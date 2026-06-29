// Transport-agnostic LSP handlers.
//
// `runServer` registers the document store + diagnostics on a Connection and
// starts listening. The Connection is created by a thin per-transport entry:
// `node.ts` (stdio, desktop editors) or a browser Worker entry in the host
// (vscode.dev, the qubepods editor). Both pass a `loadCore` that yields the
// wasm analysis core however that host obtains the bytes.

import {
  TextDocuments,
  TextDocumentSyncKind,
  type Connection,
  type InitializeParams,
  type InitializeResult,
} from "vscode-languageserver";
import { TextDocument } from "vscode-languageserver-textdocument";
import type { Core } from "@q64/core-wasm";
import { toLspDiagnostics } from "./diagnostics.js";

export function runServer(
  connection: Connection,
  loadCore: () => Promise<Core>,
): void {
  const documents = new TextDocuments(TextDocument);
  let core: Core | undefined;

  connection.onInitialize((params: InitializeParams): InitializeResult => {
    const encodings = params.capabilities.general?.positionEncodings ?? [];
    const utf8 = encodings.includes("utf-8");
    return {
      capabilities: {
        // The core re-analyzes the whole buffer per change, so full sync is
        // simplest and sufficient — there is no incremental parse yet.
        textDocumentSync: TextDocumentSyncKind.Full,
        positionEncoding: utf8 ? "utf-8" : "utf-16",
        // Diagnostics (parse + sema) only for now. Hover / definition /
        // formatting / code actions arrive once the core exports positional
        // queries (q64_hover, …) and fmt lands in ../../../q64.
      },
    };
  });

  connection.onInitialized(async () => {
    core = await loadCore();
    // Re-validate anything already open: the client may have sent didOpen
    // before the core finished loading.
    for (const doc of documents.all()) validate(doc);
  });

  function validate(doc: TextDocument): void {
    if (!core) return; // core still loading; onInitialized re-validates
    const env = core.diagnose(doc.getText());
    connection.sendDiagnostics({
      uri: doc.uri,
      diagnostics: toLspDiagnostics(env),
    });
  }

  documents.onDidChangeContent((e) => validate(e.document));
  documents.onDidClose((e) =>
    connection.sendDiagnostics({ uri: e.document.uri, diagnostics: [] }),
  );

  documents.listen(connection);
  connection.listen();
}
