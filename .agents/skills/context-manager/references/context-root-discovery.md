<!-- Context: core/context-root-discovery | Priority: critical | Version: 1.0 | Updated: 2026-07-21 -->

# Context Root Discovery Protocol

**Purpose**: Resolve `{context_root}` and `{global_context_root}` dynamically so the same agents, skills, and commands work identically under Claude Code, opencode, Codex, and any other harness — without hardcoding a tool-specific directory name.

Every reference file in this skill uses the placeholders `{context_root}` and `{global_context_root}`. Resolve them ONCE per session using this protocol, then substitute the resolved path everywhere.

---

## Resolution Order (run once, at session start)

1. **Explicit config** — Check for a config file in the project root, in this order:
   - `.oac.json` (or `.oac.yml`) with a `contextRoot` field
   - `apm.yml` with a `context.root` field (if this package's own manifest is present)
   If found and the path exists → **use it**. Done.

2. **Tool-native local directories** — Glob for `navigation.md` inside each candidate, in this priority order:
   1. `.claude/context/navigation.md`
   2. `.opencode/context/navigation.md`
   3. `.codex/context/navigation.md`
   4. `context/navigation.md` (plain, tool-agnostic)
   If any is found → `{context_root}` = that directory. Done.

3. **No local context found** — Check global fallback candidates, in order:
   1. `~/.claude/context/navigation.md`
   2. `~/.config/opencode/context/navigation.md`
   3. `~/.codex/context/navigation.md`
   If any is found → `{global_context_root}` = that directory. Use it for **core/engine reads only** (never for project-intelligence or labbit-configuration writes — those are always local).

4. **Nothing found** — No context exists yet. Report this plainly and offer to create `{context_root}` via the `add-context` prompt (defaults to `context/` at the project root, or the tool-native directory if one is detected from other config, e.g. presence of `.claude/` implies `.claude/context/`).

**Limits**: Maximum 2 glob checks per candidate list. Resolve once per session — do not re-resolve per file. Local always wins over global; global fallback is for `core/` engine reference content only, never for `project-intelligence/` or `customer-intelligence/` (those are always project-local and git-committed).

---

## Writing a New Context Root

When no context exists (step 4) and the user approves creation:

1. Detect the active harness from environment clues (presence of `.claude/`, `.opencode/`, `.codex/`, or ask the user).
2. Create `{context_root}` = `<detected-tool-dir>/context/` if a tool dir exists, else plain `context/` at the project root.
3. Scaffold `navigation.md` and either `project-intelligence/` (software-development domain) or `customer-intelligence/` (labbit-configuration domain) — see the `add-context` prompt. These are sibling folders directly under `{context_root}`, not nested under a domain-name folder — the domain name only exists inside this skill's own `references/domains/` tree, never in the consumer's project.
4. Record the choice in `.oac.json` (`{"contextRoot": "<path>"}`) so future sessions skip re-detection.

---

## Substitution Reference

Every literal path like `.opencode/context/...` or `~/.config/opencode/context/...` appearing elsewhere in this skill's reference files should be read as `{context_root}/...` or `{global_context_root}/...` respectively — those literal paths are carried over from an OpenCode-specific predecessor system and are being normalized. Treat any remaining literal occurrence as a documentation bug, not an instruction to hardcode that path.
