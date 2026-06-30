// Minimal LSP client for black-box testing. Spawns the built server exactly
// as an editor would (`node dist/server.js --stdio`) and speaks JSON-RPC with
// Content-Length framing. It imports nothing from the workspace — the only
// contract it exercises is the wire protocol.

import { spawn, type ChildProcess } from "node:child_process";

export interface LspMessage {
  jsonrpc: "2.0";
  id?: number;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: unknown;
}

export interface PublishDiagnosticsParams {
  uri: string;
  diagnostics: Array<{
    range: {
      start: { line: number; character: number };
      end: { line: number; character: number };
    };
    severity: number;
    code?: string;
    source?: string;
    message: string;
  }>;
}

export class LspClient {
  private readonly proc: ChildProcess;
  private buf = Buffer.alloc(0);
  private nextId = 1;
  private readonly pending = new Map<number, (m: LspMessage) => void>();
  private readonly notifications: LspMessage[] = [];
  private readonly waiters: Array<{
    match: (m: LspMessage) => boolean;
    resolve: (m: LspMessage) => void;
  }> = [];

  constructor(serverPath: string) {
    this.proc = spawn("node", [serverPath, "--stdio"], {
      stdio: ["pipe", "pipe", "inherit"],
    });
    this.proc.stdout!.on("data", (d: Buffer) => this.onData(d));
  }

  private onData(chunk: Buffer): void {
    this.buf = Buffer.concat([this.buf, chunk]);
    for (;;) {
      const headerEnd = this.buf.indexOf("\r\n\r\n");
      if (headerEnd === -1) return;
      const header = this.buf.subarray(0, headerEnd).toString("utf8");
      const m = /Content-Length: (\d+)/i.exec(header);
      if (!m) {
        this.buf = this.buf.subarray(headerEnd + 4);
        continue;
      }
      const len = Number(m[1]);
      const start = headerEnd + 4;
      if (this.buf.length < start + len) return;
      const body = this.buf.subarray(start, start + len).toString("utf8");
      this.buf = this.buf.subarray(start + len);
      this.dispatch(JSON.parse(body) as LspMessage);
    }
  }

  private dispatch(msg: LspMessage): void {
    if (typeof msg.id === "number" && this.pending.has(msg.id)) {
      this.pending.get(msg.id)!(msg);
      this.pending.delete(msg.id);
      return;
    }
    // Notification (e.g. textDocument/publishDiagnostics).
    this.notifications.push(msg);
    const idx = this.waiters.findIndex((w) => w.match(msg));
    if (idx !== -1) {
      const [w] = this.waiters.splice(idx, 1);
      w.resolve(msg);
    }
  }

  private write(msg: LspMessage): void {
    const body = JSON.stringify(msg);
    const payload = `Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n\r\n${body}`;
    this.proc.stdin!.write(payload);
  }

  request(method: string, params: unknown): Promise<LspMessage> {
    const id = this.nextId++;
    return new Promise((resolve) => {
      this.pending.set(id, resolve);
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method: string, params: unknown): void {
    this.write({ jsonrpc: "2.0", method, params });
  }

  /** Resolve when a notification matching `method` arrives (checking any
   *  already-buffered notifications first). */
  waitForNotification(
    method: string,
    match: (m: LspMessage) => boolean = () => true,
  ): Promise<LspMessage> {
    const pred = (m: LspMessage) => m.method === method && match(m);
    const existing = this.notifications.find(pred);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve) => this.waiters.push({ match: pred, resolve }));
  }

  async initialize(): Promise<LspMessage> {
    const res = await this.request("initialize", {
      processId: process.pid,
      rootUri: null,
      capabilities: {},
    });
    this.notify("initialized", {});
    return res;
  }

  openDocument(uri: string, text: string, languageId = "q64"): void {
    this.notify("textDocument/didOpen", {
      textDocument: { uri, languageId, version: 1, text },
    });
  }

  /** Replace the whole buffer (the server advertises full text sync). */
  changeDocument(uri: string, text: string, version = 2): void {
    this.notify("textDocument/didChange", {
      textDocument: { uri, version },
      contentChanges: [{ text }],
    });
  }

  closeDocument(uri: string): void {
    this.notify("textDocument/didClose", { textDocument: { uri } });
  }

  hover(uri: string, line: number, character: number): Promise<LspMessage> {
    return this.request("textDocument/hover", {
      textDocument: { uri },
      position: { line, character },
    });
  }

  definition(uri: string, line: number, character: number): Promise<LspMessage> {
    return this.request("textDocument/definition", {
      textDocument: { uri },
      position: { line, character },
    });
  }

  documentSymbols(uri: string): Promise<LspMessage> {
    return this.request("textDocument/documentSymbol", { textDocument: { uri } });
  }

  completion(uri: string, line: number, character: number): Promise<LspMessage> {
    return this.request("textDocument/completion", {
      textDocument: { uri },
      position: { line, character },
    });
  }

  /** Resolve on the NEXT notification matching `method` — ignoring any already
   *  buffered. Register it BEFORE triggering the change you want to observe, so
   *  the post-open publish (e.g.) can't satisfy a didChange/didClose assertion. */
  nextNotification(
    method: string,
    match: (m: LspMessage) => boolean = () => true,
  ): Promise<LspMessage> {
    const pred = (m: LspMessage) => m.method === method && match(m);
    return new Promise((resolve) => this.waiters.push({ match: pred, resolve }));
  }

  async shutdown(): Promise<void> {
    await this.request("shutdown", null);
    this.notify("exit", null);
    this.proc.kill();
  }
}
