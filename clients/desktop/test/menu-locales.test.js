const { test, describe } = require("node:test");
const assert = require("node:assert/strict");

const { MESSAGES, detectLocale, normalizeLocale, translate } = require("../menu-locales");

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

  test("every locale defines exactly the keys present in en", () => {
    // Guards against a locale silently missing a key added later (or
    // carrying a stray one). Compares the dictionaries directly — the
    // translate() fallback would mask a missing key with the en text.
    const enKeys = Object.keys(MESSAGES.en).sort();
    assert.ok(enKeys.length > 0);
    for (const locale of Object.keys(MESSAGES)) {
      assert.deepEqual(Object.keys(MESSAGES[locale]).sort(), enKeys, `${locale} key set drifted`);
    }
  });

  test("every locale names the system-browser action", () => {
    for (const locale of Object.keys(MESSAGES)) {
      assert.equal(typeof MESSAGES[locale].openInSystemBrowser, "string");
      assert.notEqual(MESSAGES[locale].openInSystemBrowser.trim(), "");
    }
    assert.equal(translate("zhCN", "openInSystemBrowser"), "在系统浏览器中打开");
  });

  test("the role items main.js labels have translations in every locale", () => {
    // Electron role items render English unless given an explicit label —
    // main.js pulls these keys, so they must exist everywhere.
    const roleKeys = [
      // View / Window
      "reload", "forceReload", "toggleDevTools",
      "actualSize", "zoomIn", "zoomOut", "toggleFullScreen",
      "window", "minimize", "zoomWindow", "closeWindow", "quit", "front",
      // Edit (incl. the macOS-only Speech submenu)
      "edit", "undo", "redo", "cut", "copy", "paste", "pasteAndMatchStyle",
      "delete", "selectAll", "speech", "startSpeaking", "stopSpeaking",
      // macOS app menu
      "about", "services", "hide", "hideOthers", "unhide", "quitApp",
    ];
    for (const locale of Object.keys(MESSAGES)) {
      for (const key of roleKeys) {
        const message = MESSAGES[locale][key];
        assert.equal(typeof message, "string", `${locale}.${key} missing`);
        assert.notEqual(message.trim(), "", `${locale}.${key} empty`);
      }
    }
  });

  test("the smart-substitution roles stay out of the Edit menu", () => {
    // Smart quotes / dashes / text replacement rewrite what the user types in
    // xterm's hidden textarea (`"` → `“`, `--` → `—`) — poison in a shell.
    // They are not part of Electron's `editMenu` role; keep them out of ours.
    const main = require("node:fs").readFileSync(require("node:path").join(__dirname, "../main.js"), "utf8");
    for (const role of ["toggleSmartQuotes", "toggleSmartDashes", "toggleTextReplacement", "showSubstitutions"]) {
      assert.equal(main.includes(role), false, `main.js still installs the ${role} role`);
    }
    for (const key of ["substitutions", "showSubstitutions", "smartQuotes", "smartDashes", "textReplacement"]) {
      assert.equal(key in MESSAGES.en, false, `menu-locales still carries the unused ${key} key`);
    }
  });

  test("the app-name role labels keep their {name} placeholder in every locale", () => {
    // about/hide/quitApp are rendered as "About Dala" & co — a translation
    // that drops {name} silently loses the app name.
    for (const locale of Object.keys(MESSAGES)) {
      for (const key of ["about", "hide", "quitApp"]) {
        assert.ok(
          MESSAGES[locale][key].includes("{name}"),
          `${locale}.${key} lost the {name} placeholder`
        );
        assert.equal(translate(locale, key, { name: "Dala" }).includes("Dala"), true);
      }
    }
  });
});
