// Dala desktop shell — Electron main process.
//
// One Chromium window per dala server (VS Code-style multi-window), a
// bilingual application menu to switch servers, a local management page,
// a built-in browser window for external links, and a native clipboard
// bridge for plain-http LAN servers.
const { app, BrowserWindow, Menu, Notification, clipboard, dialog, ipcMain, nativeTheme, session, systemPreferences } = require("electron");
const { autoUpdater } = require("electron-updater");
const { resolveLatestClient, isNewer } = require("./updater");
const { detectLocale, normalizeLocale, translate } = require("./menu-locales");
const { normalizeConfig } = require("./src/config");
const fs = require("fs");
const path = require("path");

const MANAGE_PAGE = path.join(__dirname, "src", "index.html");
const WINDOW_ICON = path.join(__dirname, "build", "icon.png");

// Safety net: a stray rejection or throw in the main process must never
// take every window down with it. Log and keep running.
process.on("unhandledRejection", (reason) => {
  console.error("[dala] unhandled rejection:", reason);
});
process.on("uncaughtException", (err) => {
  console.error("[dala] uncaught exception:", err);
});

// ---------------------------------------------------------------------------
// Config: { servers: [{ name, url }], last: url | null, locale: string | null }

let config = { servers: [], last: null, locale: null };

// Menu language: whatever the dala page reports (its own language picker),
// falling back to the system locale until the first report arrives.
let menuLocale = null;

// Menu accelerators reported by the page (Settings → Shortcuts); defaults
// match the web app's until the first report arrives.
//
// !!! KEEP IN SYNC with assets/js/app/keybindings.ts (BINDINGS entries with
// `clientMenu: true`, converted via comboToAccelerator):
//   composer:   "mod+shift+k"  -> "CmdOrCtrl+Shift+K"
//   quickShell: "ctrl+shift+`" -> "Ctrl+Shift+`"
//   voice:      "mod+shift+m"  -> "CmdOrCtrl+Shift+M"
// test/menu-shortcuts.test.js parses both files and fails on drift.
let menuShortcuts = {
  composer: "CmdOrCtrl+Shift+K",
  quickShell: "Ctrl+Shift+`",
  voice: "CmdOrCtrl+Shift+M",
};

function t(key, params) {
  const locale = menuLocale || detectLocale(app.getLocale());
  return translate(locale, key, params);
}

const configFile = () => path.join(app.getPath("userData"), "servers.json");

// The Tauri client (≤ v0.5.x) kept the same JSON under its bundle
// identifier; import it once so nobody has to re-add their servers.
function legacyConfigFile() {
  const home = app.getPath("home");
  const id = "dev.mjason.dala";
  switch (process.platform) {
    case "darwin":
      return path.join(home, "Library", "Application Support", id, "servers.json");
    case "win32":
      return path.join(process.env.APPDATA || path.join(home, "AppData", "Roaming"), id, "servers.json");
    default:
      return path.join(process.env.XDG_CONFIG_HOME || path.join(home, ".config"), id, "servers.json");
  }
}

function loadConfig() {
  try {
    return normalizeConfig(JSON.parse(fs.readFileSync(configFile(), "utf8")));
  } catch {
    // fall through: fresh install or unreadable file
  }
  try {
    const imported = normalizeConfig(JSON.parse(fs.readFileSync(legacyConfigFile(), "utf8")));
    if (imported.servers.length > 0) saveConfig(imported);
    return imported;
  } catch {
    return { servers: [], last: null, locale: null };
  }
}

function saveConfig(cfg) {
  fs.mkdirSync(path.dirname(configFile()), { recursive: true });
  fs.writeFileSync(configFile(), JSON.stringify(cfg, null, 2) + "\n");
}

// ---------------------------------------------------------------------------
// Windows

// Shared window-open policy: http(s) links open in the built-in browser
// window, everything else (file:, javascript:, …) is dropped; no window is
// ever allowed to spawn a child window directly.
function externalLinkHandler({ url }) {
  if (/^https?:/i.test(url)) openBrowserWindow(url);
  return { action: "deny" };
}

function createShellWindow(server) {
  const win = new BrowserWindow({
    width: 1280,
    height: 820,
    backgroundColor: "#0b0c0e",
    title: server ? server.name : "Dala",
    icon: WINDOW_ICON,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      spellcheck: false,
    },
  });
  win.isDalaShell = true;
  win.serverUrl = server ? server.url : null;
  // The window is named after its server, not after whatever <title> the
  // page sets.
  win.on("page-title-updated", (event) => event.preventDefault());
  win.webContents.setWindowOpenHandler(externalLinkHandler);
  win.on("closed", rebuildMenu);
  if (server) win.loadURL(server.url);
  else win.loadFile(MANAGE_PAGE);
  return win;
}

// Slim, theme-neutral scrollbars for pages the built-in browser shows —
// arbitrary documents come with Chromium's chunky defaults.
const BROWSER_SCROLLBAR_CSS = `
  ::-webkit-scrollbar { width: 12px; height: 12px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb {
    background: rgba(128, 132, 140, 0.45);
    background-clip: content-box;
    border: 3px solid transparent;
    border-radius: 6px;
  }
  ::-webkit-scrollbar-thumb:hover {
    background: rgba(140, 145, 154, 0.7);
    background-clip: content-box;
    border: 3px solid transparent;
  }
  ::-webkit-scrollbar-corner { background: transparent; }
`;

// External links (terminal web-links, files "open in browser") get a plain
// Chromium window: no preload, no IPC, page title shown as-is.
function openBrowserWindow(url) {
  const win = new BrowserWindow({
    width: 1100,
    height: 800,
    backgroundColor: "#ffffff",
    icon: WINDOW_ICON,
  });
  win.webContents.setWindowOpenHandler(externalLinkHandler);
  // macOS renders its native overlay scrollbars — leave them alone;
  // other platforms get the slim pill instead of Chromium's chunky default.
  if (process.platform !== "darwin") {
    win.webContents.on("dom-ready", () => {
      void win.webContents.insertCSS(BROWSER_SCROLLBAR_CSS);
    });
  }
  win.loadURL(url);
}

// The dala window that server-switching actions should act on: the focused
// one, else the most recently focused shell window, else none.
// Forward a menu action to the web app in the focused dala window; the
// page listens for "dala:menu" CustomEvents (see preload.js).
function sendMenuAction(action) {
  const win = targetShellWindow();
  if (win && !win.isDestroyed()) win.webContents.send("dala:menu", action);
}

function targetShellWindow() {
  const focused = BrowserWindow.getFocusedWindow();
  if (focused && !focused.isDestroyed() && focused.isDalaShell) return focused;
  return (
    BrowserWindow.getAllWindows().find((w) => w.isDalaShell && !w.isDestroyed()) || null
  );
}

function connectWindow(win, server) {
  win.serverUrl = server.url;
  win.setTitle(server.name);
  win.loadURL(server.url);
  config.last = server.url;
  saveConfig(config);
  rebuildMenu();
}

function connectTo(server) {
  const win = targetShellWindow();
  if (win) connectWindow(win, server);
  else connectWindow(createShellWindow(null), server);
}

function showManagePage() {
  const win = targetShellWindow() || createShellWindow(null);
  win.serverUrl = null;
  win.setTitle("Dala");
  win.loadFile(MANAGE_PAGE);
  rebuildMenu();
}

function startupServer() {
  return config.servers.find((s) => s.url === config.last) || null;
}

// ---------------------------------------------------------------------------
// Menu (bilingual labels, same convention as the previous client)

// ---------------------------------------------------------------------------
// Auto-update: resolve the newest client-v* release, feed it to
// electron-updater, download in the background, install on restart.

let updateReady = null; // version staged for quitAndInstall

async function checkForUpdates({ interactive } = {}) {
  if (!app.isPackaged) {
    if (interactive) {
      void dialog.showMessageBox({ message: t("devNoUpdates") });
    }
    return;
  }
  try {
    const latest = await resolveLatestClient();
    if (!latest || !isNewer(latest.version, app.getVersion())) {
      if (interactive) {
        void dialog.showMessageBox({
          message: t("upToDate", { version: app.getVersion() }),
        });
      }
      return;
    }
    autoUpdater.setFeedURL({ provider: "generic", url: latest.feedUrl });
    await autoUpdater.checkForUpdates();
  } catch (err) {
    if (interactive) dialog.showErrorBox(t("updateFailed"), String(err));
  }
}

autoUpdater.autoDownload = true;
autoUpdater.autoInstallOnAppQuit = true;
autoUpdater.on("error", () => {
  // Background checks stay silent (offline, deb install, rate limit, …);
  // interactive failures surface in checkForUpdates above.
});
autoUpdater.on("update-downloaded", async (info) => {
  updateReady = info.version;
  rebuildMenu();
  const { response } = await dialog.showMessageBox({
    type: "info",
    buttons: [t("restartNow"), t("later")],
    defaultId: 0,
    cancelId: 1,
    message: t("updateDownloaded", { version: info.version }),
    detail: t("updateDetail"),
  });
  if (response === 0) quitAndInstall();
});

// quitAndInstall throws when the staged installer went missing (cleaned
// temp dir, AV quarantine); a broken update must not crash the app.
function quitAndInstall() {
  try {
    autoUpdater.quitAndInstall();
  } catch (err) {
    console.error("[dala] quitAndInstall failed:", err);
  }
}

function rebuildMenu() {
  const isMac = process.platform === "darwin";
  const focused = targetShellWindow();

  const serverItems = config.servers.map((server, i) => ({
    label: server.name,
    type: "checkbox",
    checked: Boolean(focused && focused.serverUrl === server.url),
    accelerator: i < 9 ? `CmdOrCtrl+${i + 1}` : undefined,
    click: () => connectTo(server),
  }));

  const newWindowItems = config.servers.map((server) => ({
    label: server.name,
    click: () => createShellWindow(server),
  }));

  const template = [
    ...(isMac
      ? [{
          label: app.name,
          submenu: [
            { role: "about" },
            { type: "separator" },
            { role: "hide" },
            { role: "hideOthers" },
            { role: "unhide" },
            { type: "separator" },
            { role: "quit" },
          ],
        }]
      : []),
    {
      label: t("file"),
      submenu: [
        {
          label: t("newWindow"),
          accelerator: "CmdOrCtrl+Shift+N",
          click: () => createShellWindow(null),
        },
        {
          label: t("manageServers"),
          accelerator: "CmdOrCtrl+,",
          click: showManagePage,
        },
        { type: "separator" },
        updateReady
          ? {
              label: t("restartUpdate", { version: updateReady }),
              click: quitAndInstall,
            }
          : {
              label: t("checkUpdates"),
              click: () => void checkForUpdates({ interactive: true }),
            },
        { type: "separator" },
        isMac ? { role: "close" } : { role: "quit" },
      ],
    },
    // Role-based edit menu: native (localized) copy/paste — this is what
    // makes ⌘C/⌘V work in the terminal on macOS.
    { role: "editMenu" },
    {
      label: t("servers"),
      submenu: [
        ...serverItems,
        ...(config.servers.length > 0 ? [{ type: "separator" }] : []),
        {
          label: t("openInNewWindow"),
          enabled: config.servers.length > 0,
          submenu: newWindowItems,
        },
        { type: "separator" },
        { label: t("manageServers"), click: showManagePage },
      ],
    },
    {
      label: t("view"),
      submenu: [
        {
          label: t("composer"),
          accelerator: menuShortcuts.composer,
          click: () => sendMenuAction("composer"),
        },
        {
          label: t("quickShell"),
          accelerator: menuShortcuts.quickShell,
          click: () => sendMenuAction("quick-shell"),
        },
        {
          label: t("voiceInput"),
          accelerator: menuShortcuts.voice,
          click: () => sendMenuAction("voice"),
        },
        { type: "separator" },
        { role: "reload" },
        { role: "forceReload" },
        { role: "toggleDevTools" },
        { type: "separator" },
        { role: "resetZoom" },
        { role: "zoomIn" },
        { role: "zoomOut" },
        { type: "separator" },
        { role: "togglefullscreen" },
      ],
    },
    { role: "windowMenu" },
  ];

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---------------------------------------------------------------------------
// IPC — command names/shapes identical to the previous client, so the
// management page only changed its invoke binding.

// Server management is only for the local management page; remote server
// pages get nothing but the clipboard bridge.
function assertManagePage(event) {
  const url = event.senderFrame ? event.senderFrame.url : "";
  if (!url.startsWith("file:")) throw new Error("not allowed from remote pages");
}

ipcMain.handle("clip_write", (_event, text) => {
  clipboard.writeText(String(text ?? ""));
});

// Custom shortcuts from the page become real menu accelerators.
ipcMain.handle("set_shortcuts", (_event, accelerators = {}) => {
  let changed = false;
  for (const key of Object.keys(menuShortcuts)) {
    const value = accelerators[key];
    if (typeof value === "string" && value && value !== menuShortcuts[key]) {
      menuShortcuts[key] = value;
      changed = true;
    }
  }
  if (changed) rebuildMenu();
});

// The dala page reports its UI language; the application menu follows it.
ipcMain.handle("set_locale", (_event, { locale } = {}) => {
  const normalized = normalizeLocale(locale);
  if (!normalized || normalized === menuLocale) return;
  menuLocale = normalized;
  config.locale = normalized;
  saveConfig(config);
  rebuildMenu();
});

// Native OS notifications (Notification Center on macOS, toasts on Windows)
// for agent events on remote server pages — the web Notification API needs
// per-origin permission prompts and renders as browser notifications; the
// Electron one is the platform's own. Click focuses the window that sent it
// and tells the page which session to jump to.
ipcMain.handle("notify", (event, payload) => {
  if (!Notification.isSupported()) return false;
  const title = String(payload?.title ?? "Dala");
  const body = String(payload?.body ?? "");
  const tag = String(payload?.tag ?? "");
  const win = BrowserWindow.fromWebContents(event.sender);
  const n = new Notification({ title, body });
  n.on("click", () => {
    if (win && !win.isDestroyed()) {
      if (win.isMinimized()) win.restore();
      win.show();
      win.focus();
      win.webContents.send("dala:notify-click", tag);
    }
  });
  n.show();
  return true;
});

ipcMain.handle("list_servers", (event) => {
  assertManagePage(event);
  return config;
});

ipcMain.handle("add_server", (event, { name, url }) => {
  assertManagePage(event);
  let parsed;
  try {
    parsed = new URL(String(url || "").trim());
  } catch {
    throw new Error("invalid URL");
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error("URL must start with http:// or https://");
  }
  const clean = parsed.origin + parsed.pathname.replace(/\/+$/, "");
  if (config.servers.some((s) => s.url === clean)) throw new Error("server already added");
  config.servers.push({ name: String(name || "").trim() || parsed.host, url: clean });
  saveConfig(config);
  rebuildMenu();
  return config;
});

ipcMain.handle("remove_server", (event, { url }) => {
  assertManagePage(event);
  config.servers = config.servers.filter((s) => s.url !== url);
  if (config.last === url) config.last = null;
  saveConfig(config);
  rebuildMenu();
  return config;
});

ipcMain.handle("connect", (event, { url }) => {
  assertManagePage(event);
  const server = config.servers.find((s) => s.url === url);
  if (!server) throw new Error("unknown server");
  connectWindow(BrowserWindow.fromWebContents(event.sender), server);
});

ipcMain.handle("open_in_new_window", (event, { url }) => {
  assertManagePage(event);
  const server = config.servers.find((s) => s.url === url);
  if (!server) throw new Error("unknown server");
  createShellWindow(server);
});

// ---------------------------------------------------------------------------
// Lifecycle

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => createShellWindow(startupServer()));

  // Windows toasts require a stable AppUserModelID matching the installer's.
  app.setAppUserModelId("com.manjialin.dala");

  // getUserMedia (voice input) requires a secure context; dala servers on a
  // LAN are plain http. Chromium accepts an explicit allow-list, which must
  // be set before the app is ready — so newly added servers get microphone
  // access after the next client restart.
  config = loadConfig();
  menuLocale = config.locale || null;
  const insecureOrigins = [
    ...new Set(
      config.servers
        .map((server) => {
          try {
            const url = new URL(server.url);
            const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
            return url.protocol === "http:" && !local ? url.origin : null;
          } catch {
            return null;
          }
        })
        .filter(Boolean)
    ),
  ];
  if (insecureOrigins.length > 0) {
    app.commandLine.appendSwitch(
      "unsafely-treat-insecure-origin-as-secure",
      insecureOrigins.join(",")
    );
  }

  app.whenReady().then(() => {
    // Grant page permission requests (mic for voice input, notifications);
    // on macOS the SYSTEM permission needs its own ask.
    session.defaultSession.setPermissionRequestHandler(async (_wc, permission, callback) => {
      if (permission === "media" && process.platform === "darwin") {
        try {
          await systemPreferences.askForMediaAccess("microphone");
        } catch {
          // System prompt failed — still grant the page permission; the OS
          // level denial surfaces on its own.
        }
      }
      callback(true);
    });
    // Dark window chrome (title bar on macOS/Windows) regardless of the
    // system theme — the app itself is dark, a white title bar clashes.
    nativeTheme.themeSource = "dark";
    rebuildMenu();
    app.on("browser-window-focus", rebuildMenu);
    createShellWindow(startupServer());
    // Background update checks: shortly after launch, then every 4 hours.
    setTimeout(() => void checkForUpdates(), 10_000);
    setInterval(() => void checkForUpdates(), 4 * 60 * 60 * 1000);
  });

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createShellWindow(startupServer());
  });

  app.on("window-all-closed", () => {
    if (process.platform !== "darwin") app.quit();
  });
}
