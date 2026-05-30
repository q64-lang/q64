// Node stdio entry — the `q64-lsp` binary for desktop editors (VSCode, Neovim).
// Creates a stdio connection and loads the wasm core from disk.

import { createConnection, ProposedFeatures } from "vscode-languageserver/node.js";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Core } from "@q64/core-wasm";
import { runServer } from "./handlers.js";

const connection = createConnection(ProposedFeatures.all);

runServer(connection, async () => {
  const wasmUrl = import.meta.resolve("@q64/core-wasm/q64-core.wasm");
  return Core.load(readFileSync(fileURLToPath(wasmUrl)));
});
