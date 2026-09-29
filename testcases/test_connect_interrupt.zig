//! test_connect_interrupt.zig — Regression test: Ctrl+C must not stall on a blackholed TCP connect.
//!
//! Background: `preconnectIpv4` performed a blocking `connectTcpOptions`, which
//! std 0.16.0 issues with no timeout (the `ConnectTcpOptions.timeout` field is
//! never read, and the POSIX backend panics if one is supplied). On a blackholed
//! route the kernel retries SYN per `tcp_syn_retries` (~127s at the default 6),
//! during which the executor thread never observed `signals.interrupted`.
//! Symptom: Ctrl+C appeared to do nothing for minutes.
//!
//! These tests pin the observable contract: once `signals.interrupted` is set (or
//! the connect budget expires), the call must return promptly instead of blocking
//! for the kernel retry window.
//!
//! The target is built directly rather than resolved from a URL: `preconnectIpv4`
//! intentionally skips host names that are already IP literals, so a literal-only
//! URL would never reach the connect path under test. 192.0.2.0/24 is RFC 5737
//! TEST-NET-1, guaranteed non-routable, so the connect genuinely blackholes.

const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const http_request = mini.http_request;
const signals = mini.signals_mod;

/// Non-routable address (RFC 5737 TEST-NET-1).
const BLACKHOLE_IP = "192.0.2.1";

fn blackholeTarget() http_request.ConnectTarget {
    // Binary address of 192.0.2.1 (network order), used by the reachability probe.
    const addr4: [4]u8 = .{ 192, 0, 2, 1 };
    var t = http_request.ConnectTarget{
        .ip_str = undefined,
        .ip_len = 0,
        .addr4 = addr4,
        .port = 9,
        .protocol = .plain,
        .host_name = .{ .bytes = BLACKHOLE_IP },
    };
    t.ip_len = BLACKHOLE_IP.len;
    @memcpy(t.ip_str[0..t.ip_len], BLACKHOLE_IP);
    return t;
}

test "connect: interrupt makes connect return promptly instead of blocking on blackhole" {
    const io = testing.io;

    // Arrange: interrupt fires shortly after the connect starts, exactly as it
    // would when a user presses Ctrl+C mid-act.
    signals.setInterrupted(false);
    defer signals.setInterrupted(false);

    const interrupter = try std.Thread.spawn(.{}, struct {
        fn run() void {
            std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
            signals.setInterrupted(true);
        }
    }.run, .{});
    defer interrupter.join();

    // NOTE: `client` is not deinit'd in this test (and on the production
    // abandon path) — the probe closes its own fd on every exit path, so no
    // resource is actually leaked.
    var client = std.http.Client{ .allocator = testing.allocator, .io = io };

    // Act: must abandon the in-flight connect probe and report the interrupt.
    const started = mini.utils.milliTimestamp();
    const result = http_request.connectTargetInterruptible(&client, blackholeTarget(), 60_000);
    const elapsed_ms = mini.utils.milliTimestamp() - started;

    // Assert: interrupted, and fast. A regression (blocking connect) would sit
    // here for ~127s, tripping `elapsed_ms` long before the runner gives up.
    try testing.expectError(error.Interrupted, result);
    try testing.expect(elapsed_ms < 5_000);
}

test "connect: budget expiry returns ConnectTimeout without waiting for the kernel" {
    const io = testing.io;

    signals.setInterrupted(false);
    defer signals.setInterrupted(false);

    var client = std.http.Client{ .allocator = testing.allocator, .io = io };

    // 1s budget: the blackholed route would keep the kernel in SYN retries
    // for ~126s, so only the budget can end this call before then.
    const started = mini.utils.milliTimestamp();
    const result = http_request.connectTargetInterruptible(&client, blackholeTarget(), 1_000);
    const elapsed_ms = mini.utils.milliTimestamp() - started;

    try testing.expectError(error.ConnectTimeout, result);
    try testing.expect(elapsed_ms < 5_000);
}

test "connect: pre-set interrupt short-circuits before the probe socket opens" {
    // Guards the flag check itself: a pre-set interrupt must be observed up
    // front, so no socket is opened and nothing is leaked.
    const io = testing.io;

    signals.setInterrupted(true);
    defer signals.setInterrupted(false);

    var client = std.http.Client{ .allocator = testing.allocator, .io = io };
    const uri = try std.Uri.parse("http://192.0.2.1:9/");

    try testing.expectError(error.Interrupted, http_request.preconnectIpv4Interruptible(&client, uri));
}

test "connect: reachable target succeeds promptly" {
    // PSEUDOCODE:
    // 1. Listen on ephemeral loopback address (127.0.0.1:0).
    // 2. Build ConnectTarget for 127.0.0.1:bound_port with network-order addr4.
    // 3. Call connectTargetInterruptible with a 2s budget.
    // 4. Assert reachable probe succeeds and returns active connection promptly.
    const io = testing.io;

    signals.setInterrupted(false);
    defer signals.setInterrupted(false);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var client = std.http.Client{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    const host_str = "127.0.0.1";
    var target = http_request.ConnectTarget{
        .ip_str = undefined,
        .ip_len = host_str.len,
        .addr4 = .{ 127, 0, 0, 1 },
        .port = port,
        .protocol = .plain,
        .host_name = .{ .bytes = host_str },
    };
    @memcpy(target.ip_str[0..target.ip_len], host_str);

    const started = mini.utils.milliTimestamp();
    const conn = try http_request.connectTargetInterruptible(&client, target, 2_000);
    const elapsed_ms = mini.utils.milliTimestamp() - started;

    try testing.expect(conn != null);
    if (conn) |c| {
        c.closing = true;
        client.connection_pool.release(c, io);
    }
    try testing.expect(elapsed_ms < 1_000);
}


