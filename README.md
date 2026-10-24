# Aura Island — Fase 1: Foundation & Window Engine

Dynamic Island untuk Windows (Tauri v2 + React + TypeScript + Framer Motion).
Fase 1 mencakup: window engine Windows, state machine 4 mode, tray icon,
autostart, settings, dan global hotkey. Modul media asli (GSMTC, WASAPI) masuk
Fase 2; konten lagu/timer di Fase 1 masih demo visual.

## Yang sudah jadi di Fase 1

- **Window engine (Rust, `src-tauri/src/main.rs`)**
  - Frameless, transparent, always-on-top, `skipTaskbar`.
  - `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`: klik tidak mencuri fokus, sembunyi
    dari Alt+Tab.
  - `DWMWA_WINDOW_CORNER_PREFERENCE = DONOTROUND` + `DWMWA_BORDER_COLOR = NONE`.
  - **Click-through via WM_NCHITTEST**: WndProc di-subclass; titik di luar
    kapsul mengembalikan `HTTRANSPARENT` (klik tembus), di dalam kapsul
    `HTCLIENT`. Frontend melaporkan rect pulau lewat command `set_island_rect`.
  - Posisi top-center dari work area monitor utama, lalu window ditampilkan.
- **State machine UI (`src/island/Island.tsx`)**: Zen (120x4) <-> Compact (180x36)
  <-> Split (160x36 + bubble 36, efek gooey SVG sesuai PRD) <-> Expanded
  (420x180). Spring PRD: expand 380/28/0.8, collapse 450/35/0.7.
- **Interaksi**: hover >150 ms (bisa diatur) memperluas, klik kapsul toggle,
  klik garis Zen kembali ke Compact, tombol Zen di kartu, hotkey `Ctrl+Alt+I`,
  menu tray "Perluas / Ciutkan Pulau" dan "Keluar".
- **Settings**: hover delay, demo musik, demo timer (tersimpan di localStorage
  WebView2); autostart via plugin-autostart (toggle di kartu Expanded).
- **Ikon**: `src-tauri/icons/icon.png` + `icon.ico` (kapsul hitam, dibuat lokal).

## Build & jalan di Windows (langkah user)

Prasyarat: Windows 10 1903+ / 11, WebView2 Runtime (bawaan Windows 10/11),
Rust stable via https://rustup.rs, Node.js 20+.

```powershell
npm install
npm run tauri dev
```

Untuk installer:

```powershell
npm run tauri build
```

Hasilnya di `src-tauri/target/release/bundle/` (`.msi` dan `.exe` NSIS).

## Checklist penerimaan Fase 1 (diuji di PC Windows)

1. Pulau muncul di tengah-atas layar, di atas taskbar dan jendela lain.
2. Hover >150 ms memperluas ke kartu; keluar dari kartu mengecilkan lagi.
3. Klik di luar kapsul (mis. tab browser di belakang area window) tetap
   mengklik aplikasi di belakangnya, bukan pulau.
4. Klik tombol di kartu tidak membuat aplikasi yang sedang aktif kehilangan
   fokus (ketik di editor, klik play demo, fokus editor tetap).
5. Tray icon muncul; menu tray bekerja; `Ctrl+Alt+I` toggle expand.
6. Autostart toggle bertahan setelah restart aplikasi.
7. Tombol Zen menyembunyikan pulau jadi garis; klik garis mengembalikan Compact.

## Yang belum terverifikasi (jujur)

VM pembuat kode ini adalah Linux tanpa toolchain Rust/Windows, sehingga:

- **Kode Rust belum pernah di-compile.** `cargo tauri dev` di Windows adalah
  langkah verifikasi pertama. Yang paling mungkin perlu penyesuaian kecil:
  pemanggilan builder menu/tray (`Menu::with_items`, `TrayIconBuilder`),
  permission capability di `src-tauri/capabilities/default.json`, dan
  detail `windows` crate (nama konstanta/fitur).
- **Perilaku WM_NCHITTEST, DWM, dan no-activate belum teruji di perangkat.**
  Checklist di atas adalah definisi "Fase 1 selesai", bukan klaim sudah lolos.
- **Frontend sudah terverifikasi**: `tsc` bersih dan `vite build` lolos
  (dist ~388 KB). UI juga bisa dibuka di browser biasa via `npm run dev`
  untuk QA visual — semua pemanggilan Tauri menjadi no-op di luar Tauri.

## Catatan scope (dari audit PRD)

- Target RAM direvisi: idle ≤80 MB, expanded ≤120 MB (private working set).
  Klaim PRD <35 MB tidak realistis untuk WebView2.
- System HUD diposisikan sebagai companion, bukan replacement OSD bawaan
  (Windows 11 tidak menyediakan API menonaktifkan flyout-nya).
- Indikator kamera/mikrofon digeser ke Fase 5 (spike, bisa dipotong).
- Baterai Bluetooth: best-effort (hanya perangkat yang mengekspos GATT
  Battery Service). V1: monitor utama saja, brightness layar internal saja.
