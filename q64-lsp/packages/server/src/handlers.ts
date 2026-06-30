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
  MarkupKind,
  type Connection,
  type InitializeParams,
  type InitializeResult,
  type Position,
} from "vscode-languageserver";
import { TextDocument } from "vscode-languageserver-textdocument";
import type { Core } from "@q64/core-wasm";
import { toLspDiagnostics } from "./diagnostics.js";

// The core indexes source by UTF-8 byte; LSP positions are (line, character) in
// UTF-16 code units of the document. These two helpers translate across that
// boundary against the document's own text, so the mapping is exact regardless
// of the negotiated position encoding (we never trust a column out of the core).
const utf8 = new TextEncoder();
const fromUtf8 = new TextDecoder();

function byteOffsetAt(doc: TextDocument, pos: Position): number {
  return utf8.encode(doc.getText().slice(0, doc.offsetAt(pos))).length;
}

function positionAtByte(doc: TextDocument, byte: number): Position {
  const utf16 = fromUtf8.decode(utf8.encode(doc.getText()).slice(0, byte)).length;
  return doc.positionAt(utf16);
}

export function runServer(
  connection: Connection,
  loadCore: () => Promise<Core>,
): void {
  const documents = new TextDocuments(TextDocument);
  // `loadCore` runs once, memoized. `validate` reads the resolved `core`
  // synchronously (re-validated on load); the request handlers await `getCore`
  // so they work even if a hover/definition arrives before the core finishes
  // loading.
  let core: Core | undefined;
  let corePromise: Promise<Core> | undefined;
  const getCore = (): Promise<Core> => (corePromise ??= loadCore());

  connection.onInitialize((params: InitializeParams): InitializeResult => {
    const encodings = params.capabilities.general?.positionEncodings ?? [];
    const wantsUtf8 = encodings.includes("utf-8");
    return {
      capabilities: {
        // The core re-analyzes the whole buffer per change, so full sync is
        // simplest and sufficient — there is no incremental parse yet.
        textDocumentSync: TextDocumentSyncKind.Full,
        positionEncoding: wantsUtf8 ? "utf-8" : "utf-16",
        hoverProvider: true,
        definitionProvider: true,
        // Formatting / code actions arrive once the core exports fmt.
      },
    };
  });

  connection.onInitialized(async () => {
    core = await getCore();
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

  connection.onHover(async (params) => {
    const doc = documents.get(params.textDocument.uri);
    if (!doc) return null;
    const h = (await getCore()).hover(doc.getText(), byteOffsetAt(doc, params.position));
    if (!h.contents) return null;
    return { contents: { kind: MarkupKind.PlainText, value: h.contents } };
  });

  connection.onDefinition(async (params) => {
    const doc = documents.get(params.textDocument.uri);
    if (!doc) return null;
    const d = (await getCore()).definition(doc.getText(), byteOffsetAt(doc, params.position));
    if (!d.found || d.offset === undefined || d.len === undefined) return null;
    return {
      uri: params.textDocument.uri,
      range: {
        start: positionAtByte(doc, d.offset),
        end: positionAtByte(doc, d.offset + d.len),
      },
    };
  });

  documents.listen(connection);
  connection.listen();
}
