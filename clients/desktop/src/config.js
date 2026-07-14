// Pure config normalization for servers.json — extracted from main.js so it
// can be unit-tested without Electron. Shape: { servers, last, locale, theme }.
const { normalizeLocale } = require("../menu-locales");

function normalizeConfig(raw) {
  const servers = (Array.isArray(raw?.servers) ? raw.servers : [])
    .filter((s) => typeof s?.url === "string" && s.url)
    .map((s) => ({ name: typeof s.name === "string" && s.name ? s.name : s.url, url: s.url }));
  const last = typeof raw?.last === "string" ? raw.last : null;
  const locale = normalizeLocale(raw?.locale) || null;
  const theme = ["system", "light", "dark"].includes(raw?.theme) ? raw.theme : "system";
  return { servers, last, locale, theme };
}

function themeRequestAllowed(pageUrl, serverUrl, mainFrame) {
  if (!mainFrame || typeof pageUrl !== "string" || typeof serverUrl !== "string") return false;
  try {
    return new URL(pageUrl).origin === new URL(serverUrl).origin;
  } catch {
    return false;
  }
}

module.exports = { normalizeConfig, themeRequestAllowed };
