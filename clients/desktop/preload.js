// Bridge between dala pages (local management page + remote server pages)
// and the Electron main process. Runs with contextIsolation on.
const { contextBridge, ipcRenderer } = require("electron");

// ipcMain.handle rejections arrive wrapped as
// "Error invoking remote method 'add_server': Error: <message>" — strip the
// wrapper so pages can show the message as-is.
const invoke = async (cmd, args) => {
  try {
    return await ipcRenderer.invoke(cmd, args);
  } catch (err) {
    const raw = err && err.message ? err.message : String(err);
    throw raw.replace(/^Error invoking remote method '[^']+': (Error: )?/, "");
  }
};

contextBridge.exposeInMainWorld("dala", { invoke });

// Menu accelerators (⌘K composer, ⌘J quick shell) forwarded to the page.
ipcRenderer.on("dala:menu", (_event, action) => {
  window.dispatchEvent(new CustomEvent("dala:menu", { detail: action }));
});

// Same contract the web app already probes for: a function returning a
// promise. Chromium's navigator.clipboard needs a secure context, which
// plain-http LAN servers are not — this always works.
contextBridge.exposeInMainWorld("__DALA_CLIPBOARD__", (text) =>
  invoke("clip_write", String(text ?? ""))
);
