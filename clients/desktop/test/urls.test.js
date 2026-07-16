const { test, describe } = require("node:test");
const assert = require("node:assert/strict");

const { httpUrl } = require("../src/urls");

describe("httpUrl", () => {
  test("accepts and normalizes HTTP and HTTPS URLs", () => {
    assert.equal(httpUrl("http://example.test/report?q=1#chart"), "http://example.test/report?q=1#chart");
    assert.equal(httpUrl("HTTPS://EXAMPLE.TEST/a"), "https://example.test/a");
  });

  test("rejects malformed and privileged protocols", () => {
    for (const value of ["", "not a url", "javascript:alert(1)", "file:///tmp/report", "data:text/html,x"]) {
      assert.equal(httpUrl(value), null);
    }
  });
});
