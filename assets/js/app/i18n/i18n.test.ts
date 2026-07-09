import { describe, expect, it } from "vitest";
import { DICTIONARIES, detectLocale, translate } from "./index";
import { en } from "./locales";

describe("locale dictionaries", () => {
  const keys = Object.keys(en).sort();

  for (const [locale, dict] of Object.entries(DICTIONARIES)) {
    it(`${locale} covers exactly the same keys as en`, () => {
      expect(Object.keys(dict).sort()).toEqual(keys);
    });

    it(`${locale} keeps the placeholders of parameterized messages`, () => {
      for (const key of Object.keys(en) as (keyof typeof en)[]) {
        const placeholders = (en[key].match(/\{\w+\}/g) ?? []).sort();
        const translated = ((dict as typeof en)[key].match(/\{\w+\}/g) ?? []).sort();
        expect(translated, `${locale}.${key}`).toEqual(placeholders);
      }
    });
  }
});

describe("detectLocale", () => {
  it("matches exact locales", () => {
    expect(detectLocale(["ja-JP", "en-US"])).toBe("ja");
    expect(detectLocale(["fr"])).toBe("fr");
  });

  it("maps Chinese variants by script", () => {
    expect(detectLocale(["zh-CN"])).toBe("zh-CN");
    expect(detectLocale(["zh"])).toBe("zh-CN");
    expect(detectLocale(["zh-Hans-SG"])).toBe("zh-CN");
    expect(detectLocale(["zh-TW"])).toBe("zh-TW");
    expect(detectLocale(["zh-Hant-HK"])).toBe("zh-TW");
    expect(detectLocale(["zh-HK"])).toBe("zh-TW");
  });

  it("falls back through the language list", () => {
    expect(detectLocale(["tlh", "ko-KR"])).toBe("ko");
  });

  it("prefix-matches regional variants", () => {
    expect(detectLocale(["pt-BR"])).toBe("pt");
    expect(detectLocale(["de-AT"])).toBe("de");
    expect(detectLocale(["en-GB"])).toBe("en");
  });

  it("defaults to English", () => {
    expect(detectLocale([])).toBe("en");
    expect(detectLocale(["tlh", "xx-YY"])).toBe("en");
  });
});

describe("translate", () => {
  it("interpolates parameters", () => {
    expect(translate("en", "shellExitedWithCode", { code: 1 })).toBe(
      "shell exited with code 1",
    );
    expect(translate("zh-CN", "shellExitedWithCode", { code: 130 })).toBe(
      "shell 已退出，退出码 130",
    );
  });

  it("interpolates multiple parameters", () => {
    expect(translate("en", "csvTruncatedRows", { shown: 500, count: 1200 })).toBe(
      "first 500 of 1200 rows",
    );
  });
});
