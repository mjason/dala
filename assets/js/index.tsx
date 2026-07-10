import React from "react";
import { createRoot } from "react-dom/client";
import App from "./app/App";
import { I18nProvider } from "./app/i18n";
import { isMac } from "./app/shortcuts";

// macOS gets its native overlay scrollbars untouched; other platforms get
// the slim custom styling (see app.css, gated on this attribute).
document.documentElement.dataset.platform = isMac ? "mac" : "other";

createRoot(document.getElementById("app")!).render(
  <React.StrictMode>
    <I18nProvider>
      <App />
    </I18nProvider>
  </React.StrictMode>,
);
