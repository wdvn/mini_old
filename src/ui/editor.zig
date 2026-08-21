const std = @import("std");

pub const LineEditor = struct {
    alloc: std.mem.Allocator,
    history: std.ArrayListUnmanaged([]const u8),
    history_index: usize,

    pub fn init(alloc: std.mem.Allocator) LineEditor {
        return .{
            .alloc = alloc,
            .history = .empty,
            .history_index = 0,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        for (self.history.items) |item| {
            self.alloc.free(item);
        }
        self.history.deinit(self.alloc);
    }

    pub fn addHistory(self: *LineEditor, line: []const u8) !void {
        if (line.len == 0) return;
        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, line)) return;
        }
        const dup = try self.alloc.dupe(u8, line);
        try self.history.append(self.alloc, dup);
    }

    pub fn readLine(self: *LineEditor, io: std.Io, prompt: []const u8) !?[]const u8 {
        const stdin_fd = std.posix.STDIN_FILENO;
        const stdout_file = std.Io.File.stdout();
        const stdin_file = std.Io.File.stdin();

        const orig_termios = try std.posix.tcgetattr(stdin_fd);
        var raw = orig_termios;
        
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = true; 
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        
        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        defer std.posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};

        var buf: [8192]u8 = undefined;
        var len: usize = 0;
        var pos: usize = 0;
        
        self.history_index = self.history.items.len;
        
        self.redraw(io, prompt, &buf, len, pos);

        while (true) {
            var char_buf: [1]u8 = undefined;
            const n = try stdin_file.readStreaming(io, &.{&char_buf});
            if (n == 0) return null;

            switch (char_buf[0]) {
                3, 4 => return null, 
                13, 10 => { 
                    stdout_file.writeStreamingAll(io, "\r\n") catch {};
                    return try self.alloc.dupe(u8, buf[0..len]);
                },
                127, 8 => { 
                    if (pos > 0) {
                        std.mem.copyForwards(u8, buf[pos-1..len-1], buf[pos..len]);
                        pos -= 1;
                        len -= 1;
                        self.redraw(io, prompt, &buf, len, pos);
                    }
                },
                1 => { pos = 0; self.redraw(io, prompt, &buf, len, pos); },
                5 => { pos = len; self.redraw(io, prompt, &buf, len, pos); },
                21 => { 
                    std.mem.copyForwards(u8, buf[0..len-pos], buf[pos..len]);
                    len -= pos;
                    pos = 0;
                    self.redraw(io, prompt, &buf, len, pos);
                },
                27 => { 
                    var seq: [2]u8 = undefined;
                    if ((stdin_file.readStreaming(io, &.{seq[0..1]}) catch 0) == 0) continue;
                    if ((stdin_file.readStreaming(io, &.{seq[1..2]}) catch 0) == 0) continue;
                    
                    if (seq[0] == '[') {
                        if (seq[1] == 'A') { 
                            if (self.history_index > 0) {
                                self.history_index -= 1;
                                const h = self.history.items[self.history_index];
                                const cp = @min(h.len, buf.len);
                                std.mem.copyForwards(u8, buf[0..cp], h[0..cp]);
                                len = cp;
                                pos = cp;
                                self.redraw(io, prompt, &buf, len, pos);
                            }
                        } else if (seq[1] == 'B') { 
                            if (self.history_index < self.history.items.len) {
                                self.history_index += 1;
                                if (self.history_index == self.history.items.len) {
                                    len = 0;
                                    pos = 0;
                                } else {
                                    const h = self.history.items[self.history_index];
                                    const cp = @min(h.len, buf.len);
                                    std.mem.copyForwards(u8, buf[0..cp], h[0..cp]);
                                    len = cp;
                                    pos = cp;
                                }
                                self.redraw(io, prompt, &buf, len, pos);
                            }
                        } else if (seq[1] == 'C') { 
                            if (pos < len) {
                                pos += 1;
                                self.redraw(io, prompt, &buf, len, pos);
                            }
                        } else if (seq[1] == 'D') { 
                            if (pos > 0) {
                                pos -= 1;
                                self.redraw(io, prompt, &buf, len, pos);
                            }
                        } else if (seq[1] == '3') { 
                            var tilde: [1]u8 = undefined;
                            _ = stdin_file.readStreaming(io, &.{&tilde}) catch 0;
                            if (tilde[0] == '~' and pos < len) {
                                std.mem.copyForwards(u8, buf[pos..len-1], buf[pos+1..len]);
                                len -= 1;
                                self.redraw(io, prompt, &buf, len, pos);
                            }
                        }
                    } else if (seq[0] == 'O') {
                        if (seq[1] == 'H') {
                            pos = 0;
                            self.redraw(io, prompt, &buf, len, pos);
                        } else if (seq[1] == 'F') {
                            pos = len;
                            self.redraw(io, prompt, &buf, len, pos);
                        }
                    }
                },
                else => {
                    if (char_buf[0] >= 32 and len < buf.len) {
                        std.mem.copyBackwards(u8, buf[pos+1..len+1], buf[pos..len]);
                        buf[pos] = char_buf[0];
                        pos += 1;
                        len += 1;
                        self.redraw(io, prompt, &buf, len, pos);
                    }
                }
            }
        }
        
        return null;
    }

    fn redraw(self: *LineEditor, io: std.Io, p: []const u8, b: []const u8, l: usize, c: usize) void {
        _ = self;
        var out_buf: [8192]u8 = undefined;
        var curr: usize = 0;
        
        const clear_str = "\x1b[2K\r";
        std.mem.copyForwards(u8, out_buf[curr..], clear_str);
        curr += clear_str.len;
        
        std.mem.copyForwards(u8, out_buf[curr..], p);
        curr += p.len;
        
        std.mem.copyForwards(u8, out_buf[curr..], b[0..l]);
        curr += l;
        
        if (c < l) {
            const diff = l - c;
            var fmt_buf: [32]u8 = undefined;
            const seq = std.fmt.bufPrint(&fmt_buf, "\x1b[{d}D", .{diff}) catch "";
            std.mem.copyForwards(u8, out_buf[curr..], seq);
            curr += seq.len;
        }
        
        const stdout_file = std.Io.File.stdout();
        stdout_file.writeStreamingAll(io, out_buf[0..curr]) catch {};
    }
};
