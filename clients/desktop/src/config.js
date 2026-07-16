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

function normalizeServerInput(name, url) {
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
  return { name: String(name || "").trim() || parsed.host, url: clean };
}

function addServerConfig(config, name, url) {
  const server = normalizeServerInput(name, url);
  if (config.servers.some((item) => item.url === server.url)) {
    throw new Error("server already added");
  }
  return { ...config, servers: [...config.servers, server] };
}

function updateServerConfig(config, currentUrl, name, url) {
  const index = config.servers.findIndex((server) => server.url === currentUrl);
  if (index < 0) throw new Error("unknown server");

  const server = normalizeServerInput(name, url);
  if (config.servers.some((item, itemIndex) => itemIndex !== index && item.url === server.url)) {
    throw new Error("server already added");
  }

  const servers = config.servers.slice();
  servers[index] = server;
  return {
    ...config,
    servers,
    last: config.last === currentUrl ? server.url : config.last,
  };
}

module.exports = { normalizeConfig, normalizeServerInput, addServerConfig, updateServerConfig };
