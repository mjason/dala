export type HiddenOutputBuffer = {
  push(data: Uint8Array): { dirty: boolean; droppedBytes: number };
  drain(): Uint8Array;
  reset(): void;
  isDirty(): boolean;
  byteLength(): number;
};

/**
 * Buffers a small hidden-terminal delta without parsing it through xterm.
 * Overflow switches permanently to dirty mode until a holder repaint resets
 * the buffer; every reported dropped byte can then be acknowledged upstream.
 */
export function createHiddenOutputBuffer(limit: number): HiddenOutputBuffer {
  let chunks: Uint8Array[] = [];
  let size = 0;
  let dirty = false;

  return {
    push(data) {
      if (dirty) return { dirty: true, droppedBytes: data.byteLength };
      if (size + data.byteLength <= limit) {
        chunks.push(data);
        size += data.byteLength;
        return { dirty: false, droppedBytes: 0 };
      }

      const droppedBytes = size + data.byteLength;
      chunks = [];
      size = 0;
      dirty = true;
      return { dirty: true, droppedBytes };
    },
    drain() {
      const data = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) {
        data.set(chunk, offset);
        offset += chunk.byteLength;
      }
      chunks = [];
      size = 0;
      return data;
    },
    reset() {
      chunks = [];
      size = 0;
      dirty = false;
    },
    isDirty: () => dirty,
    byteLength: () => size,
  };
}
