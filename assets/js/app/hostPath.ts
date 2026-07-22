export type HostBreadcrumb = { label: string; path: string };

type ParsedPath = {
  windows: boolean;
  separator: "/" | "\\";
  root: string;
  rootLabel: string;
  parts: string[];
};

function parse(path: string): ParsedPath {
  const drive = /^([A-Za-z]:)([\\/]|$)/.exec(path);
  if (drive) {
    const separator = path.includes("\\") ? "\\" : "/";
    const rest = path.slice(drive[0].length).split(/[\\/]+/).filter(Boolean);
    return {
      windows: true,
      separator,
      root: `${drive[1]}${separator}`,
      rootLabel: `${drive[1]}${separator}`,
      parts: rest,
    };
  }

  const unc = /^[\\/]{2}([^\\/]+)[\\/]([^\\/]+)/.exec(path);
  if (unc) {
    const separator = path.startsWith("\\") ? "\\" : "/";
    const root = `${separator}${separator}${unc[1]}${separator}${unc[2]}`;
    const rest = path.slice(unc[0].length).split(/[\\/]+/).filter(Boolean);
    return { windows: true, separator, root, rootLabel: root, parts: rest };
  }

  if (path.startsWith("/")) {
    return {
      windows: false,
      separator: "/",
      root: "/",
      rootLabel: "/",
      parts: path.split("/").filter(Boolean),
    };
  }

  const windows = path.includes("\\");
  const separator = windows ? "\\" : "/";
  return {
    windows,
    separator,
    root: "",
    rootLabel: "",
    parts: path.split(/[\\/]+/).filter(Boolean),
  };
}

function assemble(parsed: ParsedPath, parts: string[]): string {
  if (!parsed.root) return parts.join(parsed.separator) || ".";
  if (parts.length === 0) return parsed.root;
  const needsSeparator = !parsed.root.endsWith(parsed.separator);
  return `${parsed.root}${needsSeparator ? parsed.separator : ""}${parts.join(parsed.separator)}`;
}

export function isAbsoluteHost(path: string): boolean {
  return path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(path) || /^[\\/]{2}[^\\/]/.test(path);
}

export function joinHost(dir: string, name: string): string {
  const parsed = parse(dir);
  const clean = name.replace(/^[\\/]+/, "");
  if (parsed.root && parsed.parts.length === 0) return assemble(parsed, [clean]);
  return `${dir.replace(/[\\/]+$/, "")}${parsed.separator}${clean}`;
}

export function dirnameHost(path: string): string {
  const parsed = parse(path);
  if (parsed.parts.length === 0) return parsed.root || ".";
  return assemble(parsed, parsed.parts.slice(0, -1));
}

export function basenameHost(path: string): string {
  const parsed = parse(path.replace(/[\\/]+$/, ""));
  return parsed.parts.at(-1) ?? parsed.rootLabel;
}

export function hostPathKey(path: string): string {
  const slashNormalized = path.replaceAll("\\", "/");
  if (/^[A-Za-z]:\/?$/.test(slashNormalized)) {
    return `${slashNormalized[0].toLowerCase()}:/`;
  }
  const normalized = slashNormalized.replace(/\/+$/, "") || "/";
  return /^[A-Za-z]:\//.test(normalized) || normalized.startsWith("//")
    ? normalized.toLowerCase()
    : normalized;
}

export function relativeHost(from: string, to: string): string {
  const source = parse(from);
  const target = parse(to);
  const sourceRoot = source.windows
    ? source.root.replaceAll("\\", "/").toLowerCase()
    : source.root;
  const targetRoot = target.windows
    ? target.root.replaceAll("\\", "/").toLowerCase()
    : target.root;
  if (source.windows !== target.windows || sourceRoot !== targetRoot) {
    return to;
  }

  let index = 0;
  while (index < source.parts.length && index < target.parts.length) {
    const left = source.windows ? source.parts[index].toLowerCase() : source.parts[index];
    const right = target.windows ? target.parts[index].toLowerCase() : target.parts[index];
    if (left !== right) break;
    index += 1;
  }
  const parts = [...Array(source.parts.length - index).fill(".."), ...target.parts.slice(index)];
  return parts.length ? parts.join(target.separator) : ".";
}

export function breadcrumbsHost(path: string): HostBreadcrumb[] {
  const parsed = parse(path);
  if (!parsed.root) return [];
  const crumbs: HostBreadcrumb[] = [{ label: parsed.rootLabel, path: parsed.root }];
  for (let index = 0; index < parsed.parts.length; index += 1) {
    crumbs.push({
      label: parsed.parts[index],
      path: assemble(parsed, parsed.parts.slice(0, index + 1)),
    });
  }
  return crumbs;
}

function encodeSegments(path: string): string {
  return path
    .split("/")
    .map((segment) => encodeURIComponent(segment))
    .join("/");
}

export function toFileUri(path: string): string {
  const normalized = path.replaceAll("\\", "/");
  if (/^[A-Za-z]:\//.test(normalized)) {
    const drive = normalized.slice(0, 2);
    return `file:///${drive}/${encodeSegments(normalized.slice(3))}`;
  }
  if (normalized.startsWith("//")) {
    const [host, ...rest] = normalized.slice(2).split("/");
    return `file://${host}/${encodeSegments(rest.join("/"))}`;
  }
  return `file://${encodeSegments(normalized)}`;
}
