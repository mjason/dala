import type { Extension, Text } from "@codemirror/state";
import { ViewPlugin, hoverTooltip, type Tooltip } from "@codemirror/view";
import { autocompletion, type Completion, type CompletionContext } from "@codemirror/autocomplete";
import { setDiagnostics, type Diagnostic } from "@codemirror/lint";
import { marked } from "marked";
import { LanguageServerClient, WebSocketTransport } from "codemirror-languageserver";
import { buildCSRFHeaders, lspServers } from "../../ash_rpc";

export type LspServerInfo = {
  id: number;
  name: string;
  initializationOptions?: Record<string, unknown> | null;
  settings?: Record<string, unknown> | null;
};

/**
 * Resolves the servers for an absolute path (venv-local installs, dm lsp,
 * .dala/lsp.json — see Dala.Lsp.Discovery) and builds the extensions.
 * Returns null when the file has no language or no servers installed.
 */
export async function lspExtensionsFor(
  path: string,
  readOnly = false,
): Promise<Extension[] | null> {
  if (!path.startsWith("/")) return null;
  const result = await lspServers({
    input: { path },
    fields: ["root", "language", "servers"] as never,
    headers: buildCSRFHeaders(),
  });
  if (!result.success) return null;
  const data = result.data as unknown as {
    root: string;
    language: string | null;
    servers: LspServerInfo[];
  };
  if (!data.language || data.servers.length === 0) return null;
  return lspExtensions({
    root: data.root,
    path,
    language: data.language,
    servers: data.servers,
    readOnly,
  });
}

type LspTarget = {
  root: string;
  path: string;
  language: string;
  servers: LspServerInfo[];
  /** Preview mode: hover + diagnostics only, no completion. */
  readOnly?: boolean;
};

type Client = InstanceType<typeof LanguageServerClient>;

type ClientHandle = {
  serverId: number;
  client: Client;
  settings: Record<string, unknown> | null;
  ready: () => boolean;
  capabilities: () => Record<string, unknown> | undefined;
  whenInitialized: () => Promise<void>;
};

type LspDiagnostic = {
  message?: string;
  severity?: number;
  range?: { start?: { line: number; character: number }; end?: { line: number; character: number } };
};

/**
 * LSP support for the file editor and preview: one client per language
 * server, all attached to the same document (e.g. basedpyright for Python
 * itself plus dark-magician's `dm lsp` for the DSL inside ctx.dsl("...")).
 *
 * Everything is hand-rolled multi-client on purpose. The upstream plugin
 * can't do multi-server at all: CodeMirror's viewPlugin facet DROPS duplicate
 * instances of the same ViewPlugin, so a second `languageServerPlugin.of()`
 * silently never runs (its server would get initialize but no didOpen — dm
 * lsp answered every hover with "unknown document" this way), and its
 * hover/completion resolve `view.plugin(...)`, which only returns the first
 * instance anyway. So: one sync ViewPlugin of our own managing ALL clients,
 * merged diagnostics, aggregated hover and completion.
 */
export function lspExtensions({
  root,
  path,
  language,
  servers,
  readOnly = false,
}: LspTarget): Extension[] {
  const rootUri = `file://${root}`;
  const documentUri = `file://${path}`;
  const workspaceFolders = [{ uri: rootUri, name: root.split("/").pop() ?? root }];
  const wsProto = window.location.protocol === "https:" ? "wss" : "ws";

  const handles: ClientHandle[] = servers.map((server) => {
    const serverUri =
      `${wsProto}://${window.location.host}/lsp/ws` +
      `?root=${encodeURIComponent(root)}&path=${encodeURIComponent(path)}` +
      `&server=${server.id}`;
    const transport = new WebSocketTransport(serverUri as `ws://${string}`);
    const client = new LanguageServerClient({
      transport,
      rootUri,
      workspaceFolders,
      documentUri,
      languageId: language,
      autoClose: false,
      // dala.jsonc's per-server "initializationOptions" — sent verbatim in
      // the LSP initialize request.
      initializationOptions: server.initializationOptions ?? null,
    });
    const loose = client as unknown as {
      ready?: boolean;
      capabilities?: Record<string, unknown>;
      initializePromise?: Promise<void>;
    };
    return {
      serverId: server.id,
      client,
      settings: server.settings ?? null,
      ready: () => Boolean(loose.ready),
      capabilities: () => loose.capabilities,
      whenInitialized: () => loose.initializePromise ?? Promise.resolve(),
    };
  });

  const syncPlugin = ViewPlugin.define((view) => {
    const latest = new Map<number, LspDiagnostic[]>();
    let version = 1;
    let disposed = false;

    const applyDiagnostics = () => {
      if (disposed) return;
      const merged = [...latest.values()].flat();
      const diagnostics: Diagnostic[] = [];
      for (const item of merged) {
        const from = posToOffset(view.state.doc, item.range?.start);
        const to = posToOffset(view.state.doc, item.range?.end);
        if (from == null || to == null) continue;
        diagnostics.push({
          from,
          to: Math.max(from, to),
          severity: item.severity === 1 ? "error" : item.severity === 2 ? "warning" : "info",
          message: item.message ?? "",
        });
      }
      diagnostics.sort((a, b) => a.from - b.from);
      view.dispatch(setDiagnostics(view.state, diagnostics));
    };

    for (const handle of handles) {
      // Diagnostics are push-only; intercept them at the client and render
      // the union of every server's latest report.
      type Notification = {
        method?: string;
        params?: { uri?: string; diagnostics?: LspDiagnostic[] };
      };
      (handle.client as unknown as { processNotification: (n: Notification) => void })
        .processNotification = (notification) => {
        if (
          notification?.method === "textDocument/publishDiagnostics" &&
          notification.params?.uri === documentUri
        ) {
          latest.set(handle.serverId, notification.params.diagnostics ?? []);
          applyDiagnostics();
        }
      };

      void handle.whenInitialized().then(() => {
        if (disposed) return;
        if (handle.settings) {
          // dala.jsonc's per-server "settings" — servers pick these up via
          // workspace/didChangeConfiguration (pyright, basedpyright, …).
          (handle.client as unknown as { notify: (m: string, p: unknown) => void }).notify(
            "workspace/didChangeConfiguration",
            { settings: handle.settings },
          );
        }
        handle.client.textDocumentDidOpen({
          textDocument: {
            uri: documentUri,
            languageId: language,
            version,
            text: view.state.doc.toString(),
          },
        });
      });
    }

    return {
      update(update: { docChanged: boolean; state: { doc: Text } }) {
        if (!update.docChanged) return;
        version += 1;
        const text = update.state.doc.toString();
        for (const handle of handles) {
          if (!handle.ready()) continue;
          handle.client.textDocumentDidChange({
            textDocument: { uri: documentUri, version },
            contentChanges: [{ text }],
          });
        }
      },
      destroy() {
        disposed = true;
        for (const handle of handles) {
          try {
            handle.client.close();
          } catch {
            // already gone
          }
        }
      },
    };
  });

  const extensions: Extension[] = [syncPlugin, multiHover(handles, documentUri)];
  if (!readOnly) extensions.push(multiCompletion(handles, documentUri));
  return extensions;
}

// ---------------------------------------------------------------- position

function offsetToPos(doc: Text, offset: number) {
  const line = doc.lineAt(offset);
  return { line: line.number - 1, character: offset - line.from };
}

function posToOffset(doc: Text, pos?: { line: number; character: number }): number | null {
  if (!pos || pos.line >= doc.lines) return null;
  const line = doc.line(pos.line + 1);
  const offset = line.from + pos.character;
  return offset <= line.to ? offset : line.to;
}

// ------------------------------------------------------------------- hover

type HoverContents =
  | string
  | { kind?: string; value: string; language?: string }
  | (string | { value: string; language?: string })[];

function hoverText(contents: HoverContents | null | undefined): string {
  if (!contents) return "";
  if (typeof contents === "string") return contents;
  if (Array.isArray(contents)) {
    return contents
      .map((part) => (typeof part === "string" ? part : part.value))
      .filter(Boolean)
      .join("\n\n");
  }
  return contents.value ?? "";
}

/** Hover that asks every server and stacks the non-empty answers. */
function multiHover(handles: ClientHandle[], documentUri: string): Extension {
  return hoverTooltip(async (view, pos): Promise<Tooltip | null> => {
    const position = offsetToPos(view.state.doc, pos);

    type HoverRange = { start?: { line: number; character: number }; end?: { line: number; character: number } };
    const answers = await Promise.all(
      handles.map(async ({ client, ready, capabilities }) => {
        if (!ready() || !capabilities()?.hoverProvider) return null;
        try {
          const result = (await client.textDocumentHover({
            textDocument: { uri: documentUri },
            position,
          })) as { contents?: HoverContents; range?: HoverRange } | null;
          const text = hoverText(result?.contents).trim();
          return text ? { text, range: result?.range } : null;
        } catch {
          return null;
        }
      }),
    );

    const nonEmpty = answers.filter(Boolean) as { text: string; range?: HoverRange }[];
    const merged = nonEmpty.map((a) => a.text).join("\n\n---\n\n");
    if (!merged) return null;

    // The tooltip stays up while the pointer is inside pos..end (or the
    // tooltip itself) — a bare point would close it on the first pixel of
    // mouse movement. Prefer the server-reported symbol range, fall back to
    // the word under the pointer.
    let from = pos;
    let to: number | undefined;
    const range = nonEmpty.find((a) => a.range)?.range;
    const rangeFrom = posToOffset(view.state.doc, range?.start);
    const rangeTo = posToOffset(view.state.doc, range?.end);
    if (rangeFrom != null && rangeTo != null && rangeTo > rangeFrom) {
      from = rangeFrom;
      to = rangeTo;
    } else {
      const word = view.state.wordAt(pos);
      if (word) {
        from = word.from;
        to = word.to;
      }
    }

    return {
      pos: from,
      end: to,
      create: () => {
        const dom = document.createElement("div");
        dom.className = "cm-lsp-hover";
        dom.innerHTML = marked.parse(merged, { async: false });
        return { dom };
      },
    };
  });
}

// -------------------------------------------------------------- completion

const COMPLETION_KINDS: Record<number, string> = {
  1: "text",
  2: "method",
  3: "function",
  4: "function",
  5: "property",
  6: "variable",
  7: "class",
  8: "interface",
  9: "namespace",
  10: "property",
  12: "constant",
  13: "enum",
  14: "keyword",
  15: "text",
  20: "constant",
  21: "constant",
  22: "class",
};

type LspCompletionItem = {
  label: string;
  kind?: number;
  detail?: string;
  documentation?: string | { value?: string };
  insertText?: string;
  insertTextFormat?: number;
  textEdit?: { newText: string };
  sortText?: string;
};

function completionInsert(item: LspCompletionItem): string {
  const raw = item.textEdit?.newText ?? item.insertText ?? item.label;
  // Snippet format: keep the plain text, drop tab-stop markers.
  if (item.insertTextFormat === 2) {
    return raw.replace(/\$\{\d+:?([^}]*)\}/g, "$1").replace(/\$\d+/g, "");
  }
  return raw;
}

/** One completion source querying every server, results merged. */
function multiCompletion(handles: ClientHandle[], documentUri: string): Extension {
  const source = async (context: CompletionContext) => {
    const { state, pos, explicit } = context;
    const line = state.doc.lineAt(pos);
    const charBefore = line.text[pos - line.from - 1];
    // `$` is dm lsp's bindings prefix; `.` and words cover the usual cases.
    const word = context.matchBefore(/[\w$]+$/);
    if (!explicit && !word && charBefore !== "." && charBefore !== "$") return null;

    const position = offsetToPos(state.doc, pos);
    const results = await Promise.all(
      handles.map(async ({ client, ready, capabilities }) => {
        const provider = capabilities()?.completionProvider as
          | { triggerCharacters?: string[] }
          | undefined;
        if (!ready() || !provider) return [];
        const triggered = Boolean(charBefore && provider.triggerCharacters?.includes(charBefore));
        try {
          const result = (await client.textDocumentCompletion({
            textDocument: { uri: documentUri },
            position,
            context: {
              triggerKind: triggered ? 2 : 1,
              ...(triggered ? { triggerCharacter: charBefore } : {}),
            },
          })) as { items?: LspCompletionItem[] } | LspCompletionItem[] | null;
          if (!result) return [];
          return Array.isArray(result) ? result : (result.items ?? []);
        } catch {
          return [];
        }
      }),
    );

    const seen = new Set<string>();
    const options: Completion[] = [];
    for (const item of results.flat()) {
      if (!item?.label || seen.has(item.label)) continue;
      seen.add(item.label);
      const doc =
        typeof item.documentation === "string" ? item.documentation : item.documentation?.value;
      options.push({
        label: item.label,
        detail: item.detail,
        type: COMPLETION_KINDS[item.kind ?? 0],
        info: doc || undefined,
        apply: completionInsert(item),
        boost: item.sortText ? undefined : 0,
      });
    }
    if (options.length === 0) return null;

    return {
      from: word?.from ?? pos,
      options,
      validFor: /^[\w$]*$/,
    };
  };

  return autocompletion({ override: [source] });
}
