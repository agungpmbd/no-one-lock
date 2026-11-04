// No One Lock — kunci layar & matikan display saat kamu meninggalkan meja.
//
// Cara kerja: kamera depan dianalisis ~2x per detik dengan Vision (deteksi wajah
// + deteksi tubuh bagian atas). Kalau tidak ada orang terdeteksi selama
// `timeout` detik, layar dikunci lalu display dimatikan. Kamera berhenti saat
// layar terkunci dan hidup lagi setelah kamu unlock.

import AppKit
import AVFoundation
import Vision
import ServiceManagement

// MARK: - Presence detection

final class PresenceDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "no-one-lock.camera")
    private var configured = false
    private var lastAnalysis = Date.distantPast
    private let analysisInterval: TimeInterval = 0.5

    /// Dipanggil di main thread: true = ada orang di depan laptop.
    var onResult: ((Bool) -> Void)?

    var isRunning: Bool { session.isRunning }

    enum DetectorError: LocalizedError {
        case noCamera, cannotAddInput, cannotAddOutput
        var errorDescription: String? {
            switch self {
            case .noCamera: return "Kamera tidak ditemukan"
            case .cannotAddInput: return "Tidak bisa membuka kamera"
            case .cannotAddOutput: return "Tidak bisa membaca frame kamera"
            }
        }
    }

    func start() throws {
        if !configured { try configure() }
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() throws {
        // Utamakan kamera bawaan MacBook, bukan Continuity Camera iPhone.
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else {
            throw DetectorError.noCamera
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.low) {
            session.sessionPreset = .low
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw DetectorError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw DetectorError.cannotAddOutput }
        session.addOutput(output)

        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= analysisInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now

        let faces = VNDetectFaceRectanglesRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = true

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([faces, bodies])

        let present = !(faces.results ?? []).isEmpty || !(bodies.results ?? []).isEmpty
        DispatchQueue.main.async { [weak self] in self?.onResult?(present) }
    }
}

// MARK: - System actions

enum SystemActions {
    /// Kunci layar langsung (sama seperti Ctrl+Cmd+Q).
    static func lockScreen() {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Int32
            _ = unsafeBitCast(symbol, to: LockFn.self)()
        } else {
            // Fallback: matikan display; akan terkunci jika "Require password" = Immediately.
            sleepDisplay()
        }
    }

    static func sleepDisplay() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }
}

// MARK: - Settings

enum Settings {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    static var timeout: Int {
        get { defaults.object(forKey: "timeout") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "timeout") }
    }

    static var sleepDisplay: Bool {
        get { defaults.object(forKey: "sleepDisplay") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sleepDisplay") }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let detector = PresenceDetector()
    private var statusItem: NSStatusItem!
    private var tickTimer: Timer?

    private var lastSeen = Date()
    private var personPresent = false
    private var screenLocked = false
    private var systemAsleep = false
    private var pausedUntil: Date?
    private var cameraError: String?

    private let timeoutOptions = [5, 10, 15, 30, 60, 120]
    private let warningWindow: TimeInterval = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        detector.onResult = { [weak self] present in
            guard let self else { return }
            self.personPresent = present
            if present { self.lastSeen = Date() }
        }

        observeSystemEvents()
        requestCameraAccessAndStart()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        updateIcon()
    }

    // MARK: Lifecycle

    private var isWatching: Bool {
        guard Settings.enabled, !screenLocked, !systemAsleep, cameraError == nil else { return false }
        if let until = pausedUntil, until > Date() { return false }
        return true
    }

    private func requestCameraAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            syncCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if !granted { self.cameraError = "Akses kamera ditolak" }
                    self.syncCamera()
                }
            }
        default:
            cameraError = "Akses kamera ditolak"
            updateIcon()
        }
    }

    /// Nyalakan/matikan kamera sesuai state saat ini.
    private func syncCamera() {
        if let until = pausedUntil, until <= Date() { pausedUntil = nil }

        if isWatching {
            if !detector.isRunning {
                lastSeen = Date() // beri waktu penuh setelah kamera menyala
                do { try detector.start() } catch { cameraError = error.localizedDescription }
            }
        } else {
            detector.stop()
            personPresent = false
        }
        updateIcon()
    }

    private func tick() {
        syncCamera()
        guard isWatching else { return }

        if Date().timeIntervalSince(lastSeen) >= TimeInterval(Settings.timeout) {
            lockNow()
        }
    }

    @objc private func lockNow() {
        screenLocked = true
        syncCamera()
        SystemActions.lockScreen()
        if Settings.sleepDisplay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                SystemActions.sleepDisplay()
            }
        }
    }

    private func observeSystemEvents() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
            self?.syncCamera()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.lastSeen = Date()
            self?.syncCamera()
        }

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemAsleep = true
            self?.syncCamera()
        }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemAsleep = false
            self?.lastSeen = Date()
            self?.syncCamera()
        }
    }

    // MARK: Status bar

    private var secondsUntilLock: TimeInterval {
        max(0, TimeInterval(Settings.timeout) - Date().timeIntervalSince(lastSeen))
    }

    private func updateIcon() {
        let symbol: String
        if cameraError != nil {
            symbol = "exclamationmark.triangle"
        } else if !isWatching {
            symbol = "eye.slash"
        } else if !personPresent && secondsUntilLock <= warningWindow {
            symbol = "lock.badge.clock"
        } else {
            symbol = personPresent ? "eye" : "eye.trianglebadge.exclamationmark"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "No One Lock")
            ?? NSImage(systemSymbolName: "eye", accessibilityDescription: "No One Lock")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private var statusText: String {
        if let cameraError { return "⚠️ \(cameraError)" }
        if !Settings.enabled { return "Nonaktif" }
        if let until = pausedUntil, until > Date() {
            let f = DateFormatter()
            f.timeStyle = .short
            return "Dijeda sampai \(f.string(from: until))"
        }
        if personPresent { return "Kamu terdeteksi ✓" }
        return "Tidak ada orang — lock dalam \(Int(secondsUntilLock.rounded(.up)))s"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let enable = NSMenuItem(title: "Aktif", action: #selector(toggleEnabled), keyEquivalent: "")
        enable.state = Settings.enabled ? .on : .off
        menu.addItem(enable)

        if pausedUntil != nil {
            menu.addItem(NSMenuItem(title: "Lanjutkan sekarang", action: #selector(resume), keyEquivalent: ""))
        } else {
            let pause = NSMenuItem(title: "Jeda", action: nil, keyEquivalent: "")
            let pauseMenu = NSMenu()
            for (title, minutes) in [("15 menit", 15), ("30 menit", 30), ("1 jam", 60), ("2 jam", 120)] {
                let item = NSMenuItem(title: title, action: #selector(pause(_:)), keyEquivalent: "")
                item.tag = minutes
                pauseMenu.addItem(item)
            }
            pause.submenu = pauseMenu
            menu.addItem(pause)
        }

        let timeout = NSMenuItem(title: "Kunci setelah", action: nil, keyEquivalent: "")
        let timeoutMenu = NSMenu()
        for seconds in timeoutOptions {
            let title = seconds < 60 ? "\(seconds) detik" : "\(seconds / 60) menit"
            let item = NSMenuItem(title: title, action: #selector(setTimeout(_:)), keyEquivalent: "")
            item.tag = seconds
            item.state = Settings.timeout == seconds ? .on : .off
            timeoutMenu.addItem(item)
        }
        timeout.submenu = timeoutMenu
        menu.addItem(timeout)

        let sleep = NSMenuItem(title: "Matikan layar setelah lock", action: #selector(toggleSleepDisplay), keyEquivalent: "")
        sleep.state = Settings.sleepDisplay ? .on : .off
        menu.addItem(sleep)

        let login = NSMenuItem(title: "Buka saat login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Kunci sekarang", action: #selector(lockNow), keyEquivalent: "l"))
        if cameraError != nil {
            menu.addItem(NSMenuItem(title: "Buka pengaturan Kamera…", action: #selector(openCameraSettings), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Keluar No One Lock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != nil && item.target == nil
            && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        for item in menu.items {
            item.submenu?.items.forEach { $0.target = self }
        }
    }

    // MARK: Menu actions

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        syncCamera()
    }

    @objc private func pause(_ sender: NSMenuItem) {
        pausedUntil = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        syncCamera()
    }

    @objc private func resume() {
        pausedUntil = nil
        syncCamera()
    }

    @objc private func setTimeout(_ sender: NSMenuItem) {
        Settings.timeout = sender.tag
        lastSeen = Date()
    }

    @objc private func toggleSleepDisplay() {
        Settings.sleepDisplay.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Gagal mengatur 'Buka saat login'"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
