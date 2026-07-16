const { test, describe } = require("node:test");
const assert = require("node:assert/strict");

const {
  normalizeConfig,
  normalizeServerInput,
  addServerConfig,
  updateServerConfig,
} = require("../src/config");

describe("normalizeConfig", () => {
  test("passes a well-formed config through", () => {
    const raw = {
      servers: [{ name: "Home", url: "http://192.168.1.2:4000" }],
      last: "http://192.168.1.2:4000",
      locale: "zhCN",
    };
    assert.deepEqual(normalizeConfig(raw), raw);
  });

  test("returns an empty config for garbage input", () => {
    const empty = { servers: [], last: null, locale: null };
    assert.deepEqual(normalizeConfig(null), empty);
    assert.deepEqual(normalizeConfig(undefined), empty);
    assert.deepEqual(normalizeConfig("nonsense"), empty);
    assert.deepEqual(normalizeConfig({}), empty);
    assert.deepEqual(normalizeConfig({ servers: "not-a-list", last: 5, locale: 9 }), empty);
  });

  test("drops server entries without a usable url", () => {
    const raw = {
      servers: [
        { name: "ok", url: "http://a" },
        { name: "no url" },
        { url: "" },
        { url: 42 },
        null,
      ],
    };
    assert.deepEqual(normalizeConfig(raw).servers, [{ name: "ok", url: "http://a" }]);
  });

  test("defaults a missing or empty name to the url", () => {
    const raw = { servers: [{ url: "http://a" }, { name: "", url: "http://b" }, { name: 7, url: "http://c" }] };
    assert.deepEqual(normalizeConfig(raw).servers, [
      { name: "http://a", url: "http://a" },
      { name: "http://b", url: "http://b" },
      { name: "http://c", url: "http://c" },
    ]);
  });

  test("nulls out a non-string last", () => {
    assert.equal(normalizeConfig({ last: 123 }).last, null);
    assert.equal(normalizeConfig({ last: "http://a" }).last, "http://a");
  });

  test("normalizes locale through the known-locale whitelist", () => {
    assert.equal(normalizeConfig({ locale: "zhTW" }).locale, "zhTW");
    assert.equal(normalizeConfig({ locale: "zh-TW" }).locale, null);
    assert.equal(normalizeConfig({ locale: "klingon" }).locale, null);
  });

  test("strips unknown extra fields", () => {
    const out = normalizeConfig({ servers: [], extra: true });
    assert.deepEqual(Object.keys(out).sort(), ["last", "locale", "servers"]);
  });
});

describe("server config edits", () => {
  test("normalizes names, protocols, paths, and trailing slashes", () => {
    assert.deepEqual(normalizeServerInput("  Home  ", " http://example.test:4400/dala/// "), {
      name: "Home",
      url: "http://example.test:4400/dala",
    });
    assert.deepEqual(normalizeServerInput("", "https://example.test/"), {
      name: "example.test",
      url: "https://example.test",
    });
  });

  test("rejects malformed and non-http server URLs", () => {
    assert.throws(() => normalizeServerInput("x", "not a url"), /invalid URL/);
    assert.throws(() => normalizeServerInput("x", "file:///tmp/dala"), /http:\/\/ or https:\/\//);
  });

  test("adds a unique normalized server without mutating the input", () => {
    const config = { servers: [], last: null, locale: "en" };
    const updated = addServerConfig(config, "Home", "http://host:4400/");
    assert.deepEqual(config.servers, []);
    assert.deepEqual(updated.servers, [{ name: "Home", url: "http://host:4400" }]);
    assert.throws(() => addServerConfig(updated, "Other", "http://host:4400/"), /already added/);
  });

  test("updates name, URL, and last while preserving list position", () => {
    const config = {
      servers: [
        { name: "Home", url: "http://old:4400" },
        { name: "Work", url: "https://work:4400" },
      ],
      last: "http://old:4400",
      locale: "zhCN",
    };
    const updated = updateServerConfig(config, "http://old:4400", "New home", "https://new:4443/");
    assert.deepEqual(updated, {
      servers: [
        { name: "New home", url: "https://new:4443" },
        { name: "Work", url: "https://work:4400" },
      ],
      last: "https://new:4443",
      locale: "zhCN",
    });
    assert.deepEqual(config.servers[0], { name: "Home", url: "http://old:4400" });
  });

  test("allows an unchanged URL but rejects unknown and duplicate targets", () => {
    const config = {
      servers: [
        { name: "A", url: "http://a" },
        { name: "B", url: "http://b" },
      ],
      last: null,
      locale: null,
    };
    assert.equal(updateServerConfig(config, "http://a", "Renamed", "http://a/").servers[0].name, "Renamed");
    assert.throws(() => updateServerConfig(config, "http://missing", "X", "http://x"), /unknown server/);
    assert.throws(() => updateServerConfig(config, "http://a", "B", "http://b/"), /already added/);
  });
});
