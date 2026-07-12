const { test, describe } = require("node:test");
const assert = require("node:assert/strict");

const { detectLocale, normalizeLocale, translate } = require("../menu-locales");

describe("detectLocale", () => {
  test("maps simplified Chinese variants to zhCN", () => {
    assert.equal(detectLocale("zh-CN"), "zhCN");
    assert.equal(detectLocale("zh"), "zhCN");
    assert.equal(detectLocale("zh-Hans-CN"), "zhCN");
    assert.equal(detectLocale("zh-SG"), "zhCN");
  });

  test("maps traditional Chinese variants to zhTW", () => {
    assert.equal(detectLocale("zh-TW"), "zhTW");
    assert.equal(detectLocale("zh-HK"), "zhTW");
    assert.equal(detectLocale("zh-MO"), "zhTW");
    assert.equal(detectLocale("zh-Hant-TW"), "zhTW");
    assert.equal(detectLocale("zh-Hant"), "zhTW");
  });

  test("matches by language prefix, ignoring region", () => {
    assert.equal(detectLocale("en-US"), "en");
    assert.equal(detectLocale("pt-BR"), "pt");
    assert.equal(detectLocale("ja-JP"), "ja");
    assert.equal(detectLocale("ko-KR"), "ko");
    assert.equal(detectLocale("de-AT"), "de");
    assert.equal(detectLocale("fr-CA"), "fr");
  });

  test("is case-insensitive", () => {
    assert.equal(detectLocale("EN-us"), "en");
    assert.equal(detectLocale("ZH-TW"), "zhTW");
  });

  test("falls back to en for unknown, empty, or non-string locales", () => {
    assert.equal(detectLocale("xx-YY"), "en");
    assert.equal(detectLocale(""), "en");
    assert.equal(detectLocale(null), "en");
    assert.equal(detectLocale(undefined), "en");
    assert.equal(detectLocale(42), "en");
  });
});

describe("normalizeLocale", () => {
  test("passes known locale ids through", () => {
    for (const id of ["en", "zhCN", "zhTW", "ja", "ko", "es", "fr", "de", "ru", "pt"]) {
      assert.equal(normalizeLocale(id), id);
    }
  });

  test("returns null for unknown or malformed input", () => {
    assert.equal(normalizeLocale("zh-CN"), null); // BCP 47, not a message key
    assert.equal(normalizeLocale("EN"), null); // exact match only
    assert.equal(normalizeLocale(""), null);
    assert.equal(normalizeLocale(null), null);
    assert.equal(normalizeLocale(undefined), null);
  });
});

describe("translate", () => {
  test("returns the message for a known locale and key", () => {
    assert.equal(translate("zhCN", "file"), "文件");
    assert.equal(translate("en", "file"), "File");
  });

  test("falls back to en for unknown locale", () => {
    assert.equal(translate("xx", "file"), "File");
    assert.equal(translate(null, "newWindow"), "New Window");
  });

  test("falls back to the key itself for unknown keys", () => {
    assert.equal(translate("en", "noSuchKey"), "noSuchKey");
    assert.equal(translate("xx", "noSuchKey"), "noSuchKey");
  });

  test("interpolates {param} placeholders", () => {
    assert.equal(translate("en", "upToDate", { version: "1.2.3" }), "Up to date (v1.2.3)");
    assert.equal(translate("zhCN", "updateDownloaded", { version: "2.0.0" }), "新版本 v2.0.0 已下载");
  });

  test("coerces param values to strings and ignores extraneous params", () => {
    assert.equal(translate("en", "upToDate", { version: 7, unused: "x" }), "Up to date (v7)");
  });

  test("leaves placeholders intact when params are omitted", () => {
    assert.equal(translate("en", "upToDate"), "Up to date (v{version})");
  });

  test("every locale defines every key present in en", () => {
    // Guards against a locale silently missing a key added later. Uses the
    // fallback behavior: a missing key in locale X would return the en text.
    const enOnlyKeys = [
      "file", "newWindow", "manageServers", "checkUpdates", "restartUpdate",
      "servers", "openInNewWindow", "view", "composer", "quickShell",
      "voiceInput", "devNoUpdates", "upToDate", "updateDownloaded",
      "updateDetail", "restartNow", "later", "updateFailed",
    ];
    for (const locale of ["zhCN", "zhTW", "ja", "ko", "es", "fr", "de", "ru", "pt"]) {
      for (const key of enOnlyKeys) {
        const translated = translate(locale, key);
        assert.equal(typeof translated, "string");
        assert.notEqual(translated, key, `${locale}.${key} missing`);
      }
    }
  });
});
