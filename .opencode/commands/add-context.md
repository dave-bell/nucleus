---
allowed-tools:
- Read
- Write
- Edit
- Grep
- Glob
- Agent
argument-hint: '[dev|config] [update|global]'
arguments:
- mode
- action
description: Interactive wizard that creates or updates project-intelligence (software
  dev) or customer-intelligence (solution config) context for this project, following
  the MVI and Project Intelligence standards.
---

# Add Context

Create or update this project's context so agents (and consultants, for labbit-configuration) automatically follow the right standards. Mode: $mode. Action: $action.

## Stage 0: Resolve Context Root

Follow the context-root-discovery protocol (installed alongside the `context-manager` skill at `references/context-root-discovery.md`; try `.claude/skills/context-manager/`, `.agents/skills/context-manager/`, or `.kiro/skills/context-manager/`).

- If `$action` is `global` → target root is the global candidate (e.g. `~/.claude/context/` or `~/.config/opencode/context/`).
- Otherwise → target root is local (`{context_root}`), created if it doesn't exist.

## Stage 1: Determine Mode

If `$mode` is not `dev` or `config`, ask:

> Is this project intelligence for **building the product** (mode: dev), or **configuring the solution for a customer** (mode: config)? Both can coexist in the same project.

- `dev` → target folder: `{context_root}/project-intelligence/`, templates from the `context-manager` skill's `assets/project-intelligence/`. Standard: `references/domains/software-development/project-intelligence.md`.
- `config` → target folder: `{context_root}/customer-intelligence/`, templates from `assets/customer-intelligence/`. Standard: `references/domains/labbit-configuration/customer-intelligence.md`. Also point the user at `references/domains/labbit-configuration/standards/` (JSONC + BPMN patterns) for ongoing work.

## Stage 2: Detect Existing Context

**Structural integrity check (run first, before the domain-marker check below):**

1. Does `{context_root}/navigation.md` exist?
2. If not, and at least one domain folder (`project-intelligence/` or `customer-intelligence/`) already exists → this is a pre-fix scaffold missing its root nav. Generate `{context_root}/navigation.md` from `assets/navigation.md` right now, listing whatever domain folder(s) are actually present on disk. Report this as a repair (e.g. "Repaired: created missing root navigation.md"). Then continue into the domain-marker check below — do not skip it.
3. If not, and no domain folder exists → fresh scaffold; the root nav will be created in Stage 4. Continue to the domain-marker check below.
4. If it already exists → nothing to repair; continue to the domain-marker check below.

**Domain-marker check:** Check whether the target folder already has content (e.g. `technical-domain.md` for dev, `customer-profile.md` for config).

- **Exists and `$action` is not `update`** → show a summary of current values (parse the tables from existing files) and ask: Review & update / Add new patterns / Replace all / Cancel.
- **Exists and `$action` is `update`** → go straight to review mode: show each section, ask Keep/Update/Remove.
- **Doesn't exist** → proceed to Stage 3 fresh.

## Stage 3: Gather Information

### Mode: dev (6 questions, ~5 min)

1. Tech stack? (framework, language, database, styling)
2. API endpoint example? (paste real code, or 'skip')
3. Component example? (paste real code, or 'skip')
4. Naming conventions? (files, components, functions, database)
5. Code standards? (one per line)
6. Security requirements? (one per line)

### Mode: config (5 questions, ~5 min)

1. Customer name, industry, and scale?
2. What are their primary goals for this implementation?
3. Which modules are enabled, and are any config values overridden from defaults? (paste the JSONC snippet if available)
4. Which BPMN processes are active, and are any customized from the standard template?
5. Any constraints (compliance, legacy integration, on-prem-only, etc.)?

Skip a question with 'skip' if not yet known — templates leave placeholders for later.

## Stage 4: Generate

Delegate to the `context-organizer` agent (`Agent(context-organizer)`) with the gathered answers, target folder, and mode. It will:
1. Call `context-indexer` first to confirm nothing already covers this.
2. Load the MVI/frontmatter/structure standards.
3. **Instantiate the complete template set for the chosen mode.** Copy every file from the mode's `assets/` folder into the target domain folder, filling each with gathered answers (leave the template's placeholders where an answer was skipped). Create no fewer and no other files in the domain folder itself.

   - **dev** → `{context_root}/project-intelligence/`, all 6 files from `assets/project-intelligence/`:
     `navigation.md`, `business-domain.md`, `technical-domain.md`, `business-tech-bridge.md`, `decisions-log.md`, `living-notes.md`
   - **config** → `{context_root}/customer-intelligence/`, all 6 files from `assets/customer-intelligence/`:
     `navigation.md`, `customer-profile.md`, `configuration-domain.md`, `process-map.md`, `customization-log.md`, `living-notes.md`

   Do NOT invent alternate folders (e.g. `patterns/`) or alternate frontmatter styles. The template set defines the exact files and format for both modes. Every file must start with the exact HTML-comment frontmatter: `<!-- Context: {category}/{function} | Priority: {level} | Version: X.Y | Updated: YYYY-MM-DD -->` — never YAML frontmatter (`---`).
4. **Create or update the root navigation.** `{context_root}/navigation.md` is a separate file, always required, one level above the domain folder:
   - If it does not exist → copy `assets/navigation.md` to `{context_root}/navigation.md`, fill in `{date}`, and keep only the Quick Routes / Related Files rows for the domain(s) that exist after this run (usually just the one just created).
   - If it already exists (a second domain being added to this root, or it was just repaired in Stage 2) → update it in place to add a row for the domain just created. Never remove or rewrite an existing domain's row, and never remove content a user has added to this file.
5. Validate against the MVI checklist (frontmatter present, <200 lines, codebase references included, version set) for every file written in steps 3 and 4, including the root nav.

**Show the user a preview of each file before writing** — do not write silently.

**Before reporting done on a fresh scaffold**, list the target folder and confirm every template file for the chosen mode is present and each starts with the exact HTML-comment frontmatter. Also confirm `{context_root}/navigation.md` exists and its Quick Routes table lists every domain folder actually present on disk — not just the one from this run. Fix any missing or divergent file before finishing — this applies equally to `dev` and `config`.

## Stage 5: Confirm & Next Steps

Report what was created/updated, where it lives, and suggest:
- Test it by asking an agent to do a small task in this domain and checking whether it follows the new patterns.
- Run this prompt again with `action=update` whenever the tech stack, customer config, or processes change.
- If mode was `dev` and the project also does customer implementations, consider running this prompt again with `mode=config`.