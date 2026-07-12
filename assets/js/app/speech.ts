/**
 * Voice input: browser recording + client prefs for an OpenAI-compatible
 * transcription endpoint (vLLM Whisper serving and friends).
 *
 * Recording uses MediaRecorder (webm/opus), then decodes and re-encodes to
 * 16 kHz mono WAV before upload — WAV is the one format every Whisper
 * serving stack accepts without an ffmpeg dependency on the server side.
 */

export type SpeechPrefs = {
  /** Base URL, e.g. "http://127.0.0.1:8000/v1" — empty = not configured. */
  endpoint: string;
  /** Served model name (vLLM uses the model id it was launched with). */
  model: string;
  apiKey: string;
  /** Input device id; "" = auto (prefer the built-in mic — using a
   * Bluetooth headset mic flips it into call mode: sidetone + loud, tinny
   * playback for the whole system). */
  micDeviceId: string;
};

export const DEFAULT_SPEECH_PREFS: SpeechPrefs = {
  endpoint: "",
  model: "whisper-large-v3",
  apiKey: "",
  micDeviceId: "",
};

const KEY = "dala:speech-prefs";

export function loadSpeechPrefs(): SpeechPrefs {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) ?? "{}") as Partial<SpeechPrefs>;
    return {
      endpoint: typeof raw.endpoint === "string" ? raw.endpoint : "",
      model: typeof raw.model === "string" && raw.model ? raw.model : DEFAULT_SPEECH_PREFS.model,
      apiKey: typeof raw.apiKey === "string" ? raw.apiKey : "",
      micDeviceId: typeof raw.micDeviceId === "string" ? raw.micDeviceId : "",
    };
  } catch {
    return { ...DEFAULT_SPEECH_PREFS };
  }
}

export function saveSpeechPrefs(patch: Partial<SpeechPrefs>): SpeechPrefs {
  const merged = { ...loadSpeechPrefs(), ...patch };
  try {
    localStorage.setItem(KEY, JSON.stringify(merged));
  } catch {
    // storage unavailable
  }
  return merged;
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
