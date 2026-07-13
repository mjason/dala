import React from "react";
import { createRoot } from "react-dom/client";
import App from "./app/App";
import { I18nProvider } from "./app/i18n";
import { isMac } from "./app/shortcuts";

// macOS gets its native overlay scrollbars untouched; other platforms get
// the slim custom styling (see app.css, gated on this attribute).
document.documentElement.dataset.platform = isMac ? "mac" : "other";

// Soft-keyboard handling: mirror the VISUAL viewport height into --vvh so
// the app shell (#app, see app.css) shrinks when the on-screen keyboard
// opens instead of being covered by it. On desktop this equals the layout
// viewport, so nothing changes there.
const syncVisualViewportHeight = () => {
  const height = window.visualViewport?.height ?? window.innerHeight;
  document.documentElement.style.setProperty("--vvh", `${Math.round(height)}px`);
};
syncVisualViewportHeight();
window.visualViewport?.addEventListener("resize", syncVisualViewportHeight);
window.addEventListener("resize", syncVisualViewportHeight);

createRoot(document.getElementById("app")!).render(
  <React.StrictMode>
    <I18nProvider>
      <App />
    </I18nProvider>
  </React.StrictMode>,
);
