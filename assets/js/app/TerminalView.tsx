import React, { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import type { Channel } from "phoenix";
import { getSocket } from "./socket";
import {
  createTerminalChannel,
  onTerminalChannelMessages,
  unsubscribeTerminalChannel,
} from "../ash_typed_channels";
import type { TerminalChannel } from "../ash_types";
import { base64ToBytes } from "./util";

const theme = {
  background: "#0b0c0e",
  foreground: "#d7dde3",
  cursor: "#4cc38a",
  cursorAccent: "#0b0c0e",
  selectionBackground: "#2d3f4d",
  black: "#1a1d21",
  red: "#e5716e",
  green: "#5fbf87",
  yellow: "#d9a860",
  blue: "#6d9fd6",
  magenta: "#b087c9",
  cyan: "#5fb8b8",
  white: "#c9ced4",
  brightBlack: "#5b626b",
  brightRed: "#f0928f",
  brightGreen: "#7fd6a3",
  brightYellow: "#ecc57f",
  brightBlue: "#8fb8e8",
  brightMagenta: "#c9a5dd",
  brightCyan: "#7fd0d0",
  brightWhite: "#e6e8eb",
};

type Props = {
  sessionId: string;
  onCwdChange?: (cwd: string) => void;
};

export default function TerminalView({ sessionId, onCwdChange }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const cwdChangeRef = useRef(onCwdChange);
  cwdChangeRef.current = onCwdChange;

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const term = new Terminal({
      theme,
      fontFamily:
        '"JetBrains Mono", "Cascadia Code", "SF Mono", Menlo, Consolas, "Liberation Mono", monospace',
      fontSize: 13,
      lineHeight: 1.25,
      letterSpacing: 0,
      cursorBlink: true,
      cursorStyle: "bar",
      scrollback: 10000,
      allowTransparency: false,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.loadAddon(new WebLinksAddon());
    term.open(container);
    fit.fit();
    term.focus();

    const channel = createTerminalChannel(getSocket(), sessionId);
    const phxChannel = channel as unknown as Channel;

    // The server pushes the whole DETS scrollback as `replay` batches after
    // every (re)join; the first batch resets the terminal so a reconnect
    // repaints from a clean slate. `seq` dedupes the overlap between the
    // replay snapshot and live `output` broadcasts.
    let awaitingReplay = true;
    let lastSeq = -1;

    const refs = onTerminalChannelMessages(channel, {
      replay: (payload) => {
        if (awaitingReplay) {
          term.reset();
          awaitingReplay = false;
        }
        if (payload.data) term.write(base64ToBytes(payload.data));
        if (payload.seq > lastSeq) lastSeq = payload.seq;
      },
      output: (payload) => {
        if (payload.seq <= lastSeq) return;
        lastSeq = payload.seq;
        term.write(base64ToBytes(payload.data));
      },
      cwd: (payload) => {
        cwdChangeRef.current?.(payload.cwd);
      },
    });

    const pushResize = () => {
      phxChannel.push("resize", { rows: term.rows, cols: term.cols });
    };

    phxChannel
      .join()
      .receive("ok", () => {
        awaitingReplay = true;
        pushResize();
      })
      .receive("error", () => {
        term.writeln("\x1b[31mcould not attach to session\x1b[0m");
      });

    const inputDisposable = term.onData((data) => {
      phxChannel.push("input", { data });
    });

    let resizeTimer: number | undefined;
    const observer = new ResizeObserver(() => {
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        fit.fit();
        pushResize();
      }, 60);
    });
    observer.observe(container);

    return () => {
      observer.disconnect();
      window.clearTimeout(resizeTimer);
      inputDisposable.dispose();
      unsubscribeTerminalChannel(channel, refs);
      phxChannel.leave();
      term.dispose();
    };
  }, [sessionId]);

  return <div ref={containerRef} className="h-full w-full px-3 py-2" />;
}
