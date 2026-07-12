// Pure config normalization for servers.json — extracted from main.js so it
// can be unit-tested without Electron. Shape: { servers, last, locale }.
const { normalizeLocale } = require("../menu-locales");

function normalizeConfig(raw) {
  const servers = (Array.isArray(raw?.servers) ? raw.servers : [])
    .filter((s) => typeof s?.url === "string" && s.url)
    .map((s) => ({ name: typeof s.name === "string" && s.name ? s.name : s.url, url: s.url }));
  const last = typeof raw?.last === "string" ? raw.last : null;
  const locale = normalizeLocale(raw?.locale) || null;
  return { servers, last, locale };
}

module.exports = { normalizeConfig };
