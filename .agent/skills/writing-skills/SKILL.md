---
name: writing-skills
description: Use when creating a new mini skill, editing an existing one, or verifying a skill triggers and works before deploying to ~/.mini/skills or .agent/skills. Covers loader frontmatter rules, description triggers, body structure, and pre-deployment testing.
---

# Writing Skills Skill

A skill is a trigger description + a terse, verified procedure. The frontmatter `name` and
`description` are the only text the agent sees up front; the body loads on demand. So: write
the description as trigger conditions, keep the body a terse imperative procedure, and prove
the skill actually fires before shipping.

---

## 1. When to Activate This Skill?

- When authoring a new skill under `~/.mini/skills/<name>/` or `<project>/.agent/skills/<name>/`.
- When editing an existing skill's frontmatter, description, or body.
- Before shipping any skill: it must be verified to trigger and be followed (Section 5).
- When a skill exists but the agent never activates it — the trigger description is wrong.

---

## 2. Loader Constraints (mini `src/core/skills.zig` — match these EXACTLY)

Only `name` + `description` are prompt-resident (injected into the system prompt). The body
is read on demand. Rules that matter:

| Rule | Value | Violation effect |
|------|-------|------------------|
| Layout | `skills/<name>/SKILL.md`, non-recursive | Not discovered |
| `name` frontmatter | MUST equal directory name | Warning + forced fallback to directory name |
| `description` | Single line, hard cap 512 bytes | Truncated silently |
| Body size | 0 < size <= 64 KB | File rejected, skill not loaded |
| Total skills | Max 32; project root overrides same-named global | Extras dropped |

- Global root: `$MINI_HOME/skills` (default `~/.mini/skills/`).
- Project root: `$MINI_AGENT_FOLDER/skills` (typically `<project>/.agent/skills/`) — scanned
  after global; on name clash, project wins.
- Frontmatter is plain YAML between `---` lines. `description` supports `>` multiline
  folding, but single-line is simpler and safer.
- `name`: letters, digits, hyphens only.

Verify mechanically after writing:

```bash
# name must equal the directory name; description must be one line <= 512 bytes
head -3 ~/.mini/skills/<name>/SKILL.md
awk 'NR==2{print length($0)}' ~/.mini/skills/<name>/SKILL.md   # name line
wc -c ~/.mini/skills/<name>/SKILL.md                            # must be <= 65536
```

---

## 3. Write the Description as Trigger Conditions

The description answers one question: "Should I read this skill now?"

1. Start with `Use when ...` and list concrete trigger conditions / symptoms / situations.
2. Describe the *problem context*, not the workflow. A workflow summary becomes a shortcut
   the agent follows instead of reading the body.
3. Include keywords an agent would match on: error names, symptoms, tool names, file types.
4. Third person, single line, < 512 bytes.

```yaml
# BAD: summarizes workflow (agents skip the body)
description: Use when fixing bugs - investigate root cause, write reproduction test, apply fix
# GOOD: triggers only
description: Use when encountering any bug, test failure, or unexpected behavior, before proposing fixes
```

**Naming:** verb-first, active voice — `writing-plans`, not `plan-writing`.

---

## 4. Write the Body (terse procedure)

A skill is a reference for a proven technique, pattern, or tool — NOT a narrative of one
past session. Pick the type first:

- **Technique** — concrete steps to follow (e.g. `systematic-debugging`, `test-driven-development`).
- **Pattern** — a way of thinking (e.g. match-the-form-to-the-failure).
- **Reference** — API/syntax/command documentation.

**Structure (mirror native mini skills):**

```markdown
# <Name> Skill

<1-2 sentence overview + core principle>

## 1. When to Activate This Skill?
- Trigger bullets

## 2. <numbered process steps>
Concrete, runnable commands (mini.sh / zig / git / node)

## 3. Decision rules / common mistakes
```

**Style hard rules:**
- English, imperative, terse. No marketing prose, no emoji, no diagrams.
- One excellent example beats five mediocre ones. No multi-language dilution.
- Commands must run in mini context: `mini.sh`, `zig build test`, `git ...`, `node ...`.
- Cross-reference other skills by NAME only, never by file path.
- Target 4-8 KB per SKILL.md. The loader reads only `SKILL.md`, so anything not in it is
  unreachable unless the body gives a concrete command that fetches it.
- Match guidance form to failure type:
  - Agent skips a rule under pressure → prohibition + explicit "No exceptions" list.
  - Output has the wrong shape → positive recipe stating what the output IS.
  - Missing element → required slot in the template.
  - Conditional behavior → rule keyed to an observable predicate, no exemption clauses.

---

## 5. Test Before Shipping

Test a skill before shipping: run a single-shot task that should trigger it, then check the
journal via `session_diagnostics`.

### RED — baseline without the skill
Move the skill directory aside (or test a fresh skill), then run the representative task:

```bash
mkdir -p /tmp/skill-test && mv ~/.mini/skills/<name> /tmp/skill-test/
mini -e "<task that should trigger the skill>" 2>&1 | tail -50
```

Document: what choices were made, what rationalizations appeared, where it went wrong.
If you never watched a run fail without the skill, you do not know the skill teaches the
right thing.

### GREEN — write the minimal skill
Address ONLY the observed failures. Recreate `<root>/<name>/SKILL.md` with correct
frontmatter (`name` == directory name). Re-run the same single-shot task. Verify:

1. The skill appears in the available-skills list (name + description injected).
2. The agent reads SKILL.md and follows it.

### Verify via session journal
Confirm the on-demand load happened:

```bash
ls -t ~/.mini/sessions/journal_*.jsonl | head -1
```

Then use the `session_diagnostics` tool (`operation: detail` on the newest PID) or grep the
journal for the skill path — a `mini.read`/`file_read` act of `SKILL.md` proves the body
loaded; the following acts should match the skill's procedure.

### REFACTOR — close loopholes
New rationalization found? Add an explicit counter (a "No exceptions" list, verbatim) or a
short excuse → reality table built from your test runs. Re-run until the agent complies
under pressure. Skip the pressure cycle for pure reference skills — test that they trigger
and load, not that the agent resists rationalization.

### Pre-deployment checklist
- [ ] `name` equals directory name exactly
- [ ] `description` single line, under 512 bytes, starts with "Use when", no workflow summary
- [ ] Body 4-8 KB, every command runnable in mini context
- [ ] No helper files outside SKILL.md (the loader only reads SKILL.md)
- [ ] Single-shot trigger test passed; journal shows SKILL.md read and procedure followed

**No skill ships without the RED baseline and the GREEN verification. No exceptions.**
