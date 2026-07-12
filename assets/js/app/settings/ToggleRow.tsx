import React from "react";
import { Toggle } from "../ui";

export default function ToggleRow({
  id,
  label,
  checked,
  onChange,
}: {
  id: string;
  label: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <label
      className="flex cursor-pointer items-center justify-between gap-3 px-3 py-2 transition-colors hover:bg-bg2/40"
      onClick={(e) => {
        e.preventDefault();
        onChange(!checked);
      }}
    >
      <span className="text-[13px] text-fg">{label}</span>
      <Toggle id={id} checked={checked} onChange={onChange} />
    </label>
  );
}
