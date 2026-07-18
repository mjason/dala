const { test, describe } = require("node:test");
const assert = require("node:assert/strict");

const { createReloadPolicy, attachCrashRecovery, recoverFromGpuCrash } = require("../crash-recovery");

function fakeContents() {
  const handlers = {};
  return {
    reloads: 0,
    destroyed: false,
    on(event, fn) {
      handlers[event] = fn;
    },
    emit(event, ...args) {
      handlers[event]?.(...args);
    },
    reload() {
      this.reloads += 1;
    },
    isDestroyed() {
      return this.destroyed;
    },
  };
}

describe("createReloadPolicy", () => {
  test("clean-exit is never reloaded", () => {
    const policy = createReloadPolicy(() => 0);
    assert.equal(policy.shouldReload("clean-exit"), false);
  });

  test("crashes reload up to the cap, then stop", () => {
    let now = 0;
    const policy = createReloadPolicy(() => now);
    assert.equal(policy.shouldReload("crashed"), true);
    assert.equal(policy.shouldReload("oom"), true);
    assert.equal(policy.shouldReload("killed"), true);
    assert.equal(policy.shouldReload("crashed"), false);
  });

  test("the cap is a sliding window, not a lifetime limit", () => {
    let now = 0;
    const policy = createReloadPolicy(() => now);
    policy.shouldReload("crashed");
    policy.shouldReload("crashed");
    policy.shouldReload("crashed");
    assert.equal(policy.shouldReload("crashed"), false);
    now = 61_000;
    assert.equal(policy.shouldReload("crashed"), true);
  });
});

describe("attachCrashRecovery", () => {
  test("reloads on abnormal renderer death, ignores clean-exit", () => {
    const contents = fakeContents();
    attachCrashRecovery(contents, { log: () => {} });
    contents.emit("render-process-gone", null, { reason: "crashed" });
    assert.equal(contents.reloads, 1);
    contents.emit("render-process-gone", null, { reason: "clean-exit" });
    assert.equal(contents.reloads, 1);
  });

  test("stops reloading once the cap is hit", () => {
    const contents = fakeContents();
    attachCrashRecovery(contents, { log: () => {}, policy: createReloadPolicy(() => 0) });
    for (let i = 0; i < 5; i += 1) contents.emit("render-process-gone", null, { reason: "oom" });
    assert.equal(contents.reloads, 3);
  });
});

describe("recoverFromGpuCrash", () => {
  test("reloads live windows through their own policies, skips destroyed ones", () => {
    const alive = fakeContents();
    const dead = fakeContents();
    dead.destroyed = true;
    const capped = fakeContents();
    const cappedPolicy = createReloadPolicy(() => 0);
    cappedPolicy.shouldReload("crashed");
    cappedPolicy.shouldReload("crashed");
    cappedPolicy.shouldReload("crashed");

    recoverFromGpuCrash(
      [
        { contents: alive, policy: createReloadPolicy(() => 0) },
        { contents: dead, policy: createReloadPolicy(() => 0) },
        { contents: capped, policy: cappedPolicy },
      ],
      "killed",
      { log: () => {} },
    );

    assert.equal(alive.reloads, 1);
    assert.equal(dead.reloads, 0);
    assert.equal(capped.reloads, 0);
  });
});
