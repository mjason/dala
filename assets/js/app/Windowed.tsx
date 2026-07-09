import React, { useCallback, useEffect, useState } from "react";
import { useI18n } from "./i18n";
import { isTopWindow, Kbd, popWindow, pushWindow } from "./shortcuts";

export type WindowMode = "center" | "full" | "left" | "right";

const STORAGE_KEY = "dala:window-mode";

function initialMode(): WindowMode {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "center" || stored === "full" || stored === "left" || stored === "right") {
      return stored;
    }
  } catch {
    // storage unavailable
  }
  return "center";
}

export function useWindowMode(): [WindowMode, (mode: WindowMode) => void] {
  const [mode, setModeState] = useState<WindowMode>(initialMode);

  const setMode = useCallback((next: WindowMode) => {
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      // best effort
    }
    setModeState(next);
  }, []);

  return [mode, setMode];
}

// Docked modes have no backdrop so the terminal next to them stays usable.
const FRAMES: Record<WindowMode, { overlay: string; panel: string; backdrop: boolean }> = {
  center: {
    overlay: "fixed inset-0 z-40 grid place-items-center bg-black/60 p-3 sm:p-6",
    panel: "w-full max-w-5xl max-h-full h-auto sm:max-h-[88vh]",
    backdrop: true,
  },
  full: {
    overlay: "fixed inset-0 z-40 bg-black/60 p-1.5 sm:p-3",
    panel: "h-full w-full",
    backdrop: true,
  },
  left: {
    overlay: "fixed inset-y-0 left-0 z-40 max-md:inset-0",
    panel: "h-full w-[46vw] min-w-[24rem] max-md:w-full max-md:min-w-0 rounded-none border-r",
    backdrop: false,
  },
  right: {
    overlay: "fixed inset-y-0 right-0 z-40 max-md:inset-0",
    panel: "h-full w-[46vw] min-w-[24rem] max-md:w-full max-md:min-w-0 rounded-none border-l",
    backdrop: false,
  },
};

type Props = {
  id: string;
  onClose: () => void;
  /** Left side of the title bar (path, badges, …). */
  title: React.ReactNode;
  /** Extra action buttons rendered before the window-mode switcher. */
  actions?: React.ReactNode;
  children: React.ReactNode;
};

/**
 * Window chrome shared by the previews: a titlebar with actions plus a
 * window-mode switcher — centered dialog, fullscreen, or docked to either
 * side (docked windows leave the terminal interactive).
 */
export default function Windowed({ id, onClose, title, actions, children }: Props) {
  const [mode, setMode] = useWindowMode();
  const { t } = useI18n();
  const frame = FRAMES[mode];

  const onCloseRef = React.useRef(onClose);
  onCloseRef.current = onClose;

  // Escape closes the topmost window. Handlers inside (e.g. CodeMirror's
  // search panel) run first and preventDefault when Escape is theirs.
  useEffect(() => {
    const token = pushWindow();
    const handler = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented || !isTopWindow(token)) return;
      e.preventDefault();
      onCloseRef.current();
    };
    window.addEventListener("keydown", handler);
    return () => {
      window.removeEventListener("keydown", handler);
      popWindow(token);
    };
  }, []);

  return (
    <div className={frame.overlay} onClick={frame.backdrop ? onClose : undefined}>
      <div
        id={id}
        data-window-mode={mode}
        className={`flex flex-col overflow-hidden rounded-xl border border-line bg-bg1 shadow-2xl ${frame.panel}`}
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex items-center gap-2 border-b border-line px-3 py-2 sm:px-4">
          <div className="flex min-w-0 flex-1 items-center gap-3">{title}</div>
          {actions}
          <WindowModeSwitcher mode={mode} setMode={setMode} />
          <button
            onClick={onClose}
            title={`${t("close")} · Esc`}
            className="flex h-6 shrink-0 items-center gap-1 rounded px-1 text-fg-muted hover:text-fg"
          >
            <span className="hidden sm:inline">
              <Kbd>Esc</Kbd>
            </span>
            <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
              <path d="M4 4l8 8M12 4l-8 8" strokeLinecap="round" />
            </svg>
          </button>
        </header>
        {children}
      </div>
    </div>
  );
}

function WindowModeSwitcher({
  mode,
  setMode,
}: {
  mode: WindowMode;
  setMode: (mode: WindowMode) => void;
}) {
  const { t } = useI18n();

  const options: { value: WindowMode; label: string; icon: React.ReactNode }[] = [
    { value: "left", label: t("windowLeft"), icon: <DockIcon side="left" /> },
    { value: "center", label: t("windowCenter"), icon: <CenterIcon /> },
    { value: "right", label: t("windowRight"), icon: <DockIcon side="right" /> },
    { value: "full", label: t("windowFull"), icon: <FullIcon /> },
  ];

  return (
    <div className="hidden shrink-0 items-center gap-0.5 rounded-md border border-line p-0.5 sm:flex">
      {options.map((option) => (
        <button
          key={option.value}
          data-window-mode-button={option.value}
          onClick={() => setMode(option.value)}
          className={`grid h-5 w-6 place-items-center rounded transition-colors ${
            mode === option.value ? "bg-bg2 text-mint" : "text-fg-muted hover:text-fg"
          }`}
          title={option.label}
        >
          {option.icon}
        </button>
      ))}
    </div>
  );
}

function DockIcon({ side }: { side: "left" | "right" }) {
  const x = side === "left" ? 2.5 : 8.5;
  return (
    <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.2">
      <rect x="1.5" y="3" width="13" height="10" rx="1.5" />
      <rect x={x} y="4.5" width="5" height="7" rx="0.8" fill="currentColor" stroke="none" />
    </svg>
  );
}

function CenterIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.2">
      <rect x="1.5" y="3" width="13" height="10" rx="1.5" />
      <rect x="5" y="5.5" width="6" height="5" rx="0.8" fill="currentColor" stroke="none" />
    </svg>
  );
}

function FullIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.3">
      <path d="M6 2.5H2.5V6M10 2.5h3.5V6M6 13.5H2.5V10M10 13.5h3.5V10" strokeLinecap="round" />
    </svg>
  );
}
