const std = @import("std");
const emit = @import("emit");

// Spike entry: force the FULL codegen pipeline (parse → sema → ir → emit) to
// compile into the wasm, so the complete Binaryen C-API surface surfaces as
// imports. We only need this to BUILD — proving the q64 side cooperates and
// enumerating the imports the JS (binaryen.js) shim must implement.
export fn q64_emit_len() u32 {
    const a = std.heap.page_allocator;
    const src = "fn main { env.out(\"hi\") }\n";
    const bytes = emit.emitFromSource(a, src, "main.q", &.{}, .wasm32) catch return 0;
    defer a.free(bytes);
    return @intCast(bytes.len);
}
