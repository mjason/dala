import type { Extension } from "@codemirror/state";
import {
  LanguageServerClient,
  WebSocketTransport,
  languageServerWithTransport,
} from "codemirror-languageserver";

export type LspServerInfo = { id: number; name: string };

type LspTarget = {
  root: string;
  path: string;
  language: string;
  servers: LspServerInfo[];
};

/**
 * LSP extensions for the file editor: one client per language server, all
 * attached to the same document (e.g. basedpyright for Python itself plus
 * dark-magician's `dm lsp` for the DSL inside ctx.dsl("...") strings).
 *
 * The upstream plugin publishes diagnostics with replace-all semantics, so
 * with several servers the last publisher would wipe the others' squiggles.
 * Each client's publishDiagnostics is intercepted here and re-emitted as the
 * union of every server's latest report.
 */
export function lspExtensions({ root, path, language, servers }: LspTarget): Extension[] {
  const rootUri = `file://${root}`;
  const documentUri = `file://${path}`;
  const workspaceFolders = [{ uri: rootUri, name: root.split("/").pop() ?? root }];
  const wsProto = window.location.protocol === "https:" ? "wss" : "ws";
  const latest = new Map<number, unknown[]>();

  return servers.flatMap((server) => {
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
      autoClose: true,
    });

    type Notification = { method?: string; params?: { uri?: string; diagnostics?: unknown[] } };
    const patchable = client as unknown as { processNotification: (n: Notification) => void };
    const forward = patchable.processNotification.bind(client) as (n: Notification) => void;
    patchable.processNotification = (notification) => {
      if (
        notification?.method === "textDocument/publishDiagnostics" &&
        notification.params?.uri === documentUri
      ) {
        latest.set(server.id, notification.params.diagnostics ?? []);
        const merged = [...latest.values()].flat();
        forward({ ...notification, params: { ...notification.params, diagnostics: merged } });
        return;
      }
      forward(notification);
    };

    return languageServerWithTransport({
      client,
      transport,
      rootUri,
      workspaceFolders,
      documentUri,
      languageId: language,
    });
  });
}
