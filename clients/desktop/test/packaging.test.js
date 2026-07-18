const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// client-v0.1.19 shipped with a hand-kept `build.files` whitelist that
// missed a freshly added module — the packaged app crashed at require()
// on startup. This guard fails the build whenever a local module that
// main-process code requires would not land inside the asar.

const root = path.join(__dirname, "..");
const pkg = require("../package.json");

function packaged(rel) {
  return pkg.build.files.some((glob) => {
    if (glob === rel) return true;
    if (glob.endsWith("/**")) return rel.startsWith(glob.slice(0, -2));
    if (glob.startsWith("*.")) return !rel.includes("/") && rel.endsWith(glob.slice(1));
    return false;
  });
}

function localRequires(rel) {
  const source = fs.readFileSync(path.join(root, rel), "utf8");
  const out = [];
  for (const match of source.matchAll(/require\("(\.\.?\/[^"]+)"\)/g)) {
    const resolved = path
      .relative(root, require.resolve(path.join(root, path.dirname(rel), match[1])))
      .replaceAll(path.sep, "/");
    out.push(resolved);
  }
  return out;
}

describe("electron-builder files", () => {
  test("every module reachable from main.js and preload.js is packaged", () => {
    const seen = new Set();
    const queue = ["main.js", "preload.js"];
    while (queue.length > 0) {
      const rel = queue.pop();
      if (seen.has(rel)) continue;
      seen.add(rel);
      assert.ok(packaged(rel), `${rel} is required but not covered by build.files`);
      queue.push(...localRequires(rel));
    }
    // Sanity: the crawl actually walked the dependency graph.
    assert.ok(seen.has("crash-recovery.js"));
    assert.ok(seen.has("src/config.js"));
  });
});
