import { describe, expect, it, vi } from "vitest";
import type { UploadProgress } from "../fileUpload";
import { createUploadQueue, type UploadTarget } from "./uploadQueue";

const file = (name: string) => new File(["x"], name);

/** A controllable harness: editor text + saved draft as plain strings. */
function harness() {
  const state = { editor: "" as string | null, draft: "" };
  const target: UploadTarget = {
    replaceInEditor: (marker, replacement) => {
      if (state.editor == null) return false;
      const index = state.editor.indexOf(marker);
      if (index === -1) return false;
      state.editor =
        state.editor.slice(0, index) + replacement + state.editor.slice(index + marker.length);
      state.draft = state.editor;
      return true;
    },
    readDraft: () => state.draft,
    setDraft: (next) => {
      state.draft = next;
      if (state.editor != null) state.editor = next;
    },
  };
  return { state, target };
}

function deferredUpload() {
  const calls: { files: File[]; resolve: (paths: string[]) => void; signal: AbortSignal }[] = [];
  const upload = (files: File[], opts: { signal: AbortSignal; onProgress: (progress: UploadProgress) => void }) =>
    new Promise<string[]>((resolve) => calls.push({ files, resolve, signal: opts.signal }));
  return { calls, upload };
}

describe("createUploadQueue", () => {
  it("resolves a marker in place, even with text typed around it", async () => {
    const { state, target } = harness();
    const { calls, upload } = deferredUpload();
    const queue = createUploadQueue({ target, upload, onProgress: () => {} });
    state.editor = state.draft = "看 ⟨upload:1⟩ 这张";
    const done = queue.enqueue([file("a.png")], "⟨upload:1⟩");
    state.editor = state.draft = "看看看 ⟨upload:1⟩ 这张图";
    calls[0].resolve(["/tmp/a.png"]);
    await done;
    expect(state.editor).toBe("看看看 /tmp/a.png  这张图");
  });

  it("REGRESSION: a second paste during an upload is processed, not dropped", async () => {
    const { state, target } = harness();
    const { calls, upload } = deferredUpload();
    const queue = createUploadQueue({ target, upload, onProgress: () => {} });
    state.editor = state.draft = "⟨upload:1⟩ mid ⟨upload:2⟩";
    const first = queue.enqueue([file("a.png")], "⟨upload:1⟩");
    const second = queue.enqueue([file("b.png")], "⟨upload:2⟩");
    expect(calls).toHaveLength(2);
    calls[1].resolve(["/tmp/b.png"]);
    calls[0].resolve(["/tmp/a.png"]);
    await Promise.all([first, second]);
    expect(state.editor).toBe("/tmp/a.png  mid /tmp/b.png ");
  });

  it("REGRESSION: marker sent away before the upload resolves → paths land in the fresh draft", async () => {
    const { state, target } = harness();
    const { calls, upload } = deferredUpload();
    const queue = createUploadQueue({ target, upload, onProgress: () => {} });
    state.editor = state.draft = "描述 ⟨upload:1⟩";
    const done = queue.enqueue([file("a.png")], "⟨upload:1⟩");
    // The user hit send: composer cleared, marker gone everywhere.
    state.editor = state.draft = "";
    calls[0].resolve(["/tmp/a.png"]);
    await done;
    expect(state.draft).toBe("/tmp/a.png ");
  });

  it("editor closed mid-upload → the SAVED DRAFT is repaired (no orphan markers)", async () => {
    const { state, target } = harness();
    const { calls, upload } = deferredUpload();
    const queue = createUploadQueue({ target, upload, onProgress: () => {} });
    state.editor = state.draft = "草稿 ⟨upload:1⟩ 结尾";
    const done = queue.enqueue([file("a.png")], "⟨upload:1⟩");
    state.editor = null; // composer unmounted; draft persists
    calls[0].resolve(["/tmp/a.png"]);
    await done;
    expect(state.draft).toBe("草稿 /tmp/a.png  结尾");
  });

  it("total failure consumes the marker with nothing (no garbage left)", async () => {
    const { state, target } = harness();
    const { calls, upload } = deferredUpload();
    const queue = createUploadQueue({ target, upload, onProgress: () => {} });
    state.editor = state.draft = "x ⟨upload:1⟩ y";
    const done = queue.enqueue([file("a.png")], "⟨upload:1⟩");
    calls[0].resolve([]);
    await done;
    expect(state.editor).toBe("x  y");
  });

  it("attach button (no marker): paths append with one space", async () => {
    const { state, target } = harness();
    const { calls, upload } = deferredUpload();
    const queue = createUploadQueue({ target, upload, onProgress: () => {} });
    state.editor = state.draft = "已有文字";
    const done = queue.enqueue([file("a.png")]);
    calls[0].resolve(["/tmp/a.png"]);
    await done;
    expect(state.draft).toBe("已有文字 /tmp/a.png ");
  });

  it("progress clears only after the LAST concurrent batch settles", async () => {
    const { target } = harness();
    const { calls, upload } = deferredUpload();
    const onProgress = vi.fn();
    const queue = createUploadQueue({ target, upload, onProgress });
    const a = queue.enqueue([file("a.png")], "⟨upload:1⟩");
    const b = queue.enqueue([file("b.png")], "⟨upload:2⟩");
    expect(queue.pending()).toBe(true);
    calls[0].resolve([]);
    await a;
    expect(onProgress).not.toHaveBeenCalledWith(null);
    calls[1].resolve([]);
    await b;
    expect(onProgress).toHaveBeenCalledWith(null);
    expect(queue.pending()).toBe(false);
  });

  it("abortAll signals every in-flight batch", async () => {
    const { target } = harness();
    const { calls, upload } = deferredUpload();
    const queue = createUploadQueue({ target, upload, onProgress: () => {} });
    const a = queue.enqueue([file("a.png")], "⟨upload:1⟩");
    const b = queue.enqueue([file("b.png")], "⟨upload:2⟩");
    queue.abortAll();
    expect(calls[0].signal.aborted).toBe(true);
    expect(calls[1].signal.aborted).toBe(true);
    calls[0].resolve([]);
    calls[1].resolve([]);
    await Promise.all([a, b]);
  });

  it("empty file list with a marker still consumes the marker", async () => {
    const { state, target } = harness();
    const { upload } = deferredUpload();
    const queue = createUploadQueue({ target, upload, onProgress: () => {} });
    state.editor = state.draft = "a ⟨upload:1⟩ b";
    await queue.enqueue([], "⟨upload:1⟩");
    expect(state.editor).toBe("a  b");
  });
});
