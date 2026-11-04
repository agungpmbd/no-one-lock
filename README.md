# No One Lock

Aplikasi menu bar macOS yang **otomatis mengunci layar dan mematikan display** saat kamu meninggalkan meja kerja.

No One Lock memakai kamera bawaan Mac untuk mendeteksi apakah ada orang di depan laptop. Kalau tidak ada yang terdeteksi selama beberapa detik, layar langsung dikunci.

## Fitur

- Deteksi kehadiran dengan **wajah + tubuh bagian atas** (Apple Vision), jadi menoleh atau menunduk tidak memicu lock
- Kunci layar instan (setara `Ctrl + Cmd + Q`), lalu display dimatikan
- Kamera otomatis berhenti saat layar terkunci dan aktif lagi setelah unlock
- Waktu tunggu bisa diatur: 5 detik sampai 2 menit
- Jeda sementara (15 menit sampai 2 jam)
- Opsi buka otomatis saat login
- **Privasi:** semua gambar diproses di perangkat, tidak pernah disimpan atau dikirim ke mana pun

## Ikon menu bar

| Ikon | Arti |
|------|------|
| 👁 mata | Kamu terdeteksi |
| 👁 + tanda seru | Tidak ada orang, hitung mundur berjalan |
| 🔒 + jam | Akan terkunci dalam 3 detik |
| 👁 dicoret | Dijeda / nonaktif |

## Kebutuhan

- macOS 14 (Sonoma) atau lebih baru
- Mac Apple Silicon atau Intel dengan kamera

## Instalasi

### Dari Releases

1. Unduh `NoOneLock.zip` dari halaman [Releases](https://github.com/agungpmbd/no-one-lock/releases), lalu ekstrak.
2. Pindahkan **No One Lock.app** ke folder **Applications**.
3. Buka aplikasinya. Karena belum dinotarisasi Apple, macOS akan memblokirnya. Buka **System Settings → Privacy & Security**, scroll ke bawah, lalu klik **Open Anyway**.
4. Klik **Allow** saat diminta izin kamera.

### Build dari source

Hanya butuh Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/agungpmbd/no-one-lock.git
cd no-one-lock
./build.sh            # build ke build/No One Lock.app
./build.sh install    # build, salin ke /Applications, lalu jalankan
./build.sh dist       # build dan buat build/NoOneLock.zip untuk dibagikan
```

## Catatan

- Lampu hijau kamera akan menyala selama aplikasi aktif. Ini aturan macOS.
- Di ruangan yang sangat gelap, deteksi bisa gagal. Gunakan **Jeda** atau perpanjang waktu tunggu.
- Fitur lock memakai fungsi privat macOS (`SACLockScreenImmediate`). Kalau tidak tersedia, aplikasi akan mematikan display, dan layar tetap terkunci jika opsi "Require password" diset ke *Immediately*.

## Lisensi

[MIT](LICENSE) © 2026 Agung Pambudi
