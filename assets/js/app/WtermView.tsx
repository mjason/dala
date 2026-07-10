import React, { useEffect, useRef, useState } from "react";
import { Terminal, type TerminalHandle } from "@wterm/react";
import { GhosttyCore } from "@wterm/ghostty";
import type { Channel } from "phoenix";
import { getSocket } from "./socket";
import {
  createTerminalChannel,
  onTerminalChannelMessages,
  unsubscribeTerminalChannel,
} from "../ash_typed_channels";
import { base64ToBytes } from "./util";
import { createStreamGate } from "./streamGate";

type TerminalActions = { reset: () => void; refit: () => void; focus: () => void };

type Props = {
  sessionId: string;
  scrollbackLines?: number;
  onCwdChange?: (cwd: string) => void;
  onError?: (message: string) => void;
  actionsRef?: React.MutableRefObject<TerminalActions | null>;
};

/**
 * Experimental renderer: wterm (DOM rendering) with the libghostty WASM
 * core, wired to the same channel protocol as TerminalView. DOM rendering
 * gives native selection/copy/find; the trade-off is a younger stack —
 * mouse reporting, OSC 52 and file-paste interception are not covered yet,
 * which is why this stays behind the appearance setting.
 */
export default function WtermView({ sessionId, scrollbackLines, onCwdChange, onError, actionsRef }: Props) {
  const handleRef = useRef<TerminalHandle | null>(null);
  const channelRef = useRef<Channel | null>(null);
  const [core, setCore] = useState<GhosttyCore | null>(null);
  const [replaying, setReplaying] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const cwdChangeRef = useRef(onCwdChange);
  cwdChangeRef.current = onCwdChange;

  useEffect(() => {
    let cancelled = false;
    GhosttyCore.load({
      wasmPath: "/wasm/ghostty-vt.wasm",
      scrollbackLimit: scrollbackLines ?? 10_000,
    })
      .then((loaded) => {
        if (!cancelled) setCore(loaded);
      })
      .catch((error) => {
        if (!cancelled) setLoadError(String(error));
      });
    return () => {
      cancelled = true;
    };
    // The core is sized at load; scrollback changes apply on next mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId]);

  useEffect(() => {
    if (!core) return;

    const channel = createTerminalChannel(getSocket(), sessionId);
    const phxChannel = channel as unknown as Channel;
    channelRef.current = phxChannel;
    const gate = createStreamGate();
    let attached = false;

    const write = (data: Uint8Array | string) => handleRef.current?.write(data);

    const refs = onTerminalChannelMessages(channel, {
      replay: (payload) => {
        const { reset, release } = gate.replayBatch(payload.seq, payload.done);
        if (reset) setReplaying(true);
        const data = payload.data ? base64ToBytes(payload.data) : new Uint8Array();
        write(data);
        if (release) {
          // wterm's write path is synchronous into the WASM core; uncover on
          // the next frame so the DOM has painted the final state.
          requestAnimationFrame(() => {
            gate.replayParsed();
            setReplaying(false);
          });
        }
      },
      output: (payload) => {
        if (!gate.acceptOutput(payload.seq)) return;
        write(base64ToBytes(payload.data));
      },
      cwd: (payload) => {
        cwdChangeRef.current?.(payload.cwd);
      },
    });

    const coverTimer = window.setTimeout(() => setReplaying(false), 2500);

    phxChannel
      .join()
      .receive("ok", () => {
        gate.joined();
        const instance = handleRef.current?.instance;
        const cols = instance?.cols ?? 80;
        const rows = instance?.rows ?? 24;
        phxChannel.push("resize", { rows, cols });
        phxChannel.push("attach", { rows, cols });
        attached = true;
      })
      .receive("error", () => onError?.("could not attach to session"));

    if (actionsRef) {
      actionsRef.current = {
        reset: () => write("\x1bc"),
        refit: () => undefined,
        focus: () => handleRef.current?.focus(),
      };
    }

    return () => {
      window.clearTimeout(coverTimer);
      if (actionsRef) actionsRef.current = null;
      unsubscribeTerminalChannel(channel, refs);
      phxChannel.leave();
      void attached;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [core, sessionId]);

  if (loadError) {
    return (
      <div className="grid h-full place-items-center px-6 text-center font-mono text-xs text-fg-muted">
        wterm core failed to load: {loadError}
      </div>
    );
  }

  return (
    <div className="relative h-full w-full">
      {core && (
        <Terminal
          ref={handleRef}
          core={core}
          autoResize
          cursorBlink
          className="h-full w-full px-3 py-2 font-mono"
          onData={(data) => channelRef.current?.push("input", { data })}
          onResize={(cols, rows) => {
            channelRef.current?.push("resize", { rows, cols });
          }}
          onError={(error) => onError?.(String(error))}
        />
      )}
      <div
        className={`pointer-events-none absolute inset-0 bg-bg0 transition-opacity duration-150 ${
          replaying ? "opacity-100" : "opacity-0"
        }`}
      />
    </div>
  );
}
