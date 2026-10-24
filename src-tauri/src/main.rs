#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Deserialize;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

// ---------------------------------------------------------------------------
// Rect pulau dalam piksel fisik, relatif terhadap sudut kiri-atas window.
// Ditulis oleh command `set_island_rect` (frontend mengirim rect CSS, lalu
// dikali scale factor), dibaca oleh WndProc saat WM_NCHITTEST.
// Nilai default (0,0,0,0) = tidak ada area klik: semua klik tembus.
// ---------------------------------------------------------------------------
#[derive(Debug, Clone, Copy, Default)]
struct IslandRect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

static ISLAND_RECT: Mutex<IslandRect> = Mutex::new(IslandRect {
    x: 0.0,
    y: 0.0,
    width: 0.0,
    height: 0.0,
});

#[cfg(target_os = "windows")]
static ORIGINAL_WNDPROC: Mutex<Option<isize>> = Mutex::new(None);

#[derive(Debug, Deserialize)]
struct IslandRectCss {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[tauri::command]
fn set_island_rect(app: AppHandle, rect: IslandRectCss) {
    let scale = app
        .get_webview_window("main")
        .and_then(|w| w.scale_factor().ok())
        .unwrap_or(1.0);
    if let Ok(mut slot) = ISLAND_RECT.lock() {
        *slot = IslandRect {
            x: rect.x * scale,
            y: rect.y * scale,
            width: rect.width * scale,
            height: rect.height * scale,
        };
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .invoke_handler(tauri::generate_handler![set_island_rect])
        .setup(|app| {
            setup_tray(app)?;
            #[cfg(target_os = "windows")]
            setup_window_windows(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Aura Island");
}

fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    use tauri::menu::{Menu, MenuItem};
    use tauri::tray::TrayIconBuilder;

    let expand = MenuItem::with_id(
        app,
        "expand",
        "Perluas / Ciutkan Pulau",
        true,
        None::<&str>,
    )?;
    let quit = MenuItem::with_id(app, "quit", "Keluar", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&expand, &quit])?;

    let mut tray_builder = TrayIconBuilder::new()
        .menu(&menu)
        .tooltip("Aura Island")
        .on_menu_event(|app, event| match event.id.as_ref() {
            "expand" => {
                let _ = app.emit("toggle-expand", ());
            }
            "quit" => app.exit(0),
            _ => {}
        });
    if let Some(icon) = app.default_window_icon() {
        tray_builder = tray_builder.icon(icon.clone());
    }
    tray_builder.build(app)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Windows: window engine.
//  - WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW: klik tidak mencuri fokus, sembunyi
//    dari Alt+Tab.
//  - DWMWA_WINDOW_CORNER_PREFERENCE = DONOTROUND + DWMWA_BORDER_COLOR = NONE:
//    menghilangkan rounded border abu-abu dan bayangan kotak dari DWM.
//  - Subclass WndProc untuk WM_NCHITTEST: HTTRANSPARENT di luar kapsul
//    (klik tembus ke jendela di belakang), HTCLIENT di dalam kapsul.
//    Ini cara yang benar; men-toggle flag WS_EX_TRANSPARENT mengikuti kursor
//    menimbulkan flicker dan tidak dipakai.
//  - Posisi: top-center dari work area monitor utama (work area = layar
//    dikurangi taskbar), lalu window ditampilkan (config visible: false).
// ---------------------------------------------------------------------------
#[cfg(target_os = "windows")]
fn setup_window_windows(app: &tauri::App) -> tauri::Result<()> {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Dwm::{
        DwmSetWindowAttribute, DWMWA_BORDER_COLOR, DWMWA_COLOR_NONE,
        DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_DONOTROUND,
    };
    use windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTOPRIMARY,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CallWindowProcW, GetWindowLongPtrW, GetWindowRect, SetWindowLongPtrW,
        SetWindowPos, GWL_EXSTYLE, GWLP_WNDPROC, HTTRANSPARENT, HTCLIENT,
        HWND_TOPMOST, SWP_NOACTIVATE, SWP_SHOWWINDOW, WNDPROC, WS_EX_NOACTIVATE,
        WS_EX_TOOLWINDOW,
    };

    let window = app
        .get_webview_window("main")
        .expect("window utama 'main' tidak ditemukan");

    let hwnd = match window.window_handle().expect("window handle").as_raw() {
        RawWindowHandle::Win32(handle) => {
            HWND(handle.hwnd.get() as *mut core::ffi::c_void)
        }
        _ => unreachable!("Aura Island hanya menargetkan Windows"),
    };

    unsafe {
        // Extended styles: pertahankan yang sudah ada, tambahkan NOACTIVATE
        // dan TOOLWINDOW.
        let exstyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        SetWindowLongPtrW(
            hwnd,
            GWL_EXSTYLE,
            exstyle | WS_EX_NOACTIVATE.0 as isize | WS_EX_TOOLWINDOW.0 as isize,
        );

        // DWM: tanpa rounded corner, tanpa border.
        let corner: u32 = DWMWCP_DONOTROUND.0 as u32;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            &corner as *const u32 as *const core::ffi::c_void,
            std::mem::size_of::<u32>() as u32,
        );
        let border: u32 = DWMWA_COLOR_NONE.0;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_BORDER_COLOR,
            &border as *const u32 as *const core::ffi::c_void,
            std::mem::size_of::<u32>() as u32,
        );

        // Subclass WndProc untuk hit-testing.
        let original = SetWindowLongPtrW(hwnd, GWLP_WNDPROC, island_wndproc as isize);
        if let Ok(mut slot) = ORIGINAL_WNDPROC.lock() {
            *slot = Some(original);
        }

        // Posisi top-center work area monitor utama.
        let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(monitor, &mut info).as_bool() {
            let work = info.rcWork;
            let size = window
                .inner_size()
                .unwrap_or(tauri::PhysicalSize {
                    width: 560,
                    height: 300,
                });
            let x = work.left + (work.right - work.left - size.width as i32) / 2;
            let y = work.top;
            let _ = SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                x,
                y,
                size.width as i32,
                size.height as i32,
                SWP_NOACTIVATE | SWP_SHOWWINDOW,
            );
        }
    }

    let _ = window.show();
    Ok(())
}

#[cfg(target_os = "windows")]
unsafe extern "system" fn island_wndproc(
    hwnd: windows::Win32::Foundation::HWND,
    msg: u32,
    wparam: windows::Win32::Foundation::WPARAM,
    lparam: windows::Win32::Foundation::LPARAM,
) -> windows::Win32::Foundation::LRESULT {
    use windows::Win32::Foundation::RECT;
    use windows::Win32::UI::WindowsAndMessaging::{
        CallWindowProcW, GetWindowRect, HTCLIENT, HTTRANSPARENT, WM_NCHITTEST,
    };

    if msg == WM_NCHITTEST {
        // Koordinat kursor dalam piksel fisik layar.
        let x = (lparam.0 & 0xffff) as i16 as i32;
        let y = ((lparam.0 >> 16) & 0xffff) as i16 as i32;
        let mut window_rect = RECT::default();
        let _ = GetWindowRect(hwnd, &mut window_rect);
        let rel_x = (x - window_rect.left) as f64;
        let rel_y = (y - window_rect.top) as f64;
        let inside = ISLAND_RECT.lock().map(|rect| {
            rect.width > 0.0
                && rect.height > 0.0
                && rel_x >= rect.x
                && rel_x < rect.x + rect.width
                && rel_y >= rect.y
                && rel_y < rect.y + rect.height
        });
        if inside == Ok(true) {
            return HTCLIENT;
        }
        return HTTRANSPARENT;
    }

    // Semua pesan lain diteruskan ke WndProc asli.
    let original = ORIGINAL_WNDPROC
        .lock()
        .ok()
        .and_then(|slot| *slot)
        .unwrap_or(0);
    if original != 0 {
        let original_proc: WNDPROC = std::mem::transmute(original);
        return CallWindowProcW(original_proc, hwnd, msg, wparam, lparam);
    }
    windows::Win32::Foundation::LRESULT(0)
}
