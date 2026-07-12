const { test, describe, afterEach } = require("node:test");
const assert = require("node:assert/strict");

const { isNewer, resolveLatestClient } = require("../updater");

// Pinned on purpose: the updater must talk to this repo's releases.
const REPO = "mjason/dala";

describe("isNewer", () => {
  test("equal versions are not newer", () => {
    assert.equal(isNewer("1.2.3", "1.2.3"), false);
    assert.equal(isNewer("0.0.0", "0.0.0"), false);
  });

  test("patch bump", () => {
    assert.equal(isNewer("1.2.4", "1.2.3"), true);
    assert.equal(isNewer("1.2.3", "1.2.4"), false);
  });

  test("minor bump", () => {
    assert.equal(isNewer("1.3.0", "1.2.9"), true);
    assert.equal(isNewer("1.2.9", "1.3.0"), false);
  });

  test("major bump", () => {
    assert.equal(isNewer("2.0.0", "1.9.9"), true);
    assert.equal(isNewer("1.9.9", "2.0.0"), false);
  });

  test("numeric, not lexicographic, comparison", () => {
    assert.equal(isNewer("0.10.0", "0.9.0"), true);
    assert.equal(isNewer("0.2.10", "0.2.9"), true);
  });

  test("missing components are treated as 0", () => {
    assert.equal(isNewer("1.2", "1.2.0"), false);
    assert.equal(isNewer("1.2.0", "1.2"), false);
    assert.equal(isNewer("1.2.1", "1.2"), true);
    assert.equal(isNewer("2", "1.9.9"), true);
  });

  test("malformed input degrades to 0, never throws", () => {
    assert.equal(isNewer("abc", "1.0.0"), false); // abc -> 0.0.0
    assert.equal(isNewer("1.0.0", "abc"), true);
    assert.equal(isNewer("", ""), false);
    assert.equal(isNewer(null, undefined), false);
    assert.equal(isNewer("1.x.3", "1.0.2"), true); // "x" -> 0, so 1.0.3 vs 1.0.2
  });

  test("prerelease suffix is ignored (documented limitation)", () => {
    // "1.2.3-beta" parses as 1.2.3 — prereleases compare equal to releases.
    assert.equal(isNewer("1.2.3-beta", "1.2.3"), false);
    assert.equal(isNewer("1.2.3", "1.2.3-beta"), false);
  });
});

describe("resolveLatestClient", () => {
  const realFetch = global.fetch;
  afterEach(() => {
    global.fetch = realFetch;
  });

  const stubFetch = (refs, { ok = true, status = 200 } = {}) => {
    const calls = [];
    global.fetch = async (url, opts) => {
      calls.push({ url, opts });
      return { ok, status, json: async () => refs };
    };
    return calls;
  };

  const ref = (tag) => ({ ref: `refs/tags/${tag}` });

  test("picks the numerically newest client-v tag", async () => {
    stubFetch([ref("client-v0.9.0"), ref("client-v0.10.1"), ref("client-v0.2.3")]);
    const latest = await resolveLatestClient();
    assert.deepEqual(latest, {
      tag: "client-v0.10.1",
      version: "0.10.1",
      feedUrl: `https://github.com/${REPO}/releases/download/client-v0.10.1`,
    });
  });

  test("queries the prefix-scoped tag listing for the repo", async () => {
    const calls = stubFetch([ref("client-v1.0.0")]);
    await resolveLatestClient();
    assert.equal(calls.length, 1);
    assert.equal(
      calls[0].url,
      `https://api.github.com/repos/${REPO}/git/matching-refs/tags/client-v`
    );
  });

  test("survives duplicate and equal versions (no sort-contract abuse)", async () => {
    stubFetch([ref("client-v0.5.0"), ref("client-v0.5.0"), ref("client-v0.4.9")]);
    const latest = await resolveLatestClient();
    assert.equal(latest.version, "0.5.0");
  });

  test("aborts the GitHub request after a timeout via AbortSignal", async () => {
    const calls = stubFetch([ref("client-v1.0.0")]);
    await resolveLatestClient();
    assert.ok(calls[0].opts.signal instanceof AbortSignal, "fetch must carry an AbortSignal");
  });

  test("ignores tags that do not start with a digit after the prefix", async () => {
    stubFetch([ref("client-vnext"), ref("client-v1.4.0"), ref("client-v-rc")]);
    const latest = await resolveLatestClient();
    assert.equal(latest.version, "1.4.0");
  });

  test("tolerates malformed ref entries", async () => {
    stubFetch([{}, { ref: null }, ref("client-v0.3.0")]);
    const latest = await resolveLatestClient();
    assert.equal(latest.version, "0.3.0");
  });

  test("returns null when no client tags exist", async () => {
    stubFetch([]);
    assert.equal(await resolveLatestClient(), null);
  });

  test("throws on a non-OK GitHub response", async () => {
    stubFetch([], { ok: false, status: 403 });
    await assert.rejects(resolveLatestClient, /GitHub responded with 403/);
  });
});
