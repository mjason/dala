import React, { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebglAddon } from "@xterm/addon-webgl";
import type { Channel } from "phoenix";
import { getSocket } from "./socket";
import {
  createTerminalChannel,
  onTerminalChannelMessages,
  unsubscribeTerminalChannel,
} from "../ash_typed_channels";
import { base64ToBytes } from "./util";
import { createStreamGate } from "./streamGate";

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

// The one terminal font, bundled with the app (see app.css @font-face) so
// cell metrics are identical everywhere and icons never come from a
// different-width fallback font.
const FONT_FAMILY = '"JetBrainsMono NFM", monospace';
const FONT_SIZE = 14;

// Wait for the bundled font faces before the terminal measures its cell
// size — measuring against a fallback font misaligns everything drawn later.
function loadTerminalFonts(): Promise<unknown> {
  return Promise.all(
    ["", "bold ", "italic ", "bold italic "].map((variant) =>
      document.fonts.load(`${variant}${FONT_SIZE}px "JetBrainsMono NFM"`),
    ),
  ).catch(() => undefined);
}

// A "follower" client (typically a phone) watches a shared session without
// driving its size: it never sends resize, so it can't shrink the PTY for the
// desktop that owns it. Instead it renders at the server's PTY size and scales
// that down to fit its own screen. It can still type.
function isFollowerClient(): boolean {
  if (typeof window === "undefined" || !window.matchMedia) return false;
  return (
    window.matchMedia("(pointer: coarse)").matches &&
    window.matchMedia("(max-width: 820px)").matches
  );
}

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

    let disposed = false;
    let cleanup: (() => void) | undefined;

    void loadTerminalFonts().then(() => {
      if (disposed) return;

      const term = new Terminal({
        theme,
        fontFamily: FONT_FAMILY,
        fontSize: FONT_SIZE,
        lineHeight: 1.2,
        letterSpacing: 0,
        cursorBlink: true,
        cursorStyle: "bar",
        scrollback: 10000,
        allowTransparency: false,
        allowProposedApi: true,
      });
      const fit = new FitAddon();
      term.loadAddon(fit);
      term.loadAddon(new WebLinksAddon());
      term.loadAddon(new Unicode11Addon());
      term.unicode.activeVersion = "11";
      term.open(container);

      // WebGL renderer places every glyph on the exact cell grid (like VS
      // Code), which keeps full-screen apps such as vim pixel-aligned. Fall
      // back to the DOM renderer when WebGL isn't available.
      let webgl: WebglAddon | undefined;
      try {
        webgl = new WebglAddon();
        webgl.onContextLoss(() => {
          webgl?.dispose();
          webgl = undefined;
        });
        term.loadAddon(webgl);
      } catch {
        webgl = undefined;
      }

      fit.fit();
      term.focus();

      const follower = isFollowerClient();
      if (follower) {
        container.style.padding = "0";
        container.style.overflow = "auto";
      }

      // Follower only: render at the server's PTY size, then scale that down to
      // fit this screen's width (never resize the shared PTY).
      const scaleToFit = () => {
        const el = term.element;
        if (!el) return;
        el.style.transformOrigin = "top left";
        el.style.transform = "";
        const natural = el.offsetWidth;
        const avail = container.clientWidth;
        if (natural > 0 && avail > 0) {
          el.style.transform = `scale(${Math.min(1, avail / natural)})`;
        }
      };
      const applyServerSize = (rows: number, cols: number) => {
        term.resize(Math.max(cols, 1), Math.max(rows, 1));
        scaleToFit();
      };

      const channel = createTerminalChannel(getSocket(), sessionId);
      const phxChannel = channel as unknown as Channel;

      // See streamGate.ts for the replay/dedup/input-guard invariants.
      const gate = createStreamGate();

      const refs = onTerminalChannelMessages(channel, {
        replay: (payload) => {
          const { reset, release } = gate.replayBatch(payload.seq, payload.done);
          if (reset) term.reset();

          const data = payload.data ? base64ToBytes(payload.data) : "";
          if (release) {
            term.write(data, () => gate.replayParsed());
          } else {
            term.write(data);
          }
        },
        output: (payload) => {
          if (!gate.acceptOutput(payload.seq)) return;
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
        .receive("ok", (resp?: { rows?: number; cols?: number }) => {
          gate.joined();
          if (follower) {
            if (resp?.rows && resp?.cols) applyServerSize(resp.rows, resp.cols);
          } else {
            // Re-fit now that layout has settled so the PTY is the real size
            // before the user runs anything (else the first `ls` renders at the
            // default 80-col size until a later resize/repaint corrects it).
            fit.fit();
            pushResize();
          }
        })
        .receive("error", () => {
          term.writeln("\x1b[31mcould not attach to session\x1b[0m");
        });

      // Follower: track the owner's PTY size instead of driving our own.
      if (follower) {
        phxChannel.on("resize", (p: { rows: number; cols: number }) => {
          applyServerSize(p.rows, p.cols);
        });
      }

      const inputDisposable = term.onData((data) => {
        if (!gate.acceptInput()) return;
        phxChannel.push("input", { data });
      });

      let resizeTimer: number | undefined;
      const observer = new ResizeObserver(() => {
        window.clearTimeout(resizeTimer);
        resizeTimer = window.setTimeout(() => {
          if (follower) {
            scaleToFit();
          } else {
            fit.fit();
            pushResize();
          }
        }, 60);
      });
      observer.observe(container);

      cleanup = () => {
        observer.disconnect();
        window.clearTimeout(resizeTimer);
        inputDisposable.dispose();
        unsubscribeTerminalChannel(channel, refs);
        phxChannel.leave();
        term.dispose();
      };
    });

    return () => {
      disposed = true;
      cleanup?.();
    };
  }, [sessionId]);

  return <div ref={containerRef} className="h-full w-full px-3 py-2" />;
}
