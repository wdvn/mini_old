//! mod.zig — Provider profile modules registry (RFC-012).

pub const openai = @import("openai.zig");
pub const deepseek = @import("deepseek.zig");
pub const qwen = @import("qwen.zig");
pub const minimax = @import("minimax.zig");
pub const glm = @import("glm.zig");
pub const kimi = @import("kimi.zig");
pub const xai = @import("xai.zig");
pub const vllm = @import("vllm.zig");
pub const generic = @import("generic.zig");
pub const agnes = @import("agnes.zig");
