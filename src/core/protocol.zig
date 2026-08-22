//! protocol.zig — Kiểu dữ liệu chung cho toàn bộ mini-agent.
//!
//! Module này định nghĩa các struct và enum được chia sẻ giữa backends,
//! agent loop và tool dispatcher. Không có logic nghiệp vụ ở đây.
//!
//! ## Kiểu chính
//!   - `Message`        — một tin nhắn trong lịch sử hội thoại
//!   - `ContentBlock`   — khối nội dung (text, tool_use, tool_result)
//!   - `Response`       — phản hồi từ AI backend
//!   - `ToolDefinition` — mô tả tool gửi lên API
//!   - `ToolResult`     — kết quả thực thi tool

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;

// ---------------------------------------------------------------------------
// Message roles
// ---------------------------------------------------------------------------

/// Vai trò của một tin nhắn trong hội thoại.
pub const Role = enum {
    user,
    assistant,

    /// Trả về chuỗi JSON: "user" hoặc "assistant".
    pub fn toJson(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
        };
    }
};

// ---------------------------------------------------------------------------
// Content blocks
// ---------------------------------------------------------------------------

/// Thông tin một lần gọi tool từ AI.
pub const ToolUse = struct {
    /// ID duy nhất của lần gọi này (trả về trong tool result).
    id: []const u8,
    /// Tên tool được gọi.
    name: []const u8,
    /// Tham số dạng JSON string (object).
    input_json: []const u8,
};

/// Kết quả tool đính kèm vào tin nhắn user (trả lời cho tool_use).
pub const ToolResultBlock = struct {
    /// ID khớp với ToolUse.id.
    tool_use_id: []const u8,
    /// Nội dung trả về (plain text hoặc JSON).
    content: []const u8,
    /// Có phải lỗi không (tool thực thi thất bại).
    is_error: bool,
};

/// Khối suy nghĩ (thinking / reasoning) của AI.
pub const ThinkingBlock = struct {
    /// Nội dung luồng suy nghĩ.
    thinking: []const u8,
    /// Chữ ký xác thực của Anthropic (nếu có, có thể rỗng).
    signature: []const u8,
};

/// Một khối nội dung trong message hoặc response.
pub const ContentBlock = union(enum) {
    /// Văn bản thông thường.
    text: []const u8,
    /// Luồng suy nghĩ của AI.
    thinking: ThinkingBlock,
    /// AI yêu cầu thực thi tool.
    tool_use: ToolUse,
    /// Kết quả tool gửi lại cho AI.
    tool_result: ToolResultBlock,
};

/// Cấp bậc ngữ cảnh (MemAct RFC-003).
pub const Tier = enum {
    pinned,
    recent,
    summarized,
    archived,
};

/// Một tin nhắn trong lịch sử hội thoại.
/// `content` là slice sở hữu bởi History — không tự free.
pub const Message = struct {
    role: Role,
    /// Các content block của tin nhắn này.
    content: []const ContentBlock,
    /// Phân cấp ngữ cảnh (MemAct). Null nếu tạo theo cách cũ.
    tier: ?Tier = null,
};

// ---------------------------------------------------------------------------
// Response
// ---------------------------------------------------------------------------

/// Lý do AI dừng sinh text.
pub const StopReason = enum {
    /// Kết thúc tự nhiên.
    end_turn,
    /// AI muốn gọi tool.
    tool_use,
    /// Đã đạt giới hạn token.
    max_tokens,
    /// Stop sequence kích hoạt.
    stop_sequence,
    /// Lý do không xác định.
    unknown,
};

/// Phản hồi đầy đủ từ một AI backend.
/// Gọi `deinit` sau khi dùng xong để giải phóng bộ nhớ.
pub const Response = struct {
    allocator: Allocator,
    /// Tất cả content block trong phản hồi.
    content: ArrayList(ContentBlock),
    /// Lý do dừng.
    stop_reason: StopReason,
    /// HTTP status code (nếu có lỗi/unknown)
    http_code: u32 = 200,
    /// Raw debug info từ backend (khi stop_reason == .unknown)
    raw_debug_info: ?[]const u8,

    /// Khởi tạo Response rỗng.
    pub fn init(alloc: Allocator) Response {
        return .{
            .allocator = alloc,
            .content = .empty,
            .stop_reason = .unknown,
            .http_code = 200,
            .raw_debug_info = null,
        };
    }

    /// Giải phóng toàn bộ bộ nhớ.
    pub fn deinit(self: *Response) void {
        for (self.content.items) |block| {
            switch (block) {
                .text => |t| self.allocator.free(t),
                .thinking => |th| {
                    if (th.thinking.len > 0) self.allocator.free(th.thinking);
                    if (th.signature.len > 0) self.allocator.free(th.signature);
                },
                .tool_use => |tu| {
                    self.allocator.free(tu.id);
                    self.allocator.free(tu.name);
                    self.allocator.free(tu.input_json);
                },
                .tool_result => |tr| {
                    self.allocator.free(tr.tool_use_id);
                    self.allocator.free(tr.content);
                },
            }
        }
        self.content.deinit(self.allocator);
        if (self.raw_debug_info) |raw| self.allocator.free(raw);
    }
};

// ---------------------------------------------------------------------------
// Tool types
// ---------------------------------------------------------------------------

/// Định nghĩa tool gửi lên API để AI biết tool nào có thể dùng.
pub const ToolDefinition = struct {
    /// Tên tool (dùng để dispatch).
    name: []const u8,
    /// Mô tả ngắn gọn cho AI.
    description: []const u8,
    /// JSON Schema của input_parameters (object).
    input_schema_json: []const u8,
};

/// Kết quả thực thi tool để thêm vào history.
pub const ToolResult = struct {
    /// Khớp với ToolUse.id.
    tool_use_id: []const u8,
    /// Output của tool.
    content: []const u8,
    /// True nếu tool báo lỗi.
    is_error: bool,
};
