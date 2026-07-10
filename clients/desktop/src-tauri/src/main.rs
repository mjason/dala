// Dala desktop client: a thin multi-window shell around dala servers.
// Each window shows one server's web UI (the server keeps its own login
// cookie per origin); the native menu switches the focused window between
// servers or opens another server in a new window, VS Code style.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde::{Deserialize, Serialize};
use tauri::menu::{Menu, MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::{AppHandle, Manager, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder, Wry};

static WINDOW_SEQ: AtomicUsize = AtomicUsize::new(1);

/// Injected into every window (dala servers included): window.open and
/// target=_blank links call back into the shell, which opens a built-in
/// browser window — the webview denies popups by default, so terminal
/// links and HTML previews would otherwise do nothing.
const LINK_SCRIPT: &str = r#"
(function () {
  if (window.__DALA_LINKS__) return;
  window.__DALA_LINKS__ = 1;
  var send = function (url) {
    try {
      window.__TAURI__.core.invoke("open_browser", { url: String(url) });
    } catch (e) {}
  };
  window.__DALA_CLIPBOARD__ = function (text) {
    return window.__TAURI__.core.invoke("clip_write", { text: String(text) });
  };
  var native = window.open;
  window.open = function (url) {
    if (url) { send(url); return null; }
    return native.apply(window, arguments);
  };
  document.addEventListener(
    "click",
    function (e) {
      var el = e.target;
      var a = el && el.closest ? el.closest("a[target=_blank]") : null;
      if (a && a.href) {
        e.preventDefault();
        send(a.href);
      }
    },
    true
  );
})();
"#;

#[derive(Serialize, Deserialize, Clone, Default)]
struct Config {
    servers: Vec<Server>,
    last: Option<String>,
}

#[derive(Serialize, Deserialize, Clone)]
struct Server {
    name: String,
    url: String,
}

fn config_path(app: &AppHandle) -> PathBuf {
    app.path()
        .app_config_dir()
        .expect("no config dir")
        .join("servers.json")
}

fn load_config(app: &AppHandle) -> Config {
    fs::read_to_string(config_path(app))
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

fn save_config(app: &AppHandle, cfg: &Config) -> Result<(), String> {
    let path = config_path(app);
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    fs::write(&path, serde_json::to_string_pretty(cfg).unwrap()).map_err(|e| e.to_string())
}

/// The bundled management page, addressable from any (remote) page.
fn manage_url() -> Url {
    let base = if cfg!(target_os = "windows") {
        "http://tauri.localhost/index.html"
    } else {
        "tauri://localhost/index.html"
    };
    Url::parse(base).unwrap()
}

fn parse_server_url(raw: &str) -> Result<Url, String> {
    let url = Url::parse(raw.trim()).map_err(|e| format!("invalid URL: {e}"))?;
    if url.scheme() != "http" && url.scheme() != "https" {
        return Err("URL must be http:// or https://".into());
    }
    Ok(url)
}

// --- menu --------------------------------------------------------------------

fn build_menu(app: &AppHandle, cfg: &Config) -> tauri::Result<Menu<Wry>> {
    let mut servers = SubmenuBuilder::new(app, "服务器 Servers");
    for (i, server) in cfg.servers.iter().enumerate() {
        let active = cfg.last.as_deref() == Some(server.url.as_str());
        let label = format!("{}{}", if active { "✓ " } else { "" }, server.name);
        let mut item = MenuItemBuilder::with_id(format!("connect:{i}"), label);
        if i < 9 {
            item = item.accelerator(format!("CmdOrCtrl+{}", i + 1));
        }
        servers = servers.item(&item.build(app)?);
    }

    let mut new_window = SubmenuBuilder::new(app, "在新窗口打开 Open in New Window");
    for (i, server) in cfg.servers.iter().enumerate() {
        new_window =
            new_window.item(&MenuItemBuilder::with_id(format!("newwin:{i}"), &server.name).build(app)?);
    }

    let servers = servers
        .separator()
        .item(&new_window.build()?)
        .separator()
        .item(
            &MenuItemBuilder::with_id("manage", "管理服务器 Manage Servers…")
                .accelerator("CmdOrCtrl+,")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("new-empty-window", "新建窗口 New Window")
                .accelerator("CmdOrCtrl+Shift+N")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("reload", "刷新 Reload")
                .accelerator("CmdOrCtrl+R")
                .build(app)?,
        )
        .build()?;

    let edit = SubmenuBuilder::new(app, "编辑 Edit")
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;

    MenuBuilder::new(app).item(&servers).item(&edit).build()
}

fn refresh_menu(app: &AppHandle) {
    let cfg = load_config(app);
    if let Ok(menu) = build_menu(app, &cfg) {
        let _ = app.set_menu(menu);
    }
}

// --- windows -----------------------------------------------------------------

fn focused_window(app: &AppHandle) -> Option<WebviewWindow> {
    let windows = app.webview_windows();
    windows
        .values()
        .find(|w| w.is_focused().unwrap_or(false))
        .cloned()
        .or_else(|| windows.values().next().cloned())
}

fn open_window(app: &AppHandle, url: WebviewUrl, title: &str) {
    let label = format!("win{}", WINDOW_SEQ.fetch_add(1, Ordering::SeqCst));
    let _ = WebviewWindowBuilder::new(app, label, url)
        .title(title)
        .inner_size(1280.0, 840.0)
        .initialization_script(LINK_SCRIPT)
        .build();
}

fn connect_window(app: &AppHandle, window: &WebviewWindow, server: &Server) {
    if let Ok(url) = parse_server_url(&server.url) {
        let mut cfg = load_config(app);
        cfg.last = Some(server.url.clone());
        let _ = save_config(app, &cfg);
        let _ = window.set_title(&format!("{} — Dala", server.name));
        let _ = window.navigate(url);
        refresh_menu(app);
    }
}

// --- commands (management page) ------------------------------------------------

#[tauri::command]
fn list_servers(app: AppHandle) -> Config {
    load_config(&app)
}

#[tauri::command]
fn add_server(app: AppHandle, name: String, url: String) -> Result<Config, String> {
    let parsed = parse_server_url(&url)?;
    let name = if name.trim().is_empty() {
        parsed.host_str().unwrap_or("dala").to_string()
    } else {
        name.trim().to_string()
    };

    let mut cfg = load_config(&app);
    if cfg.servers.iter().any(|s| s.url == url.trim()) {
        return Err("server already exists".into());
    }
    cfg.servers.push(Server {
        name,
        url: url.trim().to_string(),
    });
    save_config(&app, &cfg)?;
    refresh_menu(&app);
    Ok(cfg)
}

#[tauri::command]
fn remove_server(app: AppHandle, url: String) -> Result<Config, String> {
    let mut cfg = load_config(&app);
    cfg.servers.retain(|s| s.url != url);
    if cfg.last.as_deref() == Some(url.as_str()) {
        cfg.last = None;
    }
    save_config(&app, &cfg)?;
    refresh_menu(&app);
    Ok(cfg)
}

#[tauri::command]
fn connect(app: AppHandle, window: WebviewWindow, url: String) -> Result<(), String> {
    let cfg = load_config(&app);
    let server = cfg
        .servers
        .iter()
        .find(|s| s.url == url)
        .ok_or("unknown server")?;
    connect_window(&app, &window, server);
    Ok(())
}

/// Native clipboard write: webview clipboard APIs are inconsistent across
/// WKWebView/WebKitGTK/WebView2 (secure-context rules, execCommand quirks),
/// so pages bridge here instead.
#[tauri::command]
fn clip_write(text: String) -> Result<(), String> {
    arboard::Clipboard::new()
        .and_then(|mut clipboard| clipboard.set_text(text))
        .map_err(|e| e.to_string())
}

/// Built-in browser window for links that would otherwise open a popup
/// (terminal web links, HTML previews, OAuth pages).
#[tauri::command]
fn open_browser(app: AppHandle, url: String) -> Result<(), String> {
    let parsed = parse_server_url(&url)?;
    let title = parsed.host_str().unwrap_or("browser").to_string();
    open_window(&app, WebviewUrl::External(parsed), &title);
    Ok(())
}

#[tauri::command]
fn open_in_new_window(app: AppHandle, url: String) -> Result<(), String> {
    let cfg = load_config(&app);
    let server = cfg
        .servers
        .iter()
        .find(|s| s.url == url)
        .ok_or("unknown server")?
        .clone();
    let parsed = parse_server_url(&server.url)?;
    open_window(&app, WebviewUrl::External(parsed), &format!("{} — Dala", server.name));
    Ok(())
}

// --- app ---------------------------------------------------------------------

fn handle_menu(app: &AppHandle, id: &str) {
    let cfg = load_config(app);

    if let Some(index) = id.strip_prefix("connect:").and_then(|s| s.parse::<usize>().ok()) {
        if let (Some(server), Some(window)) = (cfg.servers.get(index), focused_window(app)) {
            connect_window(app, &window, &server.clone());
        }
        return;
    }
    if let Some(index) = id.strip_prefix("newwin:").and_then(|s| s.parse::<usize>().ok()) {
        if let Some(server) = cfg.servers.get(index) {
            if let Ok(url) = parse_server_url(&server.url) {
                open_window(app, WebviewUrl::External(url), &format!("{} — Dala", server.name));
            }
        }
        return;
    }

    match id {
        "manage" => {
            if let Some(window) = focused_window(app) {
                let _ = window.set_title("Dala");
                let _ = window.navigate(manage_url());
            }
        }
        "new-empty-window" => open_window(app, WebviewUrl::App("index.html".into()), "Dala"),
        "reload" => {
            if let Some(window) = focused_window(app) {
                let _ = window.eval("location.reload()");
            }
        }
        _ => {}
    }
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            list_servers,
            add_server,
            remove_server,
            connect,
            open_in_new_window,
            open_browser,
            clip_write
        ])
        .on_menu_event(|app, event| handle_menu(app, event.id().as_ref()))
        .setup(|app| {
            let handle = app.handle().clone();
            let cfg = load_config(&handle);
            app.set_menu(build_menu(&handle, &cfg)?)?;

            // Reopen the last-used server directly; first run lands on the
            // management page.
            let start = cfg
                .last
                .as_deref()
                .and_then(|last| cfg.servers.iter().find(|s| s.url == last))
                .and_then(|s| parse_server_url(&s.url).ok().map(|u| (u, s.name.clone())));

            match start {
                Some((url, name)) => {
                    open_window(&handle, WebviewUrl::External(url), &format!("{name} — Dala"))
                }
                None => open_window(&handle, WebviewUrl::App("index.html".into()), "Dala"),
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running dala client");
}
