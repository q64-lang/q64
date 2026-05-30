// Map the q64 diagnostic envelope (spec/diagnostics.md) to LSP Diagnostics.

import {
  type Diagnostic as LspDiagnostic,
  DiagnosticSeverity,
  type Range,
} from "vscode-languageserver";
import type { Envelope, Diagnostic as CoreDiagnostic } from "@q64/core-wasm";

function severity(s: CoreDiagnostic["severity"]): DiagnosticSeverity {
  switch (s) {
    case "error":
      return DiagnosticSeverity.Error;
    case "warning":
      return DiagnosticSeverity.Warning;
    case "note":
      return DiagnosticSeverity.Information;
    case "help":
      return DiagnosticSeverity.Hint;
    case "internal":
      return DiagnosticSeverity.Error;
  }
}

export function toLspDiagnostics(env: Envelope): LspDiagnostic[] {
  return env.diagnostics.map((d) => {
    // Envelope line/col are 1-based; LSP positions are 0-based. The current
    // core emits a point, not a span, so we underline a single character.
    // Widen to a real range once the core attaches spans/labels.
    const line = Math.max(0, d.location.line - 1);
    const character = Math.max(0, d.location.col - 1);
    const range: Range = {
      start: { line, character },
      end: { line, character: character + 1 },
    };
    return {
      range,
      severity: severity(d.severity),
      code: d.code,
      source: "q64",
      message: d.message,
    };
  });
}

// Known v0 limitation: the envelope counts columns in UTF-8 code points,
// while LSP positions default to UTF-16 code units. They agree for ASCII.
// The server negotiates `utf-8` positionEncoding when the client supports
// it (LSP 3.17); otherwise non-ASCII columns can be off. Resolved fully
// when the core reports ranges we can translate against the buffer.
