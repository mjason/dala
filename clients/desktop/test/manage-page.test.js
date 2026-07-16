const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const page = fs.readFileSync(path.join(__dirname, "../src/index.html"), "utf8");

describe("manage page server list", () => {
  test("editing happens in place on the row, not by reusing the add form", () => {
    // The row itself becomes the inputs…
    assert.match(page, /editRow\(row, server\)/);
    assert.match(page, /row\.classList\.add\("editing"\)/);
    // …and the add form's submit handler only ever adds.
    const submitHandler = page.slice(page.indexOf('$("add-form").onsubmit'));
    assert.match(submitHandler, /invoke\("add_server"/);
    assert.doesNotMatch(submitHandler, /update_server/);
  });

  test("in-place editor saves via update_server", () => {
    assert.match(page, /invoke\("update_server", \{ currentUrl: server\.url/);
  });

  test("a single edit session: render drives which row is the editor", () => {
    // One tracked url, cleared on save/cancel/removed; render renders that row
    // as the editor — so opening/cancelling one can't strand another.
    assert.match(page, /let editingUrl = null/);
    assert.match(page, /server\.url === editingUrl/);
    assert.match(page, /editingUrl = server\.url; render\(lastConfig\)/);
    assert.match(page, /!cfg\.servers\.some\(\(s\) => s\.url === editingUrl\)/);
  });

  test("Enter/Escape are IME-safe (no submit mid-composition)", () => {
    assert.match(page, /function editKey\(e, save, cancel\)/);
    assert.match(page, /e\.isComposing \|\| e\.keyCode === 229/);
    assert.match(page, /e\.key === "Enter"/);
    assert.match(page, /e\.key === "Escape"/);
  });
});
