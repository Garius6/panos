<!--
Sync Impact Report
==================
Version change: (initial template) → 1.0.0
Modified principles: N/A (initial ratification; all placeholders replaced)
Added sections:
  - Core Principles (I. Think Before Coding, II. Simplicity First, III. Surgical Changes)
  - Workflow Rules (Confidence Reporting, Commit Messages)
  - Governance
Removed sections: none
Templates requiring updates:
  - ✅ .specify/templates/plan-template.md — Constitution Check section already generic; no edit needed
  - ✅ .specify/templates/spec-template.md — no principle-driven change required
  - ✅ .specify/templates/tasks-template.md — no principle-driven change required
  - ⚠  .specify/templates/commands/ — directory absent; nothing to sync
Follow-up TODOs: none
-->

# Panos Constitution

## Core Principles

### I. Think Before Coding

Do not assume. Do not hide confusion. Surface tradeoffs before writing code.

Rules:

- State assumptions explicitly. If uncertain, ASK before implementing.
- If multiple interpretations of the request exist, present them; do NOT silently pick one.
- If a simpler approach exists, name it and push back when warranted.
- If something is unclear, STOP. Name what is confusing. Ask.

Rationale: Guessing leads to rework and hidden defects. Explicit assumptions and early
questions are cheaper than reversing merged code.

### II. Simplicity First

Ship the minimum code that solves the stated problem. Nothing speculative.

Rules:

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that was not requested.
- No error handling for scenarios that cannot occur.
- If the change is 200 lines and 50 would do, rewrite it.
- Self-check: "Would a senior engineer call this overcomplicated?" If yes, simplify.

Rationale: Every added line is future maintenance surface. Speculative generality is
usually wrong and always costly to remove later.

### III. Surgical Changes

Touch only what the task requires. Clean up only what your own change breaks.

Rules for editing existing code:

- Do NOT "improve" adjacent code, comments, or formatting.
- Do NOT refactor things that are not broken.
- Match existing style even if you would write it differently.
- If you notice unrelated dead code, mention it; do NOT delete it.

Rules for orphans created by the change:

- Remove imports, variables, and functions that YOUR change made unused.
- Do NOT remove pre-existing dead code unless explicitly asked.

The test: every changed line MUST trace directly to the user's request.

Rationale: Drive-by edits inflate diffs, hide intent, and cause unrelated regressions.

## Workflow Rules

### Confidence Reporting

After every response to a user request, the agent MUST state a confidence level from
0 to 100 reflecting how sure it is about the answer or change. If confidence is below
75, the agent MUST stop and ask clarifying questions instead of proceeding.

Rationale: Explicit confidence prevents overconfident guesses from landing as if
verified, and forces clarification when the request is ambiguous.

### Commit Messages

All commit messages MUST be written in Russian. Commit messages MUST NOT mention the
AI assistant, its model, or any co-author trailer referencing it. Focus on WHAT
changed and WHY.

Rationale: Project language is Russian. Attribution to the assistant adds noise and
is not part of the project history the team wants to preserve.

## Governance

This constitution supersedes ad-hoc conventions in this repository. Working
agreements in `AGENTS.md` remain authoritative for project-specific technical
guidance; where they conflict with this document, the constitution wins for process
rules and `AGENTS.md` wins for language and pipeline specifics.

Amendment procedure:

- Proposed changes MUST be recorded as a commit that updates this file and bumps
  the version below.
- Version bumps follow semantic versioning:
  - MAJOR: a principle is removed or redefined in a backward-incompatible way.
  - MINOR: a new principle or workflow rule is added, or existing guidance is
    materially expanded.
  - PATCH: wording clarifications, typo fixes, non-semantic refinements.
- `LAST_AMENDED` MUST be updated to the amendment date. `RATIFIED` MUST NOT change.

Compliance review:

- Every change MUST be checked against the three core principles before merge.
- Any violation MUST be justified in the commit body or plan under
  "Complexity Tracking" and explicitly acknowledged.

**Version**: 1.0.0 | **Ratified**: 2026-07-07 | **Last Amended**: 2026-07-07
