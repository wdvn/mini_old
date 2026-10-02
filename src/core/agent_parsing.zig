//! agent_parsing.zig — Backward-compatibility forwarder for `core/agent/parsing.zig`.

const parsing = @import("agent/parsing.zig");
pub const extractJsCodeBlock = parsing.extractJsCodeBlock;
pub const convertXmlToolTagsToJs = parsing.convertXmlToolTagsToJs;
pub const findJsCodeInResponse = parsing.findJsCodeInResponse;
pub const parseTimeoutDecision = parsing.parseTimeoutDecision;
