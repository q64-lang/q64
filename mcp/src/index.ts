import type { Env } from "./env.ts";

// q64-mcp — the Model Context Protocol surface for the Q64 registry, served at
// mcp.q64.dev.
//
// v1 is intentionally STATELESS. The only capabilities are `initialize`, the
// tool listing, and a single `version` tool — all pure constants that need no
// per-session state. So there is no session handshake (no Mcp-Session-Id) and
// no Durable Object: every request is answered directly. Real read tools
// (search_qubes, get_qube, …) will front the continuum-api Worker over `fetch`
// in a later cut and can stay just as stateless.
const VERSION = "0.1.0";
const PROTOCOL_VERSION = "2025-06-18";

const TOOLS = [
  {
    name: "version",
    description: "Return the q64-mcp server version.",
    inputSchema: { type: "object", properties: {} },
  },
];

// Open CORS so browser-based MCP clients (and Postman) can call the endpoint.
// There is no auth and nothing session-scoped to protect.
const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Accept, Mcp-Protocol-Version",
};

function rpc(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...CORS },
  });
}

function rpcError(id: unknown, code: number, message: string): Response {
  return rpc({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });
}

function handleRpc(msg: any): Response {
  const { id, method, params } = msg ?? {};

  switch (method) {
    case "initialize":
      return rpc({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "q64-mcp", version: VERSION },
        },
      });

    case "tools/list":
      return rpc({ jsonrpc: "2.0", id, result: { tools: TOOLS } });

    case "tools/call": {
      const name = params?.name;
      if (name === "version") {
        return rpc({
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: VERSION }] },
        });
      }
      return rpcError(id, -32602, `Unknown tool: ${name}`);
    }

    default:
      // Notifications carry no id and expect no reply (e.g.
      // notifications/initialized) — acknowledge with 202.
      if (id === undefined) {
        return new Response(null, { status: 202, headers: CORS });
      }
      return rpcError(id, -32601, `Method not found: ${method}`);
  }
}

export default {
  async fetch(request: Request, _env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }

    // Streamable HTTP transport (modern), stateless. No legacy SSE endpoint.
    if (url.pathname.startsWith("/mcp")) {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: CORS });
      }
      let msg: unknown;
      try {
        msg = await request.json();
      } catch {
        return rpcError(null, -32700, "Parse error");
      }
      return handleRpc(msg);
    }

    // Anyone hitting the bare host gets told where the endpoint is.
    if (url.pathname === "/") {
      return new Response(
        "q64-mcp — Model Context Protocol endpoint for the Q64 registry.\n" +
          "Point a Streamable HTTP MCP client at https://mcp.q64.dev/mcp\n",
        { headers: { "content-type": "text/plain; charset=utf-8" } },
      );
    }

    return new Response("Not found", { status: 404 });
  },
};
