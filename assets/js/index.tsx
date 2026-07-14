import React from "react";
import { createRoot } from "react-dom/client";
import App from "./app/App";
import { I18nProvider } from "./app/i18n";
import { isMac } from "./app/shortcuts";
import { ThemeProvider } from "./app/theme";

// macOS gets its native overlay scrollbars untouched; other platforms get
// the slim custom styling (see app.css, gated on this attribute).
document.documentElement.dataset.platform = isMac ? "mac" : "other";

// Soft-keyboard handling: mirror the VISUAL viewport height into --vvh so
// the app shell (#app, see app.css) shrinks when the on-screen keyboard
// opens instead of being covered by it. On desktop this equals the layout
// viewport, so nothing changes there.
const syncVisualViewportHeight = () => {
  const vv = window.visualViewport;
  // Pinch-zoom (desktop or mobile) shrinks the visual viewport WITHOUT any
  // keyboard being involved — squeezing the app shell to it would reflow
  // the whole layout under the user's fingers. Only track height at 1:1.
  if (vv && vv.scale > 1) return;
  const height = vv?.height ?? window.innerHeight;
  document.documentElement.style.setProperty("--vvh", `${Math.round(height)}px`);
};
syncVisualViewportHeight();
window.visualViewport?.addEventListener("resize", syncVisualViewportHeight);
window.addEventListener("resize", syncVisualViewportHeight);

createRoot(document.getElementById("app")!).render(
  <React.StrictMode>
    <ThemeProvider>
      <I18nProvider>
        <App />
      </I18nProvider>
    </ThemeProvider>
  </React.StrictMode>,
);
