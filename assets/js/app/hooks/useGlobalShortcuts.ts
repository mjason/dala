import { useEffect, useRef } from "react";
import type { RefObject } from "react";
import type { TerminalActions } from "../TerminalView";
import {
  BINDINGS,
  comboToAccelerator,
  loadBindings,
  matchCombo,
  onBindingsChange,
} from "../keybindings";

/**
 * Plain Ctrl+letter combos typed inside the terminal defer to readline
 * (Ctrl+P history, Ctrl+B backward-char) unless ⌘ or shift was used.
 */
export function deferToTerminal(
  e: Pick<KeyboardEvent, "target" | "metaKey" | "shiftKey">,
): boolean {
  const inTerminal = (e.target as HTMLElement | null)?.closest?.(".xterm");
  return Boolean(inTerminal) && !e.metaKey && !e.shiftKey;
}

/**
 * Global shortcuts, resolved through the customizable keybinding registry
 * (Settings → Shortcuts), plus the desktop client's menu accelerators and
 * notification-click jumps.
 */
export function useGlobalShortcuts(opts: {
  termActions: RefObject<TerminalActions | null>;
  qsActions: RefObject<TerminalActions | null>;
  qsRef: RefObject<{ open: boolean }>;
  quickShellRef: RefObject<() => void>;
  toggleComposerRef: RefObject<() => void>;
  voiceShortcutRef: RefObject<() => void>;
  toggleSidebar: () => void;
  openQuickOpen: () => void;
  toggleDrawer: () => void;
  toggleGit: () => void;
  onNotifyClick: (id: string) => void;
}) {
  const {
    termActions,
    qsActions,
    qsRef,
    quickShellRef,
    toggleComposerRef,
    voiceShortcutRef,
    toggleSidebar,
    openQuickOpen,
    toggleDrawer,
    toggleGit,
    onNotifyClick,
  } = opts;

  const bindingsRef = useRef(loadBindings());
  useEffect(() => onBindingsChange((map) => (bindingsRef.current = map)), []);

  // Desktop client: mirror the menu-bar shortcuts into real accelerators.
  useEffect(() => {
    const report = (map: Record<string, string>) => {
      const bridge = (
        window as { dala?: { invoke: (cmd: string, args: unknown) => Promise<unknown> } }
      ).dala;
      if (!bridge) return;
      const accelerators: Record<string, string> = {};
      for (const spec of BINDINGS) {
        if (!spec.clientMenu) continue;
        const accelerator = comboToAccelerator(map[spec.id] ?? spec.default);
        if (accelerator) accelerators[spec.id] = accelerator;
      }
      void bridge.invoke("set_shortcuts", accelerators).catch(() => undefined);
    };
    report(bindingsRef.current);
    return onBindingsChange(report);
  }, []);

  useEffect(() => {
    const actions: Record<string, (e: KeyboardEvent) => void> = {
      quickOpen: (e) => {
        if (deferToTerminal(e)) return;
        e.preventDefault();
        openQuickOpen();
      },
      sidebar: (e) => {
        if (deferToTerminal(e)) return;
        e.preventDefault();
        toggleSidebar();
      },
      quickShell: (e) => {
        e.preventDefault();
        quickShellRef.current();
      },
      focusTerminal: (e) => {
        e.preventDefault();
        (qsRef.current.open ? qsActions : termActions).current?.focus();
      },
      drawer: (e) => {
        e.preventDefault();
        toggleDrawer();
      },
      git: (e) => {
        e.preventDefault();
        toggleGit();
      },
      refit: (e) => {
        e.preventDefault();
        // Explicit user action — same takeover semantics as the button.
        termActions.current?.refit(true);
      },
      resetTerminal: (e) => {
        e.preventDefault();
        termActions.current?.reset();
      },
      composer: (e) => {
        e.preventDefault();
        toggleComposerRef.current();
      },
      voice: (e) => {
        e.preventDefault();
        voiceShortcutRef.current();
      },
      composerMention: (e) => {
        e.preventDefault();
        window.dispatchEvent(new CustomEvent("dala:action", { detail: "composerMention" }));
      },
      composerAttach: (e) => {
        e.preventDefault();
        window.dispatchEvent(new CustomEvent("dala:action", { detail: "composerAttach" }));
      },
    };

    const handler = (e: KeyboardEvent) => {
      const map = bindingsRef.current;
      for (const id of Object.keys(actions)) {
        const combo = map[id];
        if (combo && matchCombo(e, combo)) {
          actions[id](e);
          return;
        }
      }
    };
    // Desktop client menu accelerators (⌘K composer, ⌘J quick shell).
    const onMenu = (e: Event) => {
      const action = (e as CustomEvent).detail;
      if (action === "composer") toggleComposerRef.current();
      if (action === "quick-shell") quickShellRef.current();
      if (action === "voice") voiceShortcutRef.current();
    };
    // Clicking a native client notification jumps to the session it came from.
    const handleNotifyClick = (event: Event) => {
      const id = String((event as CustomEvent).detail ?? "");
      if (id) onNotifyClick(id);
    };
    window.addEventListener("dala:menu", onMenu);
    window.addEventListener("dala:notify-click", handleNotifyClick);
    window.addEventListener("keydown", handler, true);
    return () => {
      window.removeEventListener("dala:menu", onMenu);
      window.removeEventListener("dala:notify-click", handleNotifyClick);
      window.removeEventListener("keydown", handler, true);
    };
    // Registered once; every mutable dependency is read through a ref.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
}
