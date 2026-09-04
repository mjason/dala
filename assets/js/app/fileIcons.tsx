import React from "react";

/**
 * File-type icons use Nerd Font glyphs from the bundled JetBrains fallback,
 * colored per language/type — the same visual language as editor file trees.
 */

type IconSpec = { glyph: string; color: string };

const DEFAULT_FILE: IconSpec = { glyph: "", color: "text-fg-muted" }; //
const FOLDER: IconSpec = { glyph: "", color: "text-[#6d9fd6]" }; //
const FOLDER_OPEN: IconSpec = { glyph: "", color: "text-[#6d9fd6]" }; //  (open)

const BY_EXTENSION: Record<string, IconSpec> = {
  // languages
  ex: { glyph: "", color: "text-[#b087c9]" },
  exs: { glyph: "", color: "text-[#b087c9]" },
  heex: { glyph: "", color: "text-[#b087c9]" },
  erl: { glyph: "", color: "text-[#e5716e]" },
  js: { glyph: "", color: "text-[#ecc57f]" },
  mjs: { glyph: "", color: "text-[#ecc57f]" },
  cjs: { glyph: "", color: "text-[#ecc57f]" },
  jsx: { glyph: "", color: "text-[#7fd0d0]" },
  ts: { glyph: "", color: "text-[#6d9fd6]" },
  mts: { glyph: "", color: "text-[#6d9fd6]" },
  tsx: { glyph: "", color: "text-[#6d9fd6]" },
  py: { glyph: "", color: "text-[#d9a860]" },
  rb: { glyph: "", color: "text-[#e5716e]" },
  rs: { glyph: "", color: "text-[#d9a860]" },
  go: { glyph: "", color: "text-[#7fd0d0]" },
  java: { glyph: "", color: "text-[#e5716e]" },
  kt: { glyph: "", color: "text-[#b087c9]" },
  c: { glyph: "", color: "text-[#6d9fd6]" },
  h: { glyph: "", color: "text-[#8fb8e8]" },
  cpp: { glyph: "", color: "text-[#6d9fd6]" },
  cc: { glyph: "", color: "text-[#6d9fd6]" },
  hpp: { glyph: "", color: "text-[#8fb8e8]" },
  cs: { glyph: "", color: "text-[#b087c9]" },
  php: { glyph: "", color: "text-[#8fb8e8]" },
  swift: { glyph: "", color: "text-[#d9a860]" },
  lua: { glyph: "", color: "text-[#6d9fd6]" },
  sh: { glyph: "", color: "text-[#5fbf87]" },
  bash: { glyph: "", color: "text-[#5fbf87]" },
  zsh: { glyph: "", color: "text-[#5fbf87]" },
  fish: { glyph: "", color: "text-[#5fbf87]" },

  // web / markup
  html: { glyph: "", color: "text-[#e5716e]" },
  htm: { glyph: "", color: "text-[#e5716e]" },
  css: { glyph: "", color: "text-[#6d9fd6]" },
  scss: { glyph: "", color: "text-[#c9a5dd]" },
  sass: { glyph: "", color: "text-[#c9a5dd]" },
  vue: { glyph: "", color: "text-[#5fbf87]" },
  svelte: { glyph: "", color: "text-[#e5716e]" },
  md: { glyph: "", color: "text-[#8fb8e8]" },
  markdown: { glyph: "", color: "text-[#8fb8e8]" },

  // data / config
  json: { glyph: "", color: "text-[#ecc57f]" },
  jsonc: { glyph: "", color: "text-[#ecc57f]" },
  yaml: { glyph: "", color: "text-fg-muted" },
  yml: { glyph: "", color: "text-fg-muted" },
  toml: { glyph: "", color: "text-fg-muted" },
  ini: { glyph: "", color: "text-fg-muted" },
  conf: { glyph: "", color: "text-fg-muted" },
  env: { glyph: "", color: "text-fg-muted" },
  csv: { glyph: "", color: "text-[#5fbf87]" },
  tsv: { glyph: "", color: "text-[#5fbf87]" },
  xlsx: { glyph: "", color: "text-[#5fbf87]" },
  xlsm: { glyph: "", color: "text-[#5fbf87]" },
  sql: { glyph: "", color: "text-[#8fb8e8]" },
  db: { glyph: "", color: "text-[#8fb8e8]" },
  sqlite: { glyph: "", color: "text-[#8fb8e8]" },
  xml: { glyph: "", color: "text-[#d9a860]" },
  svg: { glyph: "", color: "text-[#c9a5dd]" },

  // media / archives / docs
  png: { glyph: "", color: "text-[#c9a5dd]" },
  jpg: { glyph: "", color: "text-[#c9a5dd]" },
  jpeg: { glyph: "", color: "text-[#c9a5dd]" },
  gif: { glyph: "", color: "text-[#c9a5dd]" },
  webp: { glyph: "", color: "text-[#c9a5dd]" },
  ico: { glyph: "", color: "text-[#c9a5dd]" },
  mp4: { glyph: "", color: "text-[#c9a5dd]" },
  mkv: { glyph: "", color: "text-[#c9a5dd]" },
  mp3: { glyph: "", color: "text-[#c9a5dd]" },
  wav: { glyph: "", color: "text-[#c9a5dd]" },
  pdf: { glyph: "", color: "text-[#e5716e]" },
  zip: { glyph: "", color: "text-[#d9a860]" },
  gz: { glyph: "", color: "text-[#d9a860]" },
  tar: { glyph: "", color: "text-[#d9a860]" },
  "7z": { glyph: "", color: "text-[#d9a860]" },

  // misc
  lock: { glyph: "", color: "text-fg-muted" },
  log: { glyph: "", color: "text-fg-muted" },
  txt: { glyph: "", color: "text-fg-muted" },
  rst: { glyph: "", color: "text-fg-muted" },
};

const BY_NAME: Record<string, IconSpec> = {
  dockerfile: { glyph: "", color: "text-[#6d9fd6]" },
  makefile: { glyph: "", color: "text-[#d9a860]" },
  "mix.lock": { glyph: "", color: "text-[#b087c9]" },
  "package.json": { glyph: "", color: "text-[#e5716e]" },
  "package-lock.json": { glyph: "", color: "text-fg-muted" },
  "cargo.toml": { glyph: "", color: "text-[#d9a860]" },
  ".gitignore": { glyph: "", color: "text-[#e5716e]" },
  ".gitattributes": { glyph: "", color: "text-[#e5716e]" },
  license: { glyph: "", color: "text-[#d9a860]" },
  "readme.md": { glyph: "", color: "text-[#8fb8e8]" },
  ".zshrc": { glyph: "", color: "text-[#5fbf87]" },
  ".bashrc": { glyph: "", color: "text-[#5fbf87]" },
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
