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

## 2. Reference Docs in `docs/`

| File | Technical Focus |
|---|---|
| `architecture.md` | System architecture: agent loop, runtime, tools, backends, memory |
| `core/graph.md` | Procedural graph internals |

New proposals follow the naming convention in `AGENTS.md` (`rfc_NNN_<name>_proposal.md`).

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
