import { useEffect, useState } from "react";

export const clampWidth = (value: number, min: number, max: number) =>
  Math.min(Math.max(Math.round(value), min), Math.max(min, max));

/** Default panel widths in px (352 = the former w-[22rem]). */
export const PANEL_W = { sidebar: 256, qs: 800, drawer: 352, git: 352 };

/**
 * Draggable panel widths, remembered per browser. Double-clicking a
 * handle resets that panel; settings has a reset-all button (it fires
 * the dala:reset-layout event).
 */
export function usePanelLayout() {
  const [sidebarW, setSidebarW] = useState(() =>
    clampWidth(Number(localStorage.getItem("dala:sidebar-w")) || PANEL_W.sidebar, 180, 440),
  );
  const [qsW, setQsW] = useState(() =>
    clampWidth(
      Number(localStorage.getItem("dala:qs-w")) || PANEL_W.qs,
      380,
      window.innerWidth - 160,
    ),
  );
  const [drawerW, setDrawerW] = useState(() =>
    clampWidth(Number(localStorage.getItem("dala:drawer-w")) || PANEL_W.drawer, 260, 720),
  );
  const [gitW, setGitW] = useState(() =>
    clampWidth(Number(localStorage.getItem("dala:git-w")) || PANEL_W.git, 280, 800),
  );
  useEffect(() => localStorage.setItem("dala:sidebar-w", String(sidebarW)), [sidebarW]);
  useEffect(() => localStorage.setItem("dala:qs-w", String(qsW)), [qsW]);
  useEffect(() => localStorage.setItem("dala:drawer-w", String(drawerW)), [drawerW]);
  useEffect(() => localStorage.setItem("dala:git-w", String(gitW)), [gitW]);
  useEffect(() => {
    const reset = () => {
      setSidebarW(PANEL_W.sidebar);
      setQsW(PANEL_W.qs);
      setDrawerW(PANEL_W.drawer);
      setGitW(PANEL_W.git);
    };
    window.addEventListener("dala:reset-layout", reset);
    return () => window.removeEventListener("dala:reset-layout", reset);
  }, []);

  return { sidebarW, setSidebarW, qsW, setQsW, drawerW, setDrawerW, gitW, setGitW };
}
