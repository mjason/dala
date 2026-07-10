// Dala desktop shell — Electron main process.
//
// One Chromium window per dala server (VS Code-style multi-window), a
// bilingual application menu to switch servers, a local management page,
// a built-in browser window for external links, and a native clipboard
// bridge for plain-http LAN servers.
const { app, BrowserWindow, Menu, clipboard, dialog, ipcMain, nativeTheme } = require("electron");
const { autoUpdater } = require("electron-updater");
const { resolveLatestClient, isNewer } = require("./updater");
const fs = require("fs");
const path = require("path");

const MANAGE_PAGE = path.join(__dirname, "src", "index.html");
const WINDOW_ICON = path.join(__dirname, "build", "icon.png");

// ---------------------------------------------------------------------------
// Config: { servers: [{ name, url }], last: url | null }

let config = { servers: [], last: null };

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

function normalizeConfig(raw) {
  const servers = (Array.isArray(raw?.servers) ? raw.servers : [])
    .filter((s) => typeof s?.url === "string" && s.url)
    .map((s) => ({ name: typeof s.name === "string" && s.name ? s.name : s.url, url: s.url }));
  const last = typeof raw?.last === "string" ? raw.last : null;
  return { servers, last };
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
    return { servers: [], last: null };
  }
}

function saveConfig(cfg) {
  fs.mkdirSync(path.dirname(configFile()), { recursive: true });
  fs.writeFileSync(configFile(), JSON.stringify(cfg, null, 2) + "\n");
}

// ---------------------------------------------------------------------------
// Windows

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
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) openBrowserWindow(url);
    return { action: "deny" };
  });
  win.on("closed", rebuildMenu);
  if (server) win.loadURL(server.url);
  else win.loadFile(MANAGE_PAGE);
  return win;
}

// External links (terminal web-links, files "open in browser") get a plain
// Chromium window: no preload, no IPC, page title shown as-is.
function openBrowserWindow(url) {
  const win = new BrowserWindow({
    width: 1100,
    height: 800,
    backgroundColor: "#ffffff",
    icon: WINDOW_ICON,
  });
  win.webContents.setWindowOpenHandler(({ url: next }) => {
    if (/^https?:/i.test(next)) openBrowserWindow(next);
    return { action: "deny" };
  });
  win.loadURL(url);
}

// The dala window that server-switching actions should act on: the focused
// one, else the most recently focused shell window, else none.
function targetShellWindow() {
  const focused = BrowserWindow.getFocusedWindow();
  if (focused && focused.isDalaShell) return focused;
  return BrowserWindow.getAllWindows().find((w) => w.isDalaShell) || null;
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
      void dialog.showMessageBox({ message: "开发模式不检查更新 (dev build)" });
    }
    return;
  }
  try {
    const latest = await resolveLatestClient();
    if (!latest || !isNewer(latest.version, app.getVersion())) {
      if (interactive) {
        void dialog.showMessageBox({
          message: `已是最新版本 Up to date (v${app.getVersion()})`,
        });
      }
      return;
    }
    autoUpdater.setFeedURL({ provider: "generic", url: latest.feedUrl });
    await autoUpdater.checkForUpdates();
  } catch (err) {
    if (interactive) dialog.showErrorBox("检查更新失败 Update check failed", String(err));
  }
}

autoUpdater.autoDownload = true;
autoUpdater.autoInstallOnAppQuit = true;
autoUpdater.on("error", () => {
  // Background checks stay silent (offline, deb install, rate limit, …);
  // interactive failures surface in checkForUpdates above.
});
autoUpdater.on("update-downloaded", (info) => {
  updateReady = info.version;
  rebuildMenu();
  void dialog
    .showMessageBox({
      type: "info",
      buttons: ["重启并更新 Restart & Update", "稍后 Later"],
      defaultId: 0,
      cancelId: 1,
      message: `新版本 v${info.version} 已下载 Update downloaded`,
      detail: "重启应用即完成升级；稍后退出时也会自动安装。\nRestart to apply — or it installs on next quit.",
    })
    .then(({ response }) => {
      if (response === 0) autoUpdater.quitAndInstall();
    });
});

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
      label: "文件 File",
      submenu: [
        {
          label: "新建窗口 New Window",
          accelerator: "CmdOrCtrl+Shift+N",
          click: () => createShellWindow(null),
        },
        {
          label: "管理服务器 Manage Servers…",
          accelerator: "CmdOrCtrl+,",
          click: showManagePage,
        },
        { type: "separator" },
        updateReady
          ? {
              label: `重启并更新 Restart & Update (v${updateReady})`,
              click: () => autoUpdater.quitAndInstall(),
            }
          : {
              label: "检查更新 Check for Updates…",
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
      label: "服务器 Servers",
      submenu: [
        ...serverItems,
        ...(config.servers.length > 0 ? [{ type: "separator" }] : []),
        {
          label: "在新窗口打开 Open in New Window",
          enabled: config.servers.length > 0,
          submenu: newWindowItems,
        },
        { type: "separator" },
        { label: "管理服务器 Manage Servers…", click: showManagePage },
      ],
    },
    {
      label: "视图 View",
      submenu: [
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

  app.whenReady().then(() => {
    // Dark window chrome (title bar on macOS/Windows) regardless of the
    // system theme — the app itself is dark, a white title bar clashes.
    nativeTheme.themeSource = "dark";
    config = loadConfig();
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
