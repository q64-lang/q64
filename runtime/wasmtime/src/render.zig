//! qview display-list rasterizer (host-side, pure Zig — no deps).
//!
//! The `qview.*` host face is an *open* drawing API; this module turns the
//! display list a qube emits into an RGB framebuffer, which the host writes to
//! a PNG (headless) or — with a display — blits to a native window. The same
//! pixels back both `qube run` (native window) and the web embed.
//!
//! Ops understood (extend freely — qview is open):
//!   box    x y w h rgb        filled rectangle (rgb = 0xRRGGBB)
//!   button bid x y w h id     a UI button (filled + outline)
//!   number x y n              an integer, 3x5 bitmap font
//!   text   x y id             a label slot marker
//!
//! PNG is encoded with stored (uncompressed) DEFLATE blocks + a hand-rolled
//! zlib wrapper, so there is no compression-library dependency.

const std = @import("std");

pub const Op = struct { name: []const u8, args: []const i64 };

pub const Canvas = struct {
    w: u32,
    h: u32,
    px: []u8, // RGB, row-major

    pub fn init(a: std.mem.Allocator, w: u32, h: u32, bg: u32) !Canvas {
        const px = try a.alloc(u8, w * h * 3);
        var i: usize = 0;
        while (i < px.len) : (i += 3) {
            px[i] = @intCast((bg >> 16) & 0xff);
            px[i + 1] = @intCast((bg >> 8) & 0xff);
            px[i + 2] = @intCast(bg & 0xff);
        }
        return .{ .w = w, .h = h, .px = px };
    }

    pub fn put(self: *Canvas, x: i64, y: i64, rgb: u32) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        const i = (@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))) * 3;
        self.px[i] = @intCast((rgb >> 16) & 0xff);
        self.px[i + 1] = @intCast((rgb >> 8) & 0xff);
        self.px[i + 2] = @intCast(rgb & 0xff);
    }

    pub fn rect(self: *Canvas, x: i64, y: i64, w: i64, h: i64, rgb: u32) void {
        var yy: i64 = y;
        while (yy < y + h) : (yy += 1) {
            var xx: i64 = x;
            while (xx < x + w) : (xx += 1) self.put(xx, yy, rgb);
        }
    }

    pub fn rectOutline(self: *Canvas, x: i64, y: i64, w: i64, h: i64, rgb: u32, t: i64) void {
        self.rect(x, y, w, t, rgb);
        self.rect(x, y + h - t, w, t, rgb);
        self.rect(x, y, t, h, rgb);
        self.rect(x + w - t, y, t, h, rgb);
    }

    fn glyph(self: *Canvas, ch: u8, x: i64, y: i64, rgb: u32, s: i64) i64 {
        const rows = font(ch) orelse return 4 * s;
        for (rows, 0..) |row, ry| {
            var bit: u2 = 0;
            while (bit < 3) : (bit += 1) {
                if ((row >> (2 - bit)) & 1 == 1)
                    self.rect(x + @as(i64, bit) * s, y + @as(i64, @intCast(ry)) * s, s, s, rgb);
            }
        }
        return 4 * s;
    }

    pub fn text(self: *Canvas, str: []const u8, x: i64, y: i64, rgb: u32, s: i64) void {
        var cx = x;
        for (str) |ch| cx += self.glyph(ch, cx, y, rgb, s);
    }
};

/// 3x5 bitmap font (3 bits/row, top→bottom) for digits and a couple glyphs.
fn font(ch: u8) ?[5]u3 {
    return switch (ch) {
        '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b010, 0b010, 0b010 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        else => null,
    };
}

/// Draw a display list onto a fresh canvas.
pub fn render(a: std.mem.Allocator, ops: []const Op, w: u32, h: u32, bg: u32) !Canvas {
    var cv = try Canvas.init(a, w, h, bg);
    for (ops) |op| {
        const ar = op.args;
        if (std.mem.eql(u8, op.name, "box") and ar.len >= 5) {
            cv.rect(ar[0], ar[1], ar[2], ar[3], @intCast(ar[4] & 0xffffff));
        } else if (std.mem.eql(u8, op.name, "button") and ar.len >= 5) {
            cv.rect(ar[1], ar[2], ar[3], ar[4], 0x2D6CDF);
            cv.rectOutline(ar[1], ar[2], ar[3], ar[4], 0x5B8DEF, 2);
        } else if (std.mem.eql(u8, op.name, "number") and ar.len >= 3) {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{ar[2]}) catch "?";
            cv.text(s, ar[0], ar[1], 0xF0F0F0, 4);
        } else if (std.mem.eql(u8, op.name, "text") and ar.len >= 3) {
            cv.rect(ar[0], ar[1], 120, 4, 0x6A7080);
        }
    }
    return cv;
}

// ---- PNG (stored DEFLATE + hand-rolled zlib/CRC) ----------------------------

fn be32(v: u32) [4]u8 {
    return .{ @intCast((v >> 24) & 0xff), @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) };
}

/// Encode `cv` to PNG bytes (caller owns the slice).
pub fn toPng(a: std.mem.Allocator, cv: Canvas) ![]u8 {
    // Filtered scanlines: a leading 0 (filter: none) per row.
    const raw_len = cv.h * (1 + cv.w * 3);
    const raw = try a.alloc(u8, raw_len);
    defer a.free(raw);
    {
        var o: usize = 0;
        var y: u32 = 0;
        while (y < cv.h) : (y += 1) {
            raw[o] = 0;
            o += 1;
            const row = cv.px[y * cv.w * 3 .. (y + 1) * cv.w * 3];
            @memcpy(raw[o .. o + row.len], row);
            o += row.len;
        }
    }

    // zlib stream: CMF/FLG + stored DEFLATE blocks + Adler-32.
    var z: std.ArrayListUnmanaged(u8) = .empty;
    defer z.deinit(a);
    try z.appendSlice(a, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (off < raw.len) {
        const chunk: u16 = @intCast(@min(raw.len - off, 0xffff));
        const final: u8 = if (off + chunk >= raw.len) 1 else 0;
        try z.append(a, final); // BFINAL + BTYPE=00 (stored)
        try z.appendSlice(a, &.{ @intCast(chunk & 0xff), @intCast((chunk >> 8) & 0xff) });
        const nlen = ~chunk;
        try z.appendSlice(a, &.{ @intCast(nlen & 0xff), @intCast((nlen >> 8) & 0xff) });
        try z.appendSlice(a, raw[off .. off + chunk]);
        off += chunk;
    }
    try z.appendSlice(a, &be32(std.hash.Adler32.hash(raw)));

    // PNG: signature + IHDR + IDAT + IEND, each chunk CRC-32'd.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });
    var ihdr: [13]u8 = undefined;
    @memcpy(ihdr[0..4], &be32(cv.w));
    @memcpy(ihdr[4..8], &be32(cv.h));
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // color type: truecolor RGB
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(a, &out, "IHDR", &ihdr);
    try writeChunk(a, &out, "IDAT", z.items);
    try writeChunk(a, &out, "IEND", &.{});
    return out.toOwnedSlice(a);
}

fn writeChunk(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), tag: []const u8, data: []const u8) !void {
    try out.appendSlice(a, &be32(@intCast(data.len)));
    try out.appendSlice(a, tag);
    try out.appendSlice(a, data);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    try out.appendSlice(a, &be32(crc.final()));
}
