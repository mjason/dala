import React from "react";

/**
 * File-type icons using Nerd Font glyphs from the bundled terminal font
 * (JetBrainsMono NFM), colored per language/type — the same visual language
 * as editor file trees.
 */

type IconSpec = { glyph: string; color: string };

const DEFAULT_FILE: IconSpec = { glyph: "", color: "text-fg-muted" }; //
const FOLDER: IconSpec = { glyph: "", color: "text-dala-info" }; //
const FOLDER_OPEN: IconSpec = { glyph: "", color: "text-dala-info" }; //  (open)

const BY_EXTENSION: Record<string, IconSpec> = {
  // languages
  ex: { glyph: "", color: "text-dala-magenta" },
  exs: { glyph: "", color: "text-dala-magenta" },
  heex: { glyph: "", color: "text-dala-magenta" },
  erl: { glyph: "", color: "text-danger" },
  js: { glyph: "", color: "text-dala-warning" },
  mjs: { glyph: "", color: "text-dala-warning" },
  cjs: { glyph: "", color: "text-dala-warning" },
  jsx: { glyph: "", color: "text-dala-cyan" },
  ts: { glyph: "", color: "text-dala-info" },
  mts: { glyph: "", color: "text-dala-info" },
  tsx: { glyph: "", color: "text-dala-info" },
  py: { glyph: "", color: "text-dala-warning" },
  rb: { glyph: "", color: "text-danger" },
  rs: { glyph: "", color: "text-dala-warning" },
  go: { glyph: "", color: "text-dala-cyan" },
  java: { glyph: "", color: "text-danger" },
  kt: { glyph: "", color: "text-dala-magenta" },
  c: { glyph: "", color: "text-dala-info" },
  h: { glyph: "", color: "text-dala-info" },
  cpp: { glyph: "", color: "text-dala-info" },
  cc: { glyph: "", color: "text-dala-info" },
  hpp: { glyph: "", color: "text-dala-info" },
  cs: { glyph: "", color: "text-dala-magenta" },
  php: { glyph: "", color: "text-dala-info" },
  swift: { glyph: "", color: "text-dala-warning" },
  lua: { glyph: "", color: "text-dala-info" },
  sh: { glyph: "", color: "text-dala-success" },
  bash: { glyph: "", color: "text-dala-success" },
  zsh: { glyph: "", color: "text-dala-success" },
  fish: { glyph: "", color: "text-dala-success" },

  // web / markup
  html: { glyph: "", color: "text-danger" },
  htm: { glyph: "", color: "text-danger" },
  css: { glyph: "", color: "text-dala-info" },
  scss: { glyph: "", color: "text-dala-magenta" },
  sass: { glyph: "", color: "text-dala-magenta" },
  vue: { glyph: "", color: "text-dala-success" },
  svelte: { glyph: "", color: "text-danger" },
  md: { glyph: "", color: "text-dala-info" },
  markdown: { glyph: "", color: "text-dala-info" },

  // data / config
  json: { glyph: "", color: "text-dala-warning" },
  jsonc: { glyph: "", color: "text-dala-warning" },
  yaml: { glyph: "", color: "text-fg-muted" },
  yml: { glyph: "", color: "text-fg-muted" },
  toml: { glyph: "", color: "text-fg-muted" },
  ini: { glyph: "", color: "text-fg-muted" },
  conf: { glyph: "", color: "text-fg-muted" },
  env: { glyph: "", color: "text-fg-muted" },
  csv: { glyph: "", color: "text-dala-success" },
  tsv: { glyph: "", color: "text-dala-success" },
  sql: { glyph: "", color: "text-dala-info" },
  db: { glyph: "", color: "text-dala-info" },
  sqlite: { glyph: "", color: "text-dala-info" },
  xml: { glyph: "", color: "text-dala-warning" },
  svg: { glyph: "", color: "text-dala-magenta" },

  // media / archives / docs
  png: { glyph: "", color: "text-dala-magenta" },
  jpg: { glyph: "", color: "text-dala-magenta" },
  jpeg: { glyph: "", color: "text-dala-magenta" },
  gif: { glyph: "", color: "text-dala-magenta" },
  webp: { glyph: "", color: "text-dala-magenta" },
  ico: { glyph: "", color: "text-dala-magenta" },
  mp4: { glyph: "", color: "text-dala-magenta" },
  mkv: { glyph: "", color: "text-dala-magenta" },
  mp3: { glyph: "", color: "text-dala-magenta" },
  wav: { glyph: "", color: "text-dala-magenta" },
  pdf: { glyph: "", color: "text-danger" },
  zip: { glyph: "", color: "text-dala-warning" },
  gz: { glyph: "", color: "text-dala-warning" },
  tar: { glyph: "", color: "text-dala-warning" },
  "7z": { glyph: "", color: "text-dala-warning" },

  // misc
  lock: { glyph: "", color: "text-fg-muted" },
  log: { glyph: "", color: "text-fg-muted" },
  txt: { glyph: "", color: "text-fg-muted" },
  rst: { glyph: "", color: "text-fg-muted" },
};

const BY_NAME: Record<string, IconSpec> = {
  dockerfile: { glyph: "", color: "text-dala-info" },
  makefile: { glyph: "", color: "text-dala-warning" },
  "mix.lock": { glyph: "", color: "text-dala-magenta" },
  "package.json": { glyph: "", color: "text-danger" },
  "package-lock.json": { glyph: "", color: "text-fg-muted" },
  "cargo.toml": { glyph: "", color: "text-dala-warning" },
  ".gitignore": { glyph: "", color: "text-danger" },
  ".gitattributes": { glyph: "", color: "text-danger" },
  license: { glyph: "", color: "text-dala-warning" },
  "readme.md": { glyph: "", color: "text-dala-info" },
  ".zshrc": { glyph: "", color: "text-dala-success" },
  ".bashrc": { glyph: "", color: "text-dala-success" },
  ".env": { glyph: "", color: "text-fg-muted" },
};

/** Icon spec for a file or directory name (exported for tests). */
export function fileIcon(name: string, isDir = false, isOpen = false): IconSpec {
  if (isDir) return isOpen ? FOLDER_OPEN : FOLDER;

  const base = name.split("/").pop()?.toLowerCase() ?? "";
  if (BY_NAME[base]) return BY_NAME[base];

  const ext = base.includes(".") ? base.split(".").pop()! : "";
  return BY_EXTENSION[ext] ?? DEFAULT_FILE;
}

type Props = {
  name: string;
  isDir?: boolean;
  isOpen?: boolean;
  className?: string;
};

export function FileTypeIcon({ name, isDir = false, isOpen = false, className = "" }: Props) {
  const { glyph, color } = fileIcon(name, isDir, isOpen);

  return (
    <span
      aria-hidden
      className={`inline-block w-4 shrink-0 text-center text-[13px] leading-none ${color} ${className}`}
      style={{ fontFamily: '"JetBrainsMono NFM", monospace' }}
    >
      {glyph}
    </span>
  );
}
