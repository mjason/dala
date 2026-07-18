// Dala desktop shell — Electron main process.
//
// One Chromium window per dala server (VS Code-style multi-window), a
// bilingual application menu to switch servers, a local management page,
// a built-in browser window for external links, and a native clipboard
// bridge for plain-http LAN servers.
const { app, BrowserWindow, Menu, Notification, WebContentsView, clipboard, dialog, ipcMain, nativeTheme, session, shell, systemPreferences } = require("electron");
const { autoUpdater } = require("electron-updater");
const { resolveLatestClient, isNewer } = require("./updater");
const { detectLocale, normalizeLocale, translate } = require("./menu-locales");
const { addServerConfig, normalizeConfig, updateServerConfig } = require("./src/config");
const { applyTheme: applyShellTheme, backgroundFor, coldStartTheme } = require("./src/theme");
const { attachCrashRecovery, recoverFromGpuCrash } = require("./crash-recovery");
const { httpUrl } = require("./src/urls");
const fs = require("fs");
const path = require("path");

const MANAGE_PAGE = path.join(__dirname, "src", "index.html");
const BROWSER_PAGE = path.join(__dirname, "src", "browser.html");
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

// Effective light/dark theme, as reported by the dala page (which owns the
// follow-system + manual-override logic). New shell windows are seeded with
// its background so they never flash the wrong shade before the page's first
// report. Seeded from the OS scheme in whenReady (below) before the first
// window; "dark" is only the pre-ready placeholder (nativeTheme is not ready
// to read at module-eval time).
let shellTheme = "dark";

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

// Same web origin? Used to pin a shell window's navigation to its own server.
function sameOrigin(a, b) {
  try {
    return Boolean(a) && Boolean(b) && new URL(a).origin === new URL(b).origin;
  } catch {
    return false;
  }
}

// A menu accelerator the client will accept from a server page's reported
// keybindings: a modifier chain + one key, and never a bare edit/system role
// accel (CmdOrCtrl+C/V/X/…) — a connected server must not silently rebind
// copy/paste/quit app-wide across every window. Real client combos carry Shift.
const ACCEL_RE =
  /^((CmdOrCtrl|Cmd|Command|Ctrl|Control|Alt|Option|AltGr|Shift|Super|Meta)\+){1,4}(F[1-9][0-9]?|[A-Za-z0-9`~!@#$%^&*()\-_=+[\]{}\\|;:'",.<>/?]|Plus|Space|Tab|Backspace|Delete|Return|Enter|Up|Down|Left|Right|Home|End|PageUp|PageDown|Escape)$/;
function validAccelerator(v) {
  if (typeof v !== "string" || v.length > 40 || !ACCEL_RE.test(v)) return false;
  const parts = v.split("+");
  const key = parts.pop().toUpperCase();
  const mods = new Set(parts.map((m) => m.toLowerCase()));
  const primaryOnly =
    mods.size === 1 &&
    [...mods][0].match(/^(cmdorctrl|cmd|command|ctrl|control|super|meta)$/) !== null;
  // Bare primary-modifier + reserved editing/system key: refuse.
  return !(primaryOnly && new Set(["C", "V", "X", "A", "Z", "W", "Q", "N", "M", "H", ","]).has(key));
}

// Shared window-open policy: http(s) links open in the built-in browser
// window, everything else (file:, javascript:, …) is dropped; no window is
// ever allowed to spawn a child window directly.
function externalLinkHandler({ url }) {
  if (httpUrl(url)) openBrowserWindow(url);
  return { action: "deny" };
}

function createShellWindow(server) {
  const win = new BrowserWindow({
    width: 1280,
    height: 820,
    backgroundColor: backgroundFor(shellTheme),
    title: server ? server.name : "Dala",
    icon: WINDOW_ICON,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      spellcheck: false,
      // A terminal keeps consuming PTY streams while the window is covered
      // or minimized — throttled timers would batch it all up and stutter
      // on refocus.
      backgroundThrottling: false,
    },
  });
  win.isDalaShell = true;
  win.serverUrl = server ? server.url : null;
  // The window is named after its server, not after whatever <title> the
  // page sets.
  win.on("page-title-updated", (event) => event.preventDefault());
  win.webContents.setWindowOpenHandler(externalLinkHandler);
  // The shell window carries the preload IPC bridge, so it must stay pinned to
  // its OWN server's origin. setWindowOpenHandler only covers new windows —
  // an in-place navigation (off-site link, meta refresh, server open-redirect)
  // would otherwise hand the full bridge to an arbitrary origin. Cancel any
  // cross-origin navigation and route it through the external-link policy (the
  // isolated, preload-less browser window) instead.
  win.webContents.on("will-navigate", (event, url) => {
    if (url.startsWith("file:") || sameOrigin(url, win.serverUrl)) return;
    event.preventDefault();
    if (httpUrl(url)) openBrowserWindow(url);
  });
  win.on("closed", rebuildMenu);
  win.crashPolicy = attachCrashRecovery(win.webContents);
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

const BROWSER_TITLEBAR_HEIGHT = 40;

function layoutBrowserView(win) {
  if (!win || win.isDestroyed() || !win.browserView) return;
  const [width, height] = win.getContentSize();
  win.browserView.setBounds({
    x: 0,
    y: BROWSER_TITLEBAR_HEIGHT,
    width,
    height: Math.max(0, height - BROWSER_TITLEBAR_HEIGHT),
  });
}

function currentBrowserUrl(win) {
  if (!win || win.isDestroyed() || !win.isDalaBrowser || !win.browserView) return null;
  return httpUrl(win.browserView.webContents.getURL());
}

async function openInSystemBrowser(win) {
  const url = currentBrowserUrl(win);
  if (!url) throw new Error("no web page is open");
  await shell.openExternal(url);
  return true;
}

// External links (terminal web-links, files "open in browser") get an
// isolated remote WebContentsView below a trusted local toolbar. The remote
// document has no preload or IPC access; only the toolbar may ask the main
// process to hand the current http(s) URL to the operating system browser.
function openBrowserWindow(url) {
  const target = httpUrl(url);
  if (!target) return null;

  const win = new BrowserWindow({
    width: 1100,
    height: 800,
    backgroundColor: nativeTheme.shouldUseDarkColors ? "#20252a" : "#f2f3f5",
    icon: WINDOW_ICON,
    ...(process.platform === "darwin"
      ? { titleBarStyle: "hiddenInset" }
      : {
          titleBarStyle: "hidden",
          titleBarOverlay: {
            color: nativeTheme.shouldUseDarkColors ? "#20252a" : "#f2f3f5",
            symbolColor: nativeTheme.shouldUseDarkColors ? "#e5e7eb" : "#30343a",
            height: BROWSER_TITLEBAR_HEIGHT,
          },
        }),
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      spellcheck: false,
    },
  });
  const view = new WebContentsView({
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
    },
  });
  win.isDalaBrowser = true;
  win.browserView = view;
  win.contentView.addChildView(view);
  layoutBrowserView(win);
  win.on("resize", () => layoutBrowserView(win));
  win.on("closed", rebuildMenu);
  win.crashPolicy = attachCrashRecovery(win.webContents);
  win.browserViewCrashPolicy = attachCrashRecovery(view.webContents);
  win.loadFile(BROWSER_PAGE);

  view.webContents.setWindowOpenHandler(externalLinkHandler);
  view.webContents.on("page-title-updated", (_event, title) => {
    const nextTitle = title || "Dala";
    win.setTitle(nextTitle);
    win.webContents.send("dala:browser-title", nextTitle);
  });
  view.webContents.on("did-navigate", rebuildMenu);
  view.webContents.on("did-navigate-in-page", rebuildMenu);
  // macOS renders its native overlay scrollbars — leave them alone;
  // other platforms get the slim pill instead of Chromium's chunky default.
  if (process.platform !== "darwin") {
    view.webContents.on("dom-ready", () => {
      void view.webContents.insertCSS(BROWSER_SCROLLBAR_CSS);
    });
  }
  void view.webContents.loadURL(target);
  return win;
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
  const activeWindow = BrowserWindow.getFocusedWindow();
  const activeBrowser = activeWindow && activeWindow.isDalaBrowser ? activeWindow : null;

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

  // Every role item needs an explicit `label:` — Electron's role defaults are
  // hardcoded English (see menu-item-roles.ts), so without one they ignore the
  // menu locale. The `role:` keeps the native behavior/accelerator.
  const template = [
    ...(isMac
      ? [{
          label: app.name,
          submenu: [
            { role: "about", label: t("about", { name: app.name }) },
            { type: "separator" },
            // The Services submenu's *contents* come from macOS (per-app
            // service providers, already in the system language); only its
            // title is ours.
            { role: "services", label: t("services") },
            { type: "separator" },
            { role: "hide", label: t("hide", { name: app.name }) },
            { role: "hideOthers", label: t("hideOthers") },
            { role: "unhide", label: t("unhide") },
            { type: "separator" },
            { role: "quit", label: t("quitApp", { name: app.name }) },
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
        {
          label: t("openInSystemBrowser"),
          enabled: Boolean(currentBrowserUrl(activeBrowser)),
          click: () => void openInSystemBrowser(activeBrowser).catch(console.error),
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
        isMac
          ? { role: "close", label: t("closeWindow") }
          : { role: "quit", label: t("quit") },
      ],
    },
    // Hand-built Edit menu: same items as the `editMenu` role (which renders
    // English), with labels. The roles are what make ⌘C/⌘V/⌘Z work natively in
    // the terminal on macOS.
    //
    // NOT here, and not ours to translate: macOS itself appends AutoFill,
    // Start Dictation and Emoji & Symbols to whatever Edit menu the app
    // installs (NSApplication does it at menu-attach time) — those already
    // follow the *system* language and cannot be labeled from Electron.
    {
      label: t("edit"),
      submenu: [
        { role: "undo", label: t("undo") },
        { role: "redo", label: t("redo") },
        { type: "separator" },
        { role: "cut", label: t("cut") },
        { role: "copy", label: t("copy") },
        { role: "paste", label: t("paste") },
        ...(isMac
          ? [
              { role: "pasteAndMatchStyle", label: t("pasteAndMatchStyle") },
              { role: "delete", label: t("delete") },
              { role: "selectAll", label: t("selectAll") },
              { type: "separator" },
              // Deliberately NOT here (and not part of Electron's `editMenu`
              // role either): the Substitutions submenu. Smart quotes / smart
              // dashes / text replacement REWRITE keystrokes inside xterm's
              // hidden textarea — `"` → `“`, `--` → `—` — which is fatal in a
              // shell. Speech stays: it only reads the selection aloud.
              {
                label: t("speech"),
                submenu: [
                  { role: "startSpeaking", label: t("startSpeaking") },
                  { role: "stopSpeaking", label: t("stopSpeaking") },
                ],
              },
            ]
          : [
              { role: "delete", label: t("delete") },
              { type: "separator" },
              { role: "selectAll", label: t("selectAll") },
            ]),
      ],
    },
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
        // Role items keep Electron's behavior/accelerators but need explicit
        // labels — without one they render in English regardless of locale.
        { role: "reload", label: t("reload") },
        { role: "forceReload", label: t("forceReload") },
        { role: "toggleDevTools", label: t("toggleDevTools") },
        {
          label: t("gpuDiagnostics"),
          click: () => {
            // chrome://gpu — an isolated, preload-less window (the built-in
            // browser only accepts http(s)).
            const win = new BrowserWindow({
              width: 980,
              height: 760,
              webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true },
            });
            void win.loadURL("chrome://gpu");
          },
        },
        { type: "separator" },
        { role: "resetZoom", label: t("actualSize") },
        { role: "zoomIn", label: t("zoomIn") },
        { role: "zoomOut", label: t("zoomOut") },
        { type: "separator" },
        // NOTE the doubled "Toggle Full Screen" seen on macOS was NOT a
        // second template entry: Electron 37.10.x picked up the cause of
        // electron#49048 (a backport of #48795 makes macOS's hidden
        // injected toggleFullScreenMode: item visible) but never got the
        // fix (#49074, 38+ only — 37 is EOL). Fixed by the electron bump
        // in package.json (^38.8.6 contains #49074).
        { role: "togglefullscreen", label: t("toggleFullScreen") },
      ],
    },
    // Hand-built Window menu (the bare `windowMenu` role renders English):
    // same items as the role's defaults, with labels; `role: "window"` on
    // the top-level item keeps macOS's automatic window list.
    {
      label: t("window"),
      role: "window",
      submenu: [
        { role: "minimize", label: t("minimize") },
        { role: "zoom", label: t("zoomWindow") },
        ...(isMac
          ? [{ type: "separator" }, { role: "front", label: t("front") }]
          : [{ role: "close", label: t("closeWindow") }]),
      ],
    },
  ];

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---------------------------------------------------------------------------
// IPC — local management and browser-toolbar commands plus the remote-page
// bridges exposed by preload.js.

// Server management is only for the local management page; remote server
// pages get nothing but the clipboard bridge.
function assertManagePage(event) {
  const url = event.senderFrame ? event.senderFrame.url : "";
  if (!url.startsWith("file:")) throw new Error("not allowed from remote pages");
}

function browserWindowFor(event) {
  const win = BrowserWindow.fromWebContents(event.sender);
  const url = event.senderFrame ? event.senderFrame.url : "";
  if (!win || !win.isDalaBrowser || event.sender !== win.webContents || !url.startsWith("file:")) {
    throw new Error("not allowed outside the browser toolbar");
  }
  return win;
}

// A sensitive bridge call coming from the SERVER PAGE itself: a shell window
// whose LIVE top frame is still on its own server's origin. Rejects foreign
// iframes embedded in the server page and any frame navigated off-origin (which
// would otherwise inherit the preload bridge) — the OS-browser/clipboard/notify
// capabilities must belong only to the server the user actually connected to.
function serverFrame(event) {
  const win = BrowserWindow.fromWebContents(event.sender);
  const frameUrl = event.senderFrame ? event.senderFrame.url : "";
  return win &&
    win.isDalaShell &&
    event.sender === win.webContents &&
    sameOrigin(frameUrl, win.serverUrl)
    ? win
    : null;
}

function assertServerFrame(event) {
  const win = serverFrame(event);
  if (!win) throw new Error("not allowed from this page");
  return win;
}

ipcMain.handle("clip_write", (event, text) => {
  assertServerFrame(event);
  clipboard.writeText(String(text ?? ""));
});

// Custom shortcuts from the page become real menu accelerators.
ipcMain.handle("set_shortcuts", (event, accelerators = {}) => {
  // Only the server page's own top frame may set these — they are app-wide, so
  // a foreign iframe/navigated page must not touch them. Combined with the
  // accelerator whitelist this keeps one server from rebinding copy/paste/quit
  // across every window.
  if (!serverFrame(event)) return;
  let changed = false;
  for (const key of Object.keys(menuShortcuts)) {
    const value = accelerators[key];
    if (validAccelerator(value) && value !== menuShortcuts[key]) {
      menuShortcuts[key] = value;
      changed = true;
    }
  }
  if (changed) rebuildMenu();
});

// The dala page reports its EFFECTIVE light/dark theme (it resolves
// follow-system + manual override itself). The native shell follows: title
// bar / traffic lights via nativeTheme.themeSource, and every shell window's
// background so the chrome never clashes with the page. Reported on first
// load and on every subsequent flip.
ipcMain.handle("set_theme", (_event, { theme } = {}) => {
  const applied = applyShellTheme(nativeTheme, BrowserWindow.getAllWindows(), theme);
  if (applied) shellTheme = applied;
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
  const win = assertServerFrame(event);
  if (!Notification.isSupported()) return false;
  const title = String(payload?.title ?? "Dala");
  const body = String(payload?.body ?? "");
  const tag = String(payload?.tag ?? "");
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
  config = addServerConfig(config, name, url);
  saveConfig(config);
  rebuildMenu();
  return config;
});

ipcMain.handle("update_server", (event, { currentUrl, name, url }) => {
  assertManagePage(event);
  const index = config.servers.findIndex((server) => server.url === currentUrl);
  config = updateServerConfig(config, currentUrl, name, url);
  const updated = config.servers[index];

  for (const win of BrowserWindow.getAllWindows()) {
    if (!win.isDestroyed() && win.isDalaShell && win.serverUrl === currentUrl) {
      win.serverUrl = updated.url;
      win.setTitle(updated.name);
      if (updated.url !== currentUrl) void win.loadURL(updated.url);
    }
  }

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

ipcMain.handle("browser_state", (event) => {
  const win = browserWindowFor(event);
  return {
    openInSystemBrowser: t("openInSystemBrowser"),
    platform: process.platform,
    title: win.getTitle(),
    url: currentBrowserUrl(win),
  };
});

ipcMain.handle("open_current_in_system_browser", (event) =>
  openInSystemBrowser(browserWindowFor(event))
);

// Server pages (the dala web app) may hand an http(s) URL to the OS browser —
// the file preview's "open in system browser" button. Same protocol policy as
// externalLinkHandler; only the server page's own top frame may ask, and the
// sandboxed built-in browser view has no IPC at all.
ipcMain.handle("open_external", (event, { url } = {}) => {
  assertServerFrame(event);
  const target = httpUrl(url);
  if (!target) throw new Error("only http(s) urls can be opened");
  return shell.openExternal(target).then(() => true);
});

// ---------------------------------------------------------------------------
// Lifecycle

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => createShellWindow(startupServer()));

  // Chromium restarts a dead GPU process on its own, but existing windows can
  // keep compositing to a black screen; reload them (each through its own
  // crash-recovery cap) so a driver reset / OOM kill never needs a manual
  // client restart.
  app.on("child-process-gone", (_event, details) => {
    if (details.type !== "GPU" || details.reason === "clean-exit") return;
    const targets = BrowserWindow.getAllWindows().flatMap((win) => [
      win.crashPolicy && { contents: win.webContents, policy: win.crashPolicy },
      win.browserViewCrashPolicy &&
        win.browserView && { contents: win.browserView.webContents, policy: win.browserViewCrashPolicy },
    ]);
    recoverFromGpuCrash(targets.filter(Boolean), details.reason);
  });

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
  // GPU rasterization for canvas/compositing (the terminal is a WebGL
  // canvas) — Chrome enables this per-device; Electron leaves it off more
  // often. Verify the result under Help → GPU Diagnostics (chrome://gpu).
  app.commandLine.appendSwitch("enable-gpu-rasterization");
  app.commandLine.appendSwitch("enable-zero-copy");

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
    // Seed the shell chrome from the OS scheme so the very first window (and
    // its titlebar) opens in the right shade instead of a hardcoded-dark flash
    // on a light-preferring OS; the page reports its effective theme right
    // after load (set_theme) and it tracks from there. nativeTheme is only
    // readable now that the app is ready — hence not at the module-level init.
    shellTheme = coldStartTheme(nativeTheme);
    applyShellTheme(nativeTheme, [], shellTheme);
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
