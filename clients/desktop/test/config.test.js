const { test, describe } = require("node:test");
const assert = require("node:assert/strict");

const { normalizeConfig, themeRequestAllowed } = require("../src/config");

describe("normalizeConfig", () => {
  test("passes a well-formed config through", () => {
    const raw = {
      servers: [{ name: "Home", url: "http://192.168.1.2:4000" }],
      last: "http://192.168.1.2:4000",
      locale: "zhCN",
      theme: "light",
    };
    assert.deepEqual(normalizeConfig(raw), raw);
  });

  test("returns an empty config for garbage input", () => {
    const empty = { servers: [], last: null, locale: null, theme: "system" };
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

  test("normalizes theme through the known-theme whitelist", () => {
    assert.equal(normalizeConfig({ theme: "system" }).theme, "system");
    assert.equal(normalizeConfig({ theme: "light" }).theme, "light");
    assert.equal(normalizeConfig({ theme: "dark" }).theme, "dark");
    assert.equal(normalizeConfig({ theme: "sepia" }).theme, "system");
  });

  test("strips unknown extra fields", () => {
    const out = normalizeConfig({ servers: [], extra: true });
    assert.deepEqual(Object.keys(out).sort(), ["last", "locale", "servers", "theme"]);
  });
});

describe("themeRequestAllowed", () => {
  test("accepts the configured server origin in the main frame", () => {
    assert.equal(
      themeRequestAllowed("https://dala.example/sign-in", "https://dala.example/app", true),
      true
    );
  });

  test("rejects foreign origins, child frames, management pages, and malformed URLs", () => {
    assert.equal(themeRequestAllowed("https://evil.example", "https://dala.example", true), false);
    assert.equal(themeRequestAllowed("https://dala.example", "https://dala.example", false), false);
    assert.equal(themeRequestAllowed("file:///manage.html", null, true), false);
    assert.equal(themeRequestAllowed("not a url", "https://dala.example", true), false);
  });
});
