---
name: technical-rfc-review
description: Study design documents (RFCs, proposals), cross-reference technical specs with current code for gap analysis or architectural review. Use when evaluating proposals, checking design compatibility, or drafting new RFCs.
---

# Technical RFC & Architecture Review Skill

Standard procedure for reviewing, evaluating, and drafting Request for Comments (RFC) proposals in `docs/`.

---

## 1. When to Activate This Skill?

- When preparing major features requiring an RFC proposal first per `AGENTS.md`.
- When cross-referencing existing code against the original RFC design.
- When clarifying architectural decisions (CodeAct vs Tool Calling, Event Sourcing, MemAct, ACP...).

---

## 2. Existing RFC Index in `docs/`

| File | Proposal Name | Technical Focus |
|---|---|---|
| `rfc_000_editor_upgrade_proposal.md` | Line Editor Upgrade | Terminal input, multiline composer, UTF-8, ANSI escape |
| `rfc_001_code_centric_architecture_proposal.md` | Code-Centric Architecture | Embedded QuickJS VM, `mini.*` API, eval loop |
| `rfc_002_long_horizon_event_sourcing_proposal.md` | Event Sourcing & CAS | Act Journal (`journal_*.jsonl`), CAS snapshot rollback |
| `rfc_003_memact_context_memory_proposal.md` | MemAct Context Memory | Token estimator, hierarchical memory, context compact |
| `rfc_004_agents_md_standard_proposal.md` | AGENTS.md Standard | Agent instructions standard in repositories |
| `rfc_005_agent_folder_proposal.md` | `.agent/` Folder Standard | Configuration management, skills (`agentskills.io`), commands |
| `rfc_006_openai_compat_response_standardization_proposal.md` | OpenAI-Compat Response Std | Standardized SSE streaming parser, tool call delta merge |
| `rfc_007_repl_chat_stream_ui_proposal.md` | REPL Chat Stream UI | TurnRenderer, live TTFT spinner, Markdown stream |
| `rfc_008_user_input_state_machine_proposal.md` | User Input State Machine | Multiline composition FSM, bracketed paste |
| `rfc_009_thinking_budget_reasoning_effort_proposal.md` | Reasoning Effort & Budget | Reasoning tokens parsing and model configuration |

---

## 3. Gap Analysis Evaluation Framework (Spec vs Implementation)

When verifying a feature:
1. **Inspect Spec**: Read the "Detailed Design" section in the corresponding RFC document.
2. **Inspect Code**: Locate the implementation files in `src/`.
3. **Identify Discrepancies**:
   - Are any APIs described in the RFC missing?
   - Do JSON/JSONL data formats match the schema specification?
   - Is memory management (Alloc/Free, Arena) within the appropriate lifecycle?
   - Concurrency & Thread safety: do multithreaded operations follow Zig 0.16 principles?
