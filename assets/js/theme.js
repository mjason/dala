(() => {
  let stored = null;
  try {
    stored = localStorage.getItem("phx:theme");
  } catch {
    // Storage can be unavailable in hardened browser contexts.
  }
  const clientTheme = window.dala?.getTheme?.();
  const preference =
    clientTheme === "system" || clientTheme === "light" || clientTheme === "dark"
      ? clientTheme
      : stored === "light" || stored === "dark"
        ? stored
        : "system";
  try {
    if (preference === "system") localStorage.removeItem("phx:theme");
    else localStorage.setItem("phx:theme", preference);
  } catch {
    // Keep applying the in-memory preference.
  }
  const theme =
    preference === "system"
      ? matchMedia("(prefers-color-scheme: dark)").matches
        ? "dark"
        : "light"
      : preference;
  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.themeSource = preference === "system" ? "system" : "user";
  document.documentElement.dataset.themePreference = preference;
})();
