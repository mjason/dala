/**
 * Voice input: browser recording + the ONE genuinely per-device pref.
 *
 * The endpoint, model and API key used to live here too, which meant
 * reconfiguring the voice service on every phone and laptop — and it let any
 * client aim the server's HTTP client at an arbitrary URL. They now live on
 * the server (`Dala.Settings.Speech`, read/written over RPC). What stays
 * local is `micDeviceId`: a deviceId from `enumerateDevices()` is meaningless
 * on another machine.
 *
 * Recording uses MediaRecorder (webm/opus), then decodes and re-encodes to
 * 16 kHz mono WAV before upload — WAV is the one format every Whisper
 * serving stack accepts without an ffmpeg dependency on the server side.
 */
import { createStore } from "./store";

export type SpeechPrefs = {
  /** Input device id; "" = auto (prefer the built-in mic — using a
   * Bluetooth headset mic flips it into call mode: sidetone + loud, tinny
   * playback for the whole system). */
  micDeviceId: string;
};

export const DEFAULT_SPEECH_PREFS: SpeechPrefs = { micDeviceId: "" };

const KEY = "dala:speech-prefs";

const store = createStore<SpeechPrefs>(KEY, DEFAULT_SPEECH_PREFS, (raw) => ({
  micDeviceId: typeof raw.micDeviceId === "string" ? raw.micDeviceId : "",
}));

export function loadSpeechPrefs(): SpeechPrefs {
  return store.load();
}

export function saveSpeechPrefs(patch: Partial<SpeechPrefs>): SpeechPrefs {
  return store.save(patch);
}

// ------------------------------------------------- one-time server migration

/** The endpoint/model/key shape that used to be persisted in this browser. */
export type LegacySpeechPrefs = { endpoint: string; model: string; apiKey: string };

/** Endpoint/model/key left over from the localStorage era, if any. */
export function readLegacySpeechPrefs(): LegacySpeechPrefs | null {
  try {
    const raw: unknown = JSON.parse(localStorage.getItem(KEY) ?? "{}");
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return null;
    const stored = raw as Record<string, unknown>;
    const endpoint = typeof stored.endpoint === "string" ? stored.endpoint.trim() : "";
    if (!endpoint) return null;
    return {
      endpoint,
      model: typeof stored.model === "string" ? stored.model : "",
      apiKey: typeof stored.apiKey === "string" ? stored.apiKey : "",
    };
  } catch {
    return null;
  }
}

/** Rewrite the entry with only what is still local (micDeviceId). */
export function dropLegacySpeechPrefs(): void {
  saveSpeechPrefs({});
}

/**
 * Silent, one-time hand-off: prefs configured in this browser before the
 * settings moved server-side get pushed up — but only when the server has
 * nothing yet, so an existing server config is never clobbered. Either way
 * the legacy keys leave localStorage. Resolves to what was pushed, or null.
 */
export async function migrateLegacySpeechPrefs(
  server: { endpoint: string },
  push: (legacy: LegacySpeechPrefs) => Promise<boolean>,
): Promise<LegacySpeechPrefs | null> {
  const legacy = readLegacySpeechPrefs();
  if (!legacy) return null;

  if (server.endpoint) {
    dropLegacySpeechPrefs();
    return null;
  }

  const pushed = await push(legacy);
  if (!pushed) return null;
  dropLegacySpeechPrefs();
  return legacy;
}

// The migration fires at APP MOUNT (not just when Settings→Voice is opened),
// so an upgrading user's voice keeps working — and their plaintext key stops
// lingering in localStorage — even if they never touch settings. This guard
// keeps it to one attempt per page session: React strict mode double-invokes
// mount effects, and the settings panel could ask again.
let migrationDone = false;

/** Test-only: forget that the migration ran this session. */
export function resetSpeechMigrationGuard(): void {
  migrationDone = false;
}

/**
 * Run the legacy hand-off at most once. Does ZERO server round-trips on the
 * common path (nothing left in localStorage → returns immediately). Only when
 * there IS something to migrate does it read the server and push. Race-safe:
 * the guard flips synchronously before the first await, so a concurrent caller
 * (app mount + settings open) can't double-push. A failed server read resets
 * the guard so a later mount retries.
 */
export async function ensureLegacySpeechMigrated(
  fetchServer: () => Promise<{ endpoint: string } | null>,
  push: (legacy: LegacySpeechPrefs) => Promise<boolean>,
): Promise<LegacySpeechPrefs | null> {
  if (migrationDone) return null;
  if (!readLegacySpeechPrefs()) return null;
  migrationDone = true;

  const server = await fetchServer();
  if (!server) {
    migrationDone = false;
    return null;
  }
  return migrateLegacySpeechPrefs(server, push);
}

// ---------------------------------------------------------------- recorder

export type Recorder = {
  /** Stops the microphone and resolves to 16 kHz mono WAV bytes. */
  stop: () => Promise<Blob>;
  cancel: () => void;
};

/** Audio input devices, for the settings picker (labels appear after the
 * first permission grant). */
export async function listMicrophones(): Promise<{ deviceId: string; label: string }[]> {
  try {
    const devices = await navigator.mediaDevices.enumerateDevices();
    return devices
      .filter((d) => d.kind === "audioinput" && d.deviceId && d.deviceId !== "default")
      .map((d, i) => ({ deviceId: d.deviceId, label: d.label || `Microphone ${i + 1}` }));
  } catch {
    return [];
  }
}

// "auto" avoids Bluetooth mics when any other input exists: capturing from
// a BT headset flips it to HFP call mode — sidetone (your own voice, loud)
// and degraded playback for the whole system while recording. Preference:
// built-in mic → any non-Bluetooth-looking input → whatever the default is.
async function micConstraints(): Promise<MediaTrackConstraints | true> {
  const preferred = loadSpeechPrefs().micDeviceId;
  if (preferred) return { deviceId: { exact: preferred } };
  try {
    const inputs = (await navigator.mediaDevices.enumerateDevices()).filter(
      (d) => d.kind === "audioinput" && d.deviceId && d.deviceId !== "default" && d.label,
    );
    const builtin = inputs.find((d) => /built-?in|internal|内建|内置|macbook/i.test(d.label));
    if (builtin) return { deviceId: { exact: builtin.deviceId } };
    const wired = inputs.find(
      (d) => !/airpods|bluetooth|蓝牙|藍牙|hands-?free|hfp|headset/i.test(d.label),
    );
    if (wired) return { deviceId: { exact: wired.deviceId } };
  } catch {
    // fall through to the default device
  }
  return true;
}

export async function startRecording(): Promise<Recorder> {
  const audio = await micConstraints();
  const stream = await navigator.mediaDevices.getUserMedia({ audio });
  const recorder = new MediaRecorder(stream);
  const chunks: BlobPart[] = [];
  recorder.ondataavailable = (event) => {
    if (event.data.size > 0) chunks.push(event.data);
  };
  recorder.start();

  const teardown = () => {
    for (const track of stream.getTracks()) track.stop();
  };

  return {
    stop: () =>
      new Promise<Blob>((resolve, reject) => {
        recorder.onstop = () => {
          teardown();
          void encodeWav(new Blob(chunks, { type: recorder.mimeType }))
            .then(resolve)
            .catch(reject);
        };
        recorder.onerror = () => {
          teardown();
          reject(new Error("recording failed"));
        };
        recorder.stop();
      }),
    cancel: () => {
      try {
        recorder.stop();
      } catch {
        // already stopped
      }
      teardown();
    },
  };
}

const TARGET_RATE = 16_000;

async function encodeWav(recorded: Blob): Promise<Blob> {
  const bytes = await recorded.arrayBuffer();
  const probe = new AudioContext();
  const decoded = await probe.decodeAudioData(bytes);
  void probe.close();

  const offline = new OfflineAudioContext(
    1,
    Math.max(1, Math.ceil(decoded.duration * TARGET_RATE)),
    TARGET_RATE,
  );
  const source = offline.createBufferSource();
  source.buffer = decoded;
  source.connect(offline.destination);
  source.start();
  const rendered = await offline.startRendering();
  const samples = rendered.getChannelData(0);

  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);
  const writeString = (offset: number, s: string) => {
    for (let i = 0; i < s.length; i++) view.setUint8(offset + i, s.charCodeAt(i));
  };
  writeString(0, "RIFF");
  view.setUint32(4, 36 + samples.length * 2, true);
  writeString(8, "WAVE");
  writeString(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, TARGET_RATE, true);
  view.setUint32(28, TARGET_RATE * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeString(36, "data");
  view.setUint32(40, samples.length * 2, true);
  for (let i = 0; i < samples.length; i++) {
    const clamped = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(44 + i * 2, clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff, true);
  }
  return new Blob([buffer], { type: "audio/wav" });
}

export async function blobToBase64(blob: Blob): Promise<string> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) {
    binary += String.fromCharCode(...bytes.subarray(i, i + step));
  }
  return btoa(binary);
}
