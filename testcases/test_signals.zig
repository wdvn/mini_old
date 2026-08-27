const std = @import("std");
const testing = std.testing;
const mini = @import("mini");
const signals = mini.signals_mod;
const quickjs = mini.quickjs_engine;

test "signals: atomic set, check, and reset" {
    signals.setInterrupted(false);
    try testing.expect(!signals.isInterrupted());

    signals.setInterrupted(true);
    try testing.expect(signals.isInterrupted());

    const was_interrupted = signals.checkAndResetInterrupted();
    try testing.expect(was_interrupted);
    try testing.expect(!signals.isInterrupted());
}

test "signals: codeact engine interrupt registration" {
    const engine = try quickjs.Engine.init(testing.allocator, std.testing.io);
    defer engine.deinit();

    signals.registerActiveEngine(engine);
    defer signals.registerActiveEngine(null);

    try testing.expect(!engine.is_interrupted);

    signals.setInterrupted(true);
    if (signals.active_engine) |eng| {
        eng.requestInterrupt();
    }
    try testing.expect(engine.is_interrupted);
    signals.setInterrupted(false);
}

test "journal: task_interrupted event type" {
    const ev = mini.agent_mod.journal_mod.ActEventType.task_interrupted;
    try testing.expectEqualStrings("task_interrupted", @tagName(ev));
}

test "signals: initSignalHandlers does not panic" {
    signals.initSignalHandlers();
    signals.setInterrupted(false);
    try testing.expect(!signals.isInterrupted());
}

test "editor: double Ctrl+C interval tracking" {
    const editor_mod = mini.editor_mod;
    var editor = editor_mod.LineEditor.init(testing.allocator);
    defer editor.deinit();

    try testing.expectEqual(@as(i64, 0), editor.last_ctrl_c_ms);
    editor.last_ctrl_c_ms = 1000;
    try testing.expectEqual(@as(i64, 1000), editor.last_ctrl_c_ms);
}

