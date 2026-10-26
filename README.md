# Aura Island untuk Mac

Klon fungsional Nusa untuk macOS, dibangun native (Swift + AppKit, tanpa
webview, tanpa Tauri). Nusa di Windows memakai Rust + Win32 + DirectComposition;
padanan native-nya di Mac adalah Swift + AppKit + CoreGraphics, jadi stack
inilah yang dipakai. Fungsinya yang ditiru: pulau mengambang di tengah atas
layar, media + lirik, dan fitur pilih sesi aktif ("pilih active").

Catatan: Mac Intel tidak punya notch hardware, jadi pulau ini mengambang
bebas di tengah atas layar, bukan menempel di notch.

## Build (di Mac)

1. Pastikan Xcode Command Line Tools terpasang (`xcode-select --install`
   bila belum).
2. `swift build -c release` atau langsung `./scripts/package-app.sh`
   untuk menghasilkan `Aura.app` dan `Aura.dmg` (di dalam DMG ada
   shortcut ke /Applications, jadi install tinggal drag-and-drop).
3. Jalankan `Aura.app` (boleh dipindah ke /Applications). Ikon menu bar
   "Aura" muncul; pill pulau muncul di tengah atas layar.

## Ekstensi Chrome (untuk pilih active per tab)

MediaRemote macOS hanya melihat Chrome sebagai satu client, jadi dua tab
(YouTube + YouTube Music) dalam satu Chrome tidak bisa dibedakan dari sisi
sistem. Ekstensi pendamping mengatasinya:

1. Buka `chrome://extensions`, aktifkan Developer mode, Load unpacked,
   pilih folder `extension/`.
2. Putar lagu di YouTube Music dan video di YouTube. Pulau menampilkan
   keduanya sebagai sumber terpisah.
3. Klik pulau untuk expand, klik salah satu sumber untuk mem-pin-nya.
   Selama pin aktif, pulau tetap menampilkan sumber itu (termasuk liriknya)
   walau tab lain sedang aktif. Klik lagi untuk melepas pin, atau pilih
   "Mode: Auto" dari menu bar.

Ekstensi melapor ke aplikasi lewat server lokal di `http://127.0.0.1:48123`
(tidak ada data yang keluar dari mesin).

## Cara kerja

- Window: NSWindow borderless, transparan, level floating, tidak mengambil
  fokus, rapat ke menu bar tanpa gap (1px masuk ke bawah menu bar supaya
  tidak ada garis cahaya) sehingga kartu terbaca sebagai notch, bukan
  pill melayang. Sudut atas membulat tipis (6pt), sudut bawah membulat
  penuh.
- State (gaya visual Nusa): Zen = pill tipis dengan dua mata saat idle;
  hover jadi Compact = state tertutup (lingkar baterai, jam, waveform);
  klik jadi Expanded = kartu musik/lirik (header tanggal+jam, sampul album,
  judul/artis, progress, kontrol, kolom lirik, daftar sumber).
- Media sistem: framework private MediaRemote (dlopen runtime, tanpa
  link-time dependency). Info lagu dibaca tiap 1 detik, termasuk sampul
  album bila tersedia dari sumbernya.
- Baterai: lingkar hijau dari IOKit (disembunyikan otomatis di Mac tanpa
  baterai). Waveform dianimasikan dekoratif selama lagu diputar (bukan
  analisis audio nyata, sama seperti Nusa).
- Lirik: LRCLIB (`lrclib.net/api/search`), sama seperti Nusa, tanpa key.
- Kontrol: tombol play/pause/next/prev untuk sesi sistem dikirim sebagai
  media key macOS (menargetkan client aktif sistem). Untuk tab ekstensi,
  play/pause bekerja lewat content script; next/prev tab belum didukung v1.
- Menu bar: Tentang, Mode Auto, Lepas pin, Jalankan saat login
  (SMAppService), Keluar.

## Batasan v1 (jujur)

- Belum pernah dikompilasi di sini (VM Linux tidak punya toolchain macOS).
  Compile pertama di Mac kemungkinan menemukan typo/mismatch API kecil —
  kirim errornya dan akan diperbaiki.
- Sampul album tampil bila sumber media menyediakannya lewat MediaRemote;
  tab ekstensi Chrome tidak punya sampul, jadi tampil placeholder.
- Daftar sumber di kartu expanded menampilkan maks 4 sumber.
- Tombol next/prev hanya untuk sesi sistem; tab ekstensi baru play/pause.
- Kalau tombol media tidak bereaksi, beri izin Accessibility di
  System Settings → Privacy & Security (macOS membatasi synthetic media key).
- Listener notifikasi aplikasi lain (fitur Nusa) tidak ada di macOS dan
  sengaja tidak dibuat.
- Belum ada: Pomodoro, todo, file shelf, baterai Bluetooth, status
  jaringan, water reminder. Itu Fase 2–3 dari rencana.

## Struktur

- `Sources/Aura/AppDelegate.swift` — wiring, menu bar, polling 1 detik.
- `Sources/Aura/IslandWindow.swift` — window + animator timer.
- `Sources/Aura/IslandView.swift` — gambar pill/kartu gaya Nusa + hit-test klik.
- `Sources/Aura/SessionStore.swift` — sesi gabungan + logika pin Auto/Pin.
- `Sources/Aura/MediaRemote.swift` — baca now-playing via MediaRemote.
- `Sources/Aura/Battery.swift` — level baterai via IOKit.
- `Sources/Aura/ExtensionBridge.swift` — server lokal untuk ekstensi.
- `Sources/Aura/Lyrics.swift` — klien LRCLIB + parser lirik sinkron.
- `extension/` — ekstensi Chrome pendamping (MV3).
- `scripts/package-app.sh` — build release + paket .app (LSUIElement,
  tanpa ikon Dock).
