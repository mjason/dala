import React from "react";
import { useI18n } from "./i18n";

type Props = {
  /** Which edge of the (relatively positioned) resizable box this sits on. */
  edge: "left" | "right";
  /** Receives the pointer's clientX while dragging; the owner converts it
   * into a width and clamps it. */
  onResize: (clientX: number) => void;
  /** Double-click restores the panel's default width. */
  onReset?: () => void;
  title?: string;
  id?: string;
};

/** A slim draggable divider for resizing panels (sidebar, drawers, …). */
export default function ResizeHandle({ edge, onResize, onReset, title, id }: Props) {
  const { t } = useI18n();

  return (
    <div
      id={id}
      title={title ?? (onReset ? t("dblclickReset") : undefined)}
      onDoubleClick={onReset}
      className={`absolute inset-y-0 z-20 hidden w-1.5 cursor-col-resize transition-colors hover:bg-mint/40 active:bg-mint/60 md:block ${
        edge === "left" ? "-left-0.5" : "-right-0.5"
      }`}
      onPointerDown={(e) => {
        e.preventDefault();
        const el = e.currentTarget;
        el.setPointerCapture(e.pointerId);
        document.body.classList.add("select-none");
        const move = (ev: PointerEvent) => onResize(ev.clientX);
        const up = (ev: PointerEvent) => {
          el.releasePointerCapture(ev.pointerId);
          document.body.classList.remove("select-none");
          el.removeEventListener("pointermove", move);
          el.removeEventListener("pointerup", up);
        };
        el.addEventListener("pointermove", move);
        el.addEventListener("pointerup", up);
      }}
    />
  );
}
