import React from "react";
import { createRoot } from "react-dom/client";
import App from "./app/App";
import { I18nProvider } from "./app/i18n";

createRoot(document.getElementById("app")!).render(
  <React.StrictMode>
    <I18nProvider>
      <App />
    </I18nProvider>
  </React.StrictMode>,
);
