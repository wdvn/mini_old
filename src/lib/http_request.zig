//! lib/http_request.zig — Centralized HTTP client for the entire mini-agent.
//!
//! All components needing to send HTTP requests (tools/http.zig, AI backends, ...)
//! call through this module instead of setting up std.http.Client independently.
//!
//! ## Main API
//!   - `fetch(alloc, io, .{...})` → `Response { status, headers, body, truncated }`
//!   - `postStream(alloc, io, .{...}, on_chunk, userdata)` → status u32 —
//!     streams chunk-by-chunk for SSE/NDJSON (replaces legacy backends/sse.zig).
//!   - `parseMethod`, `parseHeadersJson`, `parseHeadersKv`, `formatResponseText`
//!     — shared helpers.
//!
//! ## Design
//!   - Uses Zig std's std.http.Client, zero external dependencies.
//!   - Response body reads at most `max_body_size` (default 30KB) — prevents overflowing
//!     AI context window; truncated portion is dropped and flagged in `truncated`.
//!   - Status, headers, and body are clearly separated in `Response` struct so caller
//!     (JS binding `mini.http`) returns JSON object with proper semantics, avoiding
//!     leaking headers into body like the old version.
//!   - Response headers maintain raw trimmed lines — sufficient for tool protocol.
//!
//! ## Testing
//!   - `zig build test` runs integration tests with local HTTP server built from
//!     std.Io.net (no external network required, deterministic and non-flaky).

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const net = std.Io.net;
const signals = @import("../core/signals.zig");

/// Default body limit: 30KB — consistent with legacy tool protocol.
pub const DEFAULT_MAX_BODY_SIZE: usize = 30 * 1024;

/// Default timeout for full request (connect + transfer): 60s.
pub const DEFAULT_TIMEOUT_S: u32 = 60;

// ---------------------------------------------------------------------------
// Request / Response
// ---------------------------------------------------------------------------

/// Parameters for `fetch`. All fields are optional except `url`.
pub const Options = struct {
    url: []const u8,
    method: []const u8 = "GET",
    body: ?[]const u8 = null,
    /// JSON object string like `{"Key":"Value",...}` — parsed with `parseHeadersJson`.
    headers_json: ?[]const u8 = null,
    /// Limit of response body to read. Default DEFAULT_MAX_BODY_SIZE.
    max_body_size: usize = DEFAULT_MAX_BODY_SIZE,
    /// Overall request timeout (seconds). Default DEFAULT_TIMEOUT_S.
    timeout_s: u32 = DEFAULT_TIMEOUT_S,
};

/// Structured HTTP request result.
/// All slices belong to caller's `alloc` — freed via `deinit`.
pub const Response = struct {
    status: u16,
    /// Status reason phrase (e.g. "OK", "Not Found"). May be empty.
    reason: []const u8,
    /// Raw trimmed header lines in "Name: Value" format (excluding status line).
    headers: []const Header,
    /// Body (truncated at max_body_size if exceeded).
    body: []u8,
    /// Actual bytes of body received from server (including discarded portion).
    total_body_bytes: usize,
    /// true if body was truncated due to exceeding max_body_size.
    truncated: bool,
    /// Base memory pointer allocated by fetch — deinit frees this buffer (headers_out
    /// is also merged here, see fetch).
    intern_base: ?[]u8 = null,
    /// Dedicated allocation for Header array (pointing into intern_base).
    intern_headers: ?[]Response.Header = null,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Find header by name (case-insensitive). Returns value or null.
    pub fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Free all memory belonging to Response.
    pub fn deinit(self: *Response, alloc: Allocator) void {
        if (self.intern_headers) |h| alloc.free(h);
        if (self.intern_base) |p| alloc.free(p);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Parse method string → std.http.Method. Case-insensitive.
/// Returns error.InvalidMethod if unrecognized.
pub fn parseMethod(method: []const u8) !std.http.Method {
    var buf: [16]u8 = undefined;
    if (method.len > buf.len) return error.InvalidMethod;
    const upper = std.ascii.upperString(&buf, method);
    return std.meta.stringToEnum(std.http.Method, upper) orelse error.InvalidMethod;
}

/// Parse JSON object string `{"K":"V",...}` into Header list.
/// This is a simple parser: key/value must be strings without complex nesting
/// (tool input from LLM is always in this shape). Returns error if JSON is malformed.
pub fn parseHeadersJson(alloc: Allocator, headers_json: []const u8) ![]std.http.Header {
    var list = std.ArrayList(std.http.Header).empty;
    errdefer list.deinit(alloc);

    var i: usize = 0;
    // Skip leading whitespace
    while (i < headers_json.len and std.ascii.isWhitespace(headers_json[i])) : (i += 1) {}
    if (i >= headers_json.len or headers_json[i] != '{') return error.InvalidHeadersJson;
    i += 1;

    while (i < headers_json.len) {
        // Skip whitespace and comma
        while (i < headers_json.len and (std.ascii.isWhitespace(headers_json[i]) or headers_json[i] == ',')) : (i += 1) {}
        if (i >= headers_json.len) break;
        if (headers_json[i] == '}') break;

        if (headers_json[i] != '"') return error.InvalidHeadersJson;
        const key = try parseJsonString(alloc, headers_json, &i);
        defer alloc.free(key);

        // skip whitespace + colon
        while (i < headers_json.len and (std.ascii.isWhitespace(headers_json[i]) or headers_json[i] == ':')) : (i += 1) {}
        if (i >= headers_json.len or headers_json[i] != '"') return error.InvalidHeadersJson;
        const val = try parseJsonString(alloc, headers_json, &i);
        defer alloc.free(val);

        try list.append(alloc, .{ .name = try alloc.dupe(u8, key), .value = try alloc.dupe(u8, val) });
    }

    return list.toOwnedSlice(alloc);
}

/// Read JSON string starting at s[i] == '"'. Advance i past closing quote.
/// Supports escapes: \" \\ \/ \b \f \n \r \t \uXXXX.
fn parseJsonString(alloc: Allocator, s: []const u8, i: *usize) ![]u8 {
    std.debug.assert(s[i.*] == '"');
    i.* += 1;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    while (i.* < s.len) {
        const c = s[i.*];
        if (c == '"') {
            i.* += 1;
            return out.toOwnedSlice(alloc);
        }
        if (c == '\\') {
            i.* += 1;
            if (i.* >= s.len) return error.InvalidHeadersJson;
            const esc = s[i.*];
            i.* += 1;
            switch (esc) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                '/' => try out.append(alloc, '/'),
                'b' => try out.append(alloc, 0x08),
                'f' => try out.append(alloc, 0x0C),
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                'u' => {
                    if (i.* + 4 > s.len) return error.InvalidHeadersJson;
                    const cp = std.fmt.parseInt(u21, s[i.* .. i.* + 4], 16) catch return error.InvalidHeadersJson;
                    i.* += 4;
                    var utf8_buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &utf8_buf) catch return error.InvalidHeadersJson;
                    try out.appendSlice(alloc, utf8_buf[0..n]);
                },
                else => return error.InvalidHeadersJson,
            }
        } else {
            try out.append(alloc, c);
            i.* += 1;
        }
    }
    return error.InvalidHeadersJson; // missing closing quote
}

/// Format Response as text for tool protocol (status, headers, blank, body).
/// Used by executeTool in http_request and tools needing plain text output.
pub fn formatResponseText(alloc: Allocator, res: *const Response) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const w = &out;

    try w.appendSlice(alloc, "HTTP ");
    var num_buf: [8]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "{d}", .{res.status}) catch "???";
    try w.appendSlice(alloc, num);
    if (res.reason.len > 0) {
        try w.append(alloc, ' ');
        try w.appendSlice(alloc, res.reason);
    }
    try w.append(alloc, '\n');

    for (res.headers) |h| {
        try w.appendSlice(alloc, h.name);
        try w.appendSlice(alloc, ": ");
        try w.appendSlice(alloc, h.value);
        try w.append(alloc, '\n');
    }
    try w.append(alloc, '\n');
    try w.appendSlice(alloc, res.body);
    if (res.truncated) {
        const omitted = res.total_body_bytes - res.body.len;
        var tr_buf: [48]u8 = undefined;
        const tr = std.fmt.bufPrint(&tr_buf, "\n... [truncated {d} bytes]", .{omitted}) catch "";
        try w.appendSlice(alloc, tr);
    }

    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Fetch — core
// ---------------------------------------------------------------------------

/// Send HTTP request and return structured Response.
///
/// Memory note: entire Response is housed in ONE single allocation
/// (internal arena) → caller only needs to call `res.deinit(alloc)`.
pub fn fetch(alloc: Allocator, io: std.Io, opts: Options) !Response {
    var client = std.http.Client{
        .allocator = alloc,
        .io = io,
    };
    defer client.deinit();

    // Pre-warm TLS state the way std does for direct https: rescan CA
    // bundle + set `now`. Without this, http requests redirected 301 →
    // https will panic "attempt to use null value" in Tls.create (unwrapping
    // `client.now.?` on connect).
    initTlsState(&client, io);

    return fetchWithClient(alloc, &client, opts);
}

/// Initialize `now` + `ca_bundle` for client (mirroring tls: logic in
/// std.http.Client.connect — std only runs this branch when root URL is https).
fn initTlsState(client: *std.http.Client, io: std.Io) void {
    if (std.http.Client.disable_tls) return;
    client.now = std.Io.Clock.real.now(io);
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    bundle.rescan(client.allocator, io, client.now.?) catch {
        // Failed to load CA → leave empty, TLS will return CertificateBundleLoadFailure
        // instead of crashing; http connections will still work normally.
        return;
    };
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

/// Whether to prefer IPv4 when establishing connections.
///
/// Defaults to enabled. Set `MINI_FORCE_IPV4=0` / `false` / `off` to restore
/// std's default "race every resolved address" behaviour.
fn preferIpv4() bool {
    const raw = std.c.getenv("MINI_FORCE_IPV4") orelse return true;
    const v = std.mem.span(raw);
    return !(std.mem.eql(u8, v, "0") or
        std.ascii.eqlIgnoreCase(v, "false") or
        std.ascii.eqlIgnoreCase(v, "off") or
        std.ascii.eqlIgnoreCase(v, "no"));
}

/// Best-effort IPv4 pre-connect to work around blackholed IPv6 routes.
///
/// Problem: some networks advertise a global IPv6 default route that cannot
/// actually reach the internet (a "IPv6 blackhole"). std's `HostName.connect`
/// races *all* resolved addresses and may pick the IPv6 path, whose TCP connect
/// succeeds but whose TLS handshake then stalls/fails — surfacing as
/// `error.TlsInitializationFailed` after a long timeout. This intermittently
/// kills an AI act (and thus the CodeAct it was about to emit).
///
/// Fix: resolve the URL host to an A record and eagerly acquire an IPv4
/// connection, keeping the original host name for TLS SNI / certificate
/// verification and for the HTTP `Host` header. The acquired connection is
/// handed to `client.request` (via `RequestOptions.connection`) so std reuses
/// it instead of racing the broken IPv6 address again.
///
/// Returns `null` when disabled, when the host has no IPv4 address, when the
/// host is already an IP literal, or on any error — callers then fall back to
/// std's default connection logic (IPv6-only hosts keep working).
fn preconnectIpv4(client: *std.http.Client, uri: std.Uri) ?*std.http.Client.Connection {
    if (!preferIpv4()) return null;

    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return null;
    if (protocol == .tls and std.http.Client.disable_tls) return null;

    const io = client.io;

    var host_buf: [net.HostName.max_len]u8 = undefined;
    const host_name = uri.getHost(&host_buf) catch return null;

    // Already an IP literal — std connects directly, no DNS/race involved.
    if (net.IpAddress.parseIp4(host_name.bytes, uri.port orelse 0)) |_| return null else |_| {}
    if (net.IpAddress.parseIp6(host_name.bytes, uri.port orelse 0)) |_| return null else |_| {}

    const port: u16 = uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };

    var results_buf: [16]net.HostName.LookupResult = undefined;
    var results: std.Io.Queue(net.HostName.LookupResult) = .init(&results_buf);
    host_name.lookup(io, &results, .{ .port = port, .family = .ip4 }) catch return null;

    var ip4: ?net.Ip4Address = null;
    while (results.getOne(io)) |res| {
        switch (res) {
            .address => |addr| {
                if (ip4 == null) switch (addr) {
                    .ip4 => |v| ip4 = v,
                    else => {},
                };
            },
            .canonical_name => {},
        }
    } else |_| {}

    const addr = ip4 orelse return null;

    var ip_buf: [net.HostName.max_len]u8 = undefined;
    const ip_str = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{
        addr.bytes[0], addr.bytes[1], addr.bytes[2], addr.bytes[3],
    }) catch return null;

    // TLS needs `now` + CA bundle warmed before `Tls.create` runs.
    if (client.now == null) initTlsState(client, io);

    return client.connectTcpOptions(.{
        .host = .{ .bytes = ip_str },
        .port = port,
        .protocol = protocol,
        // Preserve the real host name for SNI + certificate verification and so
        // the pooled connection matches the request's URI host.
        .proxied_host = host_name,
        .proxied_port = port,
    }) catch null;
}

/// Like `fetch` but uses existing client (reuses connection pool, caller manages deinit).
pub fn fetchWithClient(alloc: Allocator, client: *std.http.Client, opts: Options) !Response {
    const http_method = try parseMethod(opts.method);

    var extra_headers: []std.http.Header = &.{};
    var extra_headers_owned = false;
    defer if (extra_headers_owned) {
        for (extra_headers) |h| {
            alloc.free(h.name);
            alloc.free(h.value);
        }
        alloc.free(extra_headers);
    };
    if (opts.headers_json) |hj| {
        extra_headers = try parseHeadersJson(alloc, hj);
        extra_headers_owned = true;
    }

    const uri = try std.Uri.parse(opts.url);
    var req = try client.request(http_method, uri, .{
        .extra_headers = extra_headers,
        .headers = .{
            .accept_encoding = .omit,
        },
        .keep_alive = false,
        // Prefer IPv4 when available (works around blackholed IPv6 routes,
        // which otherwise fail as TlsInitializationFailed during handshake).
        .connection = preconnectIpv4(client, uri),
    });
    defer req.deinit();

    // --- Send request body ---
    if (opts.body) |b| {
        if (b.len > 0) {
            req.transfer_encoding = .{ .content_length = b.len };
            var req_body = try req.sendBodyUnflushed(&.{});
            try req_body.writer.writeAll(b);
            try req_body.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }
    } else {
        try req.sendBodiless();
    }

    // --- Receive response head ---
    var redirect_buffer: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    const status: u16 = @intFromEnum(response.head.status);
    const reason: []const u8 = response.head.reason;

    // --- Collect headers using std HeaderIterator ---
    var header_list = std.ArrayList(Response.Header).empty;
    defer header_list.deinit(alloc);
    if (response.head.bytes.len > 0) {
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            try header_list.append(alloc, .{
                .name = try alloc.dupe(u8, h.name),
                .value = try alloc.dupe(u8, h.value),
            });
        }
    }

    // --- Read body with limit ---
    var resp_body = std.ArrayList(u8).empty;
    defer resp_body.deinit(alloc);

    var transfer_buf: [4096]u8 = undefined;
    const r = response.reader(&transfer_buf);

    var chunk_buf: [4096]u8 = undefined;
    var total_bytes: usize = 0;
    while (true) {
        if (signals.isInterrupted()) return error.Interrupted;
        const n = r.readSliceShort(&chunk_buf) catch |e| {
            // Already read a portion → consider sufficient, don't fail whole request
            if (resp_body.items.len > 0) break;
            return e;
        };
        if (signals.isInterrupted()) return error.Interrupted;
        if (n == 0) break;
        total_bytes += n;
        if (resp_body.items.len < opts.max_body_size) {
            const to_copy = @min(n, opts.max_body_size - resp_body.items.len);
            try resp_body.appendSlice(alloc, chunk_buf[0..to_copy]);
        }
    }

    // --- Pack into a single allocation for simple deinit ---
    // Layout: reason | header names+values | body  (no padding, cumulative offsets)
    const reason_len = reason.len;
    var headers_flat_len: usize = 0;
    for (header_list.items) |h| {
        headers_flat_len += h.name.len + h.value.len;
    }
    const total_len = reason_len + headers_flat_len + resp_body.items.len;

    const base = try alloc.alloc(u8, total_len);
    errdefer alloc.free(base);

    // Once copied, free temporary duplicates in header_list (avoid leaks).
    defer for (header_list.items) |h| {
        alloc.free(h.name);
        alloc.free(h.value);
    };

    var off: usize = 0;
    // reason
    @memcpy(base[off .. off + reason.len], reason);
    const reason_out = base[off .. off + reason.len];
    off += reason.len;

    // headers: Header array pointing into base
    const headers_out = try alloc.alloc(Response.Header, header_list.items.len);
    errdefer alloc.free(headers_out);
    for (header_list.items, 0..) |h, idx| {
        @memcpy(base[off .. off + h.name.len], h.name);
        const name_out = base[off .. off + h.name.len];
        off += h.name.len;
        @memcpy(base[off .. off + h.value.len], h.value);
        const value_out = base[off .. off + h.value.len];
        off += h.value.len;
        headers_out[idx] = .{ .name = name_out, .value = value_out };
    }

    // body
    @memcpy(base[off .. off + resp_body.items.len], resp_body.items);
    const body_out = base[off .. off + resp_body.items.len];

    return .{
        .status = status,
        .reason = reason_out,
        .headers = headers_out,
        .body = body_out,
        .total_body_bytes = total_bytes,
        .truncated = total_bytes > resp_body.items.len,
        .intern_base = base,
        .intern_headers = headers_out,
    };
}

pub const DownloadResult = struct {
    status: u16,
    total_bytes: usize,
    error_message: ?[]const u8 = null,
};

/// Download an HTTP resource directly into a file on disk in chunks (RFC-011 §3.3).
/// Avoids loading large bodies (e.g. 200MB video) into memory buffers.
pub fn downloadToFile(
    alloc: Allocator,
    io: std.Io,
    opts: Options,
    target_path: []const u8,
) !DownloadResult {
    var client = std.http.Client{
        .allocator = alloc,
        .io = io,
    };
    defer client.deinit();
    initTlsState(&client, io);

    const http_method = try parseMethod(opts.method);

    var extra_headers: []std.http.Header = &.{};
    var extra_headers_owned = false;
    defer if (extra_headers_owned) {
        for (extra_headers) |h| {
            alloc.free(h.name);
            alloc.free(h.value);
        }
        alloc.free(extra_headers);
    };
    if (opts.headers_json) |hj| {
        extra_headers = try parseHeadersJson(alloc, hj);
        extra_headers_owned = true;
    }

    const uri = try std.Uri.parse(opts.url);
    var req = try client.request(http_method, uri, .{
        .extra_headers = extra_headers,
        .headers = .{
            .accept_encoding = .omit,
        },
        .keep_alive = false,
        .connection = preconnectIpv4(&client, uri),
    });
    defer req.deinit();

    if (opts.body) |b| {
        if (b.len > 0) {
            req.transfer_encoding = .{ .content_length = b.len };
            var req_body = try req.sendBodyUnflushed(&.{});
            try req_body.writer.writeAll(b);
            try req_body.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);

    var transfer_buf: [4096]u8 = undefined;
    const r = response.reader(&transfer_buf);

    if (status < 200 or status >= 300) {
        var err_buf: [2048]u8 = undefined;
        const n = r.readSliceShort(&err_buf) catch 0;
        const msg = if (n > 0) try alloc.dupe(u8, err_buf[0..n]) else null;
        return DownloadResult{
            .status = status,
            .total_bytes = 0,
            .error_message = msg,
        };
    }

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, target_path, .{});
    defer file.close(io);

    var chunk_buf: [16 * 1024]u8 = undefined;
    var total_bytes: usize = 0;
    while (true) {
        if (signals.isInterrupted()) return error.Interrupted;
        const n = r.readSliceShort(&chunk_buf) catch |e| {
            if (total_bytes > 0) break;
            return e;
        };
        if (signals.isInterrupted()) return error.Interrupted;
        if (n == 0) break;
        total_bytes += n;
        if (total_bytes > opts.max_body_size) {
            return error.FileTooLarge;
        }
        try file.writeStreamingAll(io, chunk_buf[0..n]);
    }

    return DownloadResult{
        .status = status,
        .total_bytes = total_bytes,
    };
}

// ---------------------------------------------------------------------------
// postStream — streaming cho SSE / NDJSON (backends AI)
// ---------------------------------------------------------------------------

/// Callback receiving each data chunk from HTTP response (streaming).
/// `chunk` is a temporary slice — must be copied if retained.
/// `userdata` is a pointer to caller's context struct.
pub const StreamChunkFn = *const fn (chunk: []const u8, userdata: *anyopaque) void;

/// Options for streaming POST (similar to legacy sse.post).
pub const StreamOptions = struct {
    /// Full URL (http:// or https://).
    url: []const u8,
    /// Headers in "Key: Value" format.
    headers: []const []const u8 = &.{},
    /// POST body (JSON string).
    body: []const u8 = "",
    /// Total timeout (seconds). Default: 120.
    timeout_secs: u32 = 120,
    /// Idle (stall) watchdog: abort recv if no bytes arrive for this many
    /// seconds (RFC-009 Phase 5). Kernel-level SO_RCVTIMEO; 0 = disabled.
    idle_timeout_secs: u32 = 0,
    /// Out flag: set true when the stream was aborted by the idle watchdog
    /// after partial data was already received (partial content preserved).
    out_idle_aborted: ?*bool = null,
};

/// Parse list of headers in "Key: Value" format → []std.http.Header (duplicated).
pub fn parseHeadersKv(alloc: Allocator, headers: []const []const u8) ![]std.http.Header {
    var list = std.ArrayList(std.http.Header).empty;
    errdefer list.deinit(alloc);
    for (headers) |hdr| {
        if (std.mem.indexOfScalar(u8, hdr, ':')) |idx| {
            const name = std.mem.trim(u8, hdr[0..idx], " \t");
            const value = std.mem.trim(u8, hdr[idx + 1 ..], " \t");
            if (name.len == 0) continue;
            try list.append(alloc, .{
                .name = try alloc.dupe(u8, name),
                .value = try alloc.dupe(u8, value),
            });
        }
    }
    return list.toOwnedSlice(alloc);
}

fn freeHeadersKv(alloc: Allocator, headers: []std.http.Header) void {
    for (headers) |h| {
        alloc.free(h.name);
        alloc.free(h.value);
    }
    alloc.free(headers);
}

/// Send HTTP POST and stream response chunk-by-chunk via `on_chunk` callback.
/// Returns HTTP status code. Used for SSE/NDJSON across AI backends.
pub fn postStream(
    alloc: Allocator,
    io: std.Io,
    opts: StreamOptions,
    on_chunk: StreamChunkFn,
    userdata: *anyopaque,
) !u32 {
    var client = std.http.Client{
        .allocator = alloc,
        .io = io,
    };
    defer client.deinit();

    // See fetch(): redirect http → https requires pre-warmed TLS state.
    initTlsState(&client, io);

    const extra_headers = try parseHeadersKv(alloc, opts.headers);
    defer freeHeadersKv(alloc, extra_headers);

    const uri = try std.Uri.parse(opts.url);
    var req = try client.request(.POST, uri, .{
        .extra_headers = extra_headers,
        .headers = .{
            .accept_encoding = .omit,
        },
        .keep_alive = false,
        // Prefer IPv4 when available (works around blackholed IPv6 routes,
        // which otherwise fail as TlsInitializationFailed during handshake).
        .connection = preconnectIpv4(&client, uri),
    });
    defer req.deinit();

    // Send body
    // POST must always have a body (sendBodiless asserts !method.requestHasBody()
    // → panics with POST/PUT). Send content_length = 0 when body is empty.
    req.transfer_encoding = .{ .content_length = opts.body.len };
    var req_body = try req.sendBodyUnflushed(&.{});
    if (opts.body.len > 0) {
        try req_body.writer.writeAll(opts.body);
    }
    try req_body.end();
    try req.connection.?.flush();

    var redirect_buffer: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    // Read streaming chunks
    var transfer_buf: [4096]u8 = undefined;
    const r = response.reader(&transfer_buf);

    // Idle fd for the Stream Stall Watchdog (RFC-009 Phase 5).
    const watch_fd: ?posix.socket_t = if (opts.idle_timeout_secs > 0)
        (if (req.connection) |conn| conn.stream_reader.stream.socket.handle else null)
    else
        null;

    // Wall-clock deadline: absolute max stream duration from response headers receipt.
    // Prevents extended-thinking models (e.g. reasoning_effort=high) from hanging
    // indefinitely when TCP keepalive/TLS heartbeat fools the poll-based idle watchdog.
    const deadline_ms: i64 = blk: {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
        const start_ms = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1000000);
        // Use the smaller of total timeout or 6x idle timeout as absolute ceiling.
        // This handles: idle=60s → deadline=120s (matches timeout_secs default),
        // idle=15s → deadline=90s, etc. Prevents 3h+ hangs from extended thinking.
        const abs_max: u32 = @min(opts.timeout_secs, @max(opts.idle_timeout_secs, 1) * 6);
        break :blk start_ms + @as(i64, @intCast(abs_max)) * 1000;
    };

    var got_any = false;
    const read_result: anyerror!void = blk: {
        while (true) {
            if (signals.isInterrupted()) break :blk error.Interrupted;
            // Wall-clock check: abort if total stream duration exceeded.
            {
                var ts_now: std.os.linux.timespec = undefined;
                _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts_now);
                const now_ms = @as(i64, @intCast(ts_now.sec)) * 1000 + @divTrunc(ts_now.nsec, 1000000);
                if (now_ms >= deadline_ms) {
                    if (opts.out_idle_aborted) |flag| flag.* = true;
                    if (!got_any) return error.StreamIdleTimeout;
                    break :blk error.StreamIdleTimeout;
                }
            }
            // Stream Stall Watchdog: poll with idle timeout before each blocked
            // read. If the server goes silent for > idle_timeout_secs, abort
            // instead of blocking until the total timeout (120s) elapses.
            if (watch_fd) |fd| {
                if (r.bufferedLen() == 0) {
                    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
                    const timeout_ms: i32 = @intCast(@as(u64, opts.idle_timeout_secs) * 1000);
                    const prc = posix.poll(&fds, timeout_ms) catch |e| break :blk e;
                    if (prc == 0) {
                        // No bytes within the idle window → stream stalled.
                        if (opts.out_idle_aborted) |flag| flag.* = true;
                        if (!got_any) return error.StreamIdleTimeout;
                        break :blk error.StreamIdleTimeout;
                    }
                }
            }
            const chunk = r.peekGreedy(1) catch |e| switch (e) {
                error.EndOfStream => break :blk {},
                else => break :blk e,
            };
            if (signals.isInterrupted()) break :blk error.Interrupted;
            if (chunk.len == 0) break :blk {};
            got_any = true;
            on_chunk(chunk, userdata);
            r.toss(chunk.len);
        }
        break :blk {};
    };
    if (read_result) |_| {} else |e| {
        if (e == error.Interrupted) return error.Interrupted;
        if (e == error.StreamIdleTimeout) return error.StreamIdleTimeout;
        
        return e;
    }

    return @intFromEnum(response.head.status);
}

// ---------------------------------------------------------------------------
// Tests — unit + integration with local HTTP server (std.Io.net)
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Context for test server running on separate thread: reads 1 request, writes 1 response.
const TestServerCtx = struct {
    io: std.Io,
    port: u16,
    /// Response bytes server will send (raw HTTP/1.1, NOT chunked).
    response: []const u8,
    /// Number of requests to serve before exiting.
    max_requests: u32,
    /// Raw request received (to assert method/path/body).
    received: std.ArrayList(u8),
    received_mutex: std.Io.Mutex = .init,
    done: std.Io.Event = .unset,

    fn run(self: *TestServerCtx) void {
        self.serve() catch |e| {
            std.debug.print("[test-server] error: {s}\n", .{@errorName(e)});
        };
        self.done.set(self.io);
    }

    fn serve(self: *TestServerCtx) !void {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port);
        var server = try addr.listen(self.io, .{ .reuse_address = true });
        defer server.deinit(self.io);

        var served: u32 = 0;
        while (served < self.max_requests) : (served += 1) {
            var stream = try server.accept(self.io);
            defer stream.close(self.io);

            var read_buf: [16384]u8 = undefined;
            var s_reader = stream.reader(self.io, &read_buf);
            var write_buf: [16384]u8 = undefined;
            var s_writer = stream.writer(self.io, &write_buf);

            // Read request: head + body until full content-length.
            const head = s_reader.interface.peekGreedy(1) catch break;
            const content_len: usize = blk: {
                if (std.mem.indexOf(u8, head, "content-length:")) |p| {
                    const line_end = std.mem.indexOfPos(u8, head, p, "\r\n") orelse head.len;
                    const val = std.mem.trim(u8, head[p + 16 .. line_end], " ");
                    break :blk std.fmt.parseInt(usize, val, 10) catch 0;
                }
                break :blk 0;
            };
            var have: usize = 0;
            if (std.mem.indexOf(u8, head, "\r\n\r\n")) |bs| have = head.len - bs - 4;
            while (have < content_len) {
                const more = s_reader.interface.peekGreedy(1) catch break;
                const bs = std.mem.indexOf(u8, more, "\r\n\r\n") orelse continue;
                const new_have = more.len - bs - 4;
                if (new_have <= have) break;
                have = new_have;
            }

            {
                try self.received_mutex.lock(self.io);
                defer self.received_mutex.unlock(self.io);
                self.received.appendSlice(testing.allocator, head) catch {};
            }

            try s_writer.interface.writeAll(self.response);
            try s_writer.interface.flush();
        }
    }
};

/// Helper: bind ephemeral port, return actual port (immediately unbind for reuse).
fn ephemeralPort(io: std.Io) !u16 {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var s = try addr.listen(io, .{ .reuse_address = true });
    defer s.deinit(io);
    return s.socket.address.getPort();
}

/// Run fetch with test server. Manages thread lifecycle + cleanup.
const FetchHarness = struct {
    ctx: TestServerCtx,
    thread: ?std.Thread,
    io: std.Io,

    fn init(io: std.Io, response: []const u8, max_requests: u32) !FetchHarness {
        return .{
            .ctx = .{
                .io = io,
                .port = try ephemeralPort(io),
                .response = response,
                .max_requests = max_requests,
                .received = std.ArrayList(u8).empty,
            },
            .thread = null,
            .io = io,
        };
    }

    fn start(self: *FetchHarness) !void {
        self.thread = try std.Thread.spawn(.{}, TestServerCtx.run, .{&self.ctx});
    }

    fn url(self: *const FetchHarness, alloc: Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}{s}", .{ self.ctx.port, path });
    }

    fn deinit(self: *FetchHarness) void {
        self.ctx.done.waitUncancelable(self.io);
        if (self.thread) |t| t.join();
        self.ctx.received.deinit(testing.allocator);
    }
};

// -------------------------------------------------------------------------
// Unit tests: parseMethod
// -------------------------------------------------------------------------

test "parseMethod: valid + case-insensitive" {
    try testing.expectEqual(std.http.Method.GET, try parseMethod("GET"));
    try testing.expectEqual(std.http.Method.GET, try parseMethod("get"));
    try testing.expectEqual(std.http.Method.POST, try parseMethod("post"));
    try testing.expectEqual(std.http.Method.DELETE, try parseMethod("Delete"));
    try testing.expectEqual(std.http.Method.PATCH, try parseMethod("PATCH"));
    try testing.expectEqual(std.http.Method.HEAD, try parseMethod("HEAD"));
    try testing.expectEqual(std.http.Method.OPTIONS, try parseMethod("options"));
    try testing.expectEqual(std.http.Method.PUT, try parseMethod("PUT"));
}

test "parseMethod: invalid format" {
    try testing.expectError(error.InvalidMethod, parseMethod("BREW"));
    try testing.expectError(error.InvalidMethod, parseMethod(""));
    try testing.expectError(error.InvalidMethod, parseMethod("TOOLONGMETHODXX"));
}

// -------------------------------------------------------------------------
// Unit tests: parseHeadersJson
// -------------------------------------------------------------------------

fn freeHeaders(alloc: Allocator, headers: []std.http.Header) void {
    for (headers) |h| {
        alloc.free(h.name);
        alloc.free(h.value);
    }
    alloc.free(headers);
}

test "parseHeadersJson: simple object" {
    const alloc = testing.allocator;
    const headers = try parseHeadersJson(alloc, "{\"User-Agent\":\"test\",\"Accept\":\"text/html\"}");
    defer freeHeaders(alloc, headers);
    try testing.expectEqual(@as(usize, 2), headers.len);
    try testing.expectEqualStrings("User-Agent", headers[0].name);
    try testing.expectEqualStrings("test", headers[0].value);
    try testing.expectEqualStrings("Accept", headers[1].name);
    try testing.expectEqualStrings("text/html", headers[1].value);
}

test "parseHeadersJson: flexible whitespace + empty object" {
    const alloc = testing.allocator;
    const h1 = try parseHeadersJson(alloc, "  { \"X-A\" : \"1\" }  ");
    defer freeHeaders(alloc, h1);
    try testing.expectEqual(@as(usize, 1), h1.len);
    try testing.expectEqualStrings("X-A", h1[0].name);

    const empty = try parseHeadersJson(alloc, "{}");
    defer freeHeaders(alloc, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "parseHeadersJson: escape sequences" {
    const alloc = testing.allocator;
    const headers = try parseHeadersJson(alloc,
        \\{"X-A":"va\"lue","X-B":"line1\nline2","X-C":"tab\there","X-D":"\\slash\/","X-E":"\u0041\u1EA7"}
    );
    defer freeHeaders(alloc, headers);
    try testing.expectEqual(@as(usize, 5), headers.len);
    try testing.expectEqualStrings("va\"lue", headers[0].value);
    try testing.expectEqualStrings("line1\nline2", headers[1].value);
    try testing.expectEqualStrings("tab\there", headers[2].value);
    try testing.expectEqualStrings("\\slash/", headers[3].value);
    try testing.expectEqualStrings("Aầ", headers[4].value);
}

test "parseHeadersJson: UTF-8 preserved" {
    const alloc = testing.allocator;
    const headers = try parseHeadersJson(alloc, "{\"X-Custom\":\"tiếng Việt 🇻🇳\"}");
    defer freeHeaders(alloc, headers);
    try testing.expectEqualStrings("tiếng Việt 🇻🇳", headers[0].value);
}

test "parseHeadersJson: invalid input" {
    const alloc = testing.allocator;
    try testing.expectError(error.InvalidHeadersJson, parseHeadersJson(alloc, "not json"));
    try testing.expectError(error.InvalidHeadersJson, parseHeadersJson(alloc, "[1,2]"));
    try testing.expectError(error.InvalidHeadersJson, parseHeadersJson(alloc, "{\"a\":1}"));
    try testing.expectError(error.InvalidHeadersJson, parseHeadersJson(alloc, "{\"a\":\"unclosed"));
}

// -------------------------------------------------------------------------
// Unit tests: formatResponseText + Response.getHeader
// -------------------------------------------------------------------------

test "formatResponseText: status + headers + body + truncate note" {
    const alloc = testing.allocator;
    var res = Response{
        .status = 404,
        .reason = "Not Found",
        .headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        .body = @constCast("nothing here"), // 12 bytes
        .total_body_bytes = 100,
        .truncated = true,
    };
    defer res.deinit(alloc);

    const text = try formatResponseText(alloc, &res);
    defer alloc.free(text);

    try testing.expect(std.mem.startsWith(u8, text, "HTTP 404 Not Found\n"));
    try testing.expect(std.mem.indexOf(u8, text, "content-type: text/plain\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n\nnothing here") != null);
    // omitted = total_body_bytes - body.len = 100 - 12 = 88
    try testing.expect(std.mem.indexOf(u8, text, "... [truncated 88 bytes]") != null);
}

test "formatResponseText: 200 without truncation" {
    const alloc = testing.allocator;
    var res = Response{
        .status = 200,
        .reason = "OK",
        .headers = &.{},
        .body = @constCast("hello"),
        .total_body_bytes = 5,
        .truncated = false,
    };
    defer res.deinit(alloc);

    const text = try formatResponseText(alloc, &res);
    defer alloc.free(text);
    try testing.expectEqualStrings("HTTP 200 OK\n\nhello", text);
}

test "Response.getHeader: case-insensitive" {
    var res = Response{
        .status = 200,
        .reason = "OK",
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-Custom", .value = "abc" },
        },
        .body = @constCast(""),
        .total_body_bytes = 0,
        .truncated = false,
    };
    defer res.deinit(testing.allocator);

    try testing.expectEqualStrings("application/json", res.getHeader("content-type").?);
    try testing.expectEqualStrings("application/json", res.getHeader("CONTENT-TYPE").?);
    try testing.expectEqualStrings("abc", res.getHeader("x-custom").?);
    try testing.expect(res.getHeader("x-missing") == null);
}

// -------------------------------------------------------------------------
// Integration tests: fetch with local HTTP server
// -------------------------------------------------------------------------

test "fetch GET: separated status/headers/body — regression bug body mixed with headers" {
    const alloc = testing.allocator;
    const io = testing.io;

    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "content-type: application/json\r\n" ++
        "x-custom: hello\r\n" ++
        "content-length: 28\r\n" ++
        "\r\n" ++
        "{\"msg\":\"xin chào 🇻🇳\"}"; // 28 bytes UTF-8 (flag = 4+4 codepoints)

    var h = try FetchHarness.init(io, response, 1);
    defer h.deinit();
    try h.start();

    const u = try h.url(alloc, "/test");
    defer alloc.free(u);

    var res = fetch(alloc, io, .{ .url = u, .timeout_s = 10 }) catch |e| {
        h.deinit();
        return e;
    };
    defer res.deinit(alloc);

    try testing.expectEqual(@as(u16, 200), res.status);
    try testing.expectEqualStrings("OK", res.reason);
    try testing.expectEqualStrings("application/json", res.getHeader("Content-Type").?);
    try testing.expectEqualStrings("hello", res.getHeader("X-Custom").?);
    // Body must ONLY be body — old bug returned status line + headers inside body
    try testing.expectEqualStrings("{\"msg\":\"xin chào 🇻🇳\"}", res.body);
    try testing.expect(!res.truncated);
    try testing.expectEqual(@as(usize, 28), res.total_body_bytes);
}

test "fetch POST: send body + custom headers, server receives complete" {
    const alloc = testing.allocator;
    const io = testing.io;

    const response =
        "HTTP/1.1 201 Created\r\n" ++
        "content-length: 7\r\n" ++
        "\r\n" ++
        "created";

    var h = try FetchHarness.init(io, response, 1);
    defer h.deinit();
    try h.start();

    const u = try h.url(alloc, "/api/items");
    defer alloc.free(u);

    var res = fetch(alloc, io, .{
        .url = u,
        .method = "POST",
        .body = "{\"name\":\"test item\",\"qty\":3}",
        .headers_json = "{\"Content-Type\":\"application/json\",\"X-Trace-Id\":\"abc-123\"}",
        .timeout_s = 10,
    }) catch {
        h.deinit();
        return error.TestUnexpectedResult;
    };
    defer res.deinit(alloc);

    try testing.expectEqual(@as(u16, 201), res.status);
    try testing.expectEqualStrings("created", res.body);

    // Assert request received by server
    try h.ctx.received_mutex.lock(h.io);
    defer h.ctx.received_mutex.unlock(h.io);
    const req = h.ctx.received.items;
    try testing.expect(std.mem.startsWith(u8, req, "POST /api/items HTTP/1.1"));
    try testing.expect(std.mem.indexOf(u8, req, "content-type: application/json") != null or
        std.mem.indexOf(u8, req, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, req, "x-trace-id: abc-123") != null or
        std.mem.indexOf(u8, req, "X-Trace-Id: abc-123") != null);
    try testing.expect(std.mem.endsWith(u8, req, "{\"name\":\"test item\",\"qty\":3}"));
}

test "fetch GET 404: correct status, error body still readable" {
    const alloc = testing.allocator;
    const io = testing.io;

    const response =
        "HTTP/1.1 404 Not Found\r\n" ++
        "content-length: 9\r\n" ++
        "\r\n" ++
        "not found";

    var h = try FetchHarness.init(io, response, 1);
    defer h.deinit();
    try h.start();

    const u = try h.url(alloc, "/missing");
    defer alloc.free(u);

    var res = fetch(alloc, io, .{ .url = u, .timeout_s = 10 }) catch {
        h.deinit();
        return error.TestUnexpectedResult;
    };
    defer res.deinit(alloc);

    try testing.expectEqual(@as(u16, 404), res.status);
    try testing.expectEqualStrings("Not Found", res.reason);
    try testing.expectEqualStrings("not found", res.body);
}

test "fetch: empty body (content-length 0)" {
    const alloc = testing.allocator;
    const io = testing.io;

    const response =
        "HTTP/1.1 204 No Content\r\n" ++
        "content-length: 0\r\n" ++
        "\r\n";

    var h = try FetchHarness.init(io, response, 1);
    defer h.deinit();
    try h.start();

    const u = try h.url(alloc, "/empty");
    defer alloc.free(u);

    var res = fetch(alloc, io, .{ .url = u, .timeout_s = 10 }) catch {
        h.deinit();
        return error.TestUnexpectedResult;
    };
    defer res.deinit(alloc);

    try testing.expectEqual(@as(u16, 204), res.status);
    try testing.expectEqual(@as(usize, 0), res.body.len);
    try testing.expect(!res.truncated);
}

test "fetch: truncation when body exceeds max_body_size" {
    const alloc = testing.allocator;
    const io = testing.io;

    // Body 100 bytes 'a', max_body_size = 10 → retain only 10
    var body: [100]u8 = undefined;
    @memset(&body, 'a');

    var response_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n{s}", .{body[0..]});

    var h = try FetchHarness.init(io, response, 1);
    defer h.deinit();
    try h.start();

    const u = try h.url(alloc, "/big");
    defer alloc.free(u);

    var res = fetch(alloc, io, .{ .url = u, .max_body_size = 10, .timeout_s = 10 }) catch {
        h.deinit();
        return error.TestUnexpectedResult;
    };
    defer res.deinit(alloc);

    try testing.expectEqual(@as(u16, 200), res.status);
    try testing.expectEqual(@as(usize, 10), res.body.len);
    try testing.expect(res.truncated);
    try testing.expectEqual(@as(usize, 100), res.total_body_bytes);
}

test "fetch: invalid scheme/host URL returns error" {
    const alloc = testing.allocator;
    const io = testing.io;
    // Malformed URL → error from Uri.parse
    try testing.expectError(error.InvalidFormat, fetch(alloc, io, .{ .url = "not a url" }));
    // Non-existent host → connection error
    const r = fetch(alloc, io, .{ .url = "http://127.0.0.1:1/", .timeout_s = 5 });
    try testing.expectError(error.ConnectionRefused, r);
}

// -------------------------------------------------------------------------
// Integration tests: postStream (streaming SSE)
// -------------------------------------------------------------------------

const StreamAccumCtx = struct {
    buf: std.ArrayList(u8),
    chunks: usize,

    fn onChunk(chunk: []const u8, userdata: *anyopaque) void {
        const self: *StreamAccumCtx = @ptrCast(@alignCast(userdata));
        self.buf.appendSlice(testing.allocator, chunk) catch {};
        self.chunks += 1;
    }
};

test "postStream: SSE stream receives all chunks + status" {
    const alloc = testing.allocator;
    const io = testing.io;

    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "content-type: text/event-stream\r\n" ++
        "content-length: 32\r\n" ++
        "\r\n" ++
        "data: a\n\ndata: b\n\ndata: c\n\n";

    var h = try FetchHarness.init(io, response, 1);
    defer h.deinit();
    try h.start();

    const u = try h.url(alloc, "/v1/stream");
    defer alloc.free(u);

    var ctx = StreamAccumCtx{ .buf = .empty, .chunks = 0 };
    defer ctx.buf.deinit(alloc);

    const status = postStream(alloc, io, .{
        .url = u,
        .body = "{\"q\":1}",
        .headers = &.{"Content-Type: application/json"},
        .timeout_secs = 10,
    }, StreamAccumCtx.onChunk, &ctx) catch {
        h.deinit();
        return error.TestUnexpectedResult;
    };

    try testing.expectEqual(@as(u32, 200), status);
    try testing.expectEqualStrings("data: a\n\ndata: b\n\ndata: c\n\n", ctx.buf.items);
    try testing.expect(ctx.chunks >= 1);
}

/// Epoch milliseconds via raw clock (Zig 0.16 moved std.time.milliTimestamp).
fn testMilliTimestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1000000);
}

/// Server that sends a partial response then holds the connection open and
/// silent, for testing the stream stall watchdog (RFC-009 Phase 5).
const SilentServerCtx = struct {
    io: std.Io,
    port: u16,
    response: []const u8,
    ready: std.Io.Event = .unset,
    done: std.Io.Event = .unset,

    fn run(self: *SilentServerCtx) void {
        self.serve() catch {};
        self.done.set(self.io);
    }

    fn serve(self: *SilentServerCtx) !void {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port);
        var server = try addr.listen(self.io, .{ .reuse_address = true });
        defer server.deinit(self.io);
        self.ready.set(self.io);
        var stream = try server.accept(self.io);
        defer stream.close(self.io);
        // Read client request head
        var read_buf: [8192]u8 = undefined;
        var s_reader = stream.reader(self.io, &read_buf);
        _ = s_reader.interface.peekGreedy(1) catch {};
        // Send partial response
        var write_buf: [8192]u8 = undefined;
        var s_writer = stream.writer(self.io, &write_buf);
        try s_writer.interface.writeAll(self.response);
        try s_writer.interface.flush();
        // Hold the connection open well past the client's idle window (1s).
        var ts: std.os.linux.timespec = .{ .sec = 3, .nsec = 0 };
        _ = std.os.linux.nanosleep(&ts, &ts);
    }
};

test "postStream: idle watchdog aborts silent stream with partial data" {
    const alloc = testing.allocator;
    const io = testing.io;

    // Valid SSE headers + one data line, then nothing — the server goes silent.
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "content-type: text/event-stream\r\n" ++
        "\r\n" ++
        "data: partial\n\n";

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var bind_server = try addr.listen(io, .{ .reuse_address = true });
    const port = bind_server.socket.address.getPort();
    bind_server.deinit(io);

    var srv = SilentServerCtx{ .io = io, .port = port, .response = response };
    const thread = try std.Thread.spawn(.{}, SilentServerCtx.run, .{&srv});
    defer thread.join();
    defer srv.done.wait(io) catch {};
    try srv.ready.wait(io);

    const u = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/v1/stream", .{port});
    defer alloc.free(u);

    var ctx = StreamAccumCtx{ .buf = .empty, .chunks = 0 };
    defer ctx.buf.deinit(alloc);

    var idle_aborted = false;
    const start_ms = testMilliTimestamp();
    const result = postStream(alloc, io, .{
        .url = u,
        .body = "{\"q\":1}",
        .headers = &.{"Content-Type: application/json"},
        .timeout_secs = 30,
        .idle_timeout_secs = 1,
        .out_idle_aborted = &idle_aborted,
    }, StreamAccumCtx.onChunk, &ctx);

    const elapsed = testMilliTimestamp() - start_ms;

    // Watchdog must fire: error returned, flag set, partial data preserved.
    try testing.expectError(error.StreamIdleTimeout, result);
    try testing.expect(idle_aborted);
    try testing.expectEqualStrings("data: partial\n\n", ctx.buf.items);
    // Must abort well before a full-request timeout would (30s).
    try testing.expect(elapsed < 3 * std.time.ns_per_s / std.time.ns_per_ms);
}
