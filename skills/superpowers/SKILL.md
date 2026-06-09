---
name: superpowers
description: >
  Spec-first, TDD, subagent-driven software development workflow. Use when:
  (1) building any new feature or app — triggers brainstorm → plan → subagent execution loop,
  (2) debugging a bug or test failure — triggers systematic root-cause process,
  (3) user says "let's build", "help me plan", "I want to add X", or "this is broken",
  (4) completing a feature branch — triggers test verification + merge/PR options.
  NOT for: one-liner fixes (just edit), reading code, or non-code tasks.
  Requires exec tool and sessions_spawn.
---

# Superpowers — OpenClaw Edition

Adapted from [obra/superpowers](https://github.com/obra/superpowers). Mandatory workflow — not suggestions.

## The Pipeline

```
Idea → Brainstorm → Plan → Subagent-Driven Build (TDD) → Code Review → Finish Branch
```

Every coding task follows this pipeline. "Too simple to need a design" is always wrong.

---

## Phase 1: Brainstorming

**Trigger:** User wants to build something. Activate before touching any code.

**See:** [references/brainstorming.md](references/brainstorming.md)

**Summary:**
1. Explore project context (files, docs, recent commits)
2. Ask clarifying questions — **one at a time**, prefer multiple choice
3. Propose 2–3 approaches with trade-offs + recommendation
4. Present design in sections, get approval after each
5. Write design doc → `docs/plans/YYYY-MM-DD-<topic>-design.md` → commit
6. Hand off to **Phase 2: Writing Plans**

**HARD GATE:** Do NOT write any code until user approves design.

---

## Phase 2: Writing Plans

**Trigger:** Design approved. Activated by brainstorming phase.

**See:** [references/writing-plans.md](references/writing-plans.md)

**Summary:**
- Write a detailed task-by-task implementation plan
- Each task = 2–5 minutes: write test → watch fail → implement → watch pass → commit
- Save to `docs/plans/YYYY-MM-DD-<feature>.md`
- Announce: `"I'm using the writing-plans skill to create the implementation plan."`
- After saving, offer two execution modes:
  - **Subagent-driven (current session):** `sessions_spawn` per task + two-stage review
  - **Manual execution:** User runs tasks themselves

---

## Phase 3: Subagent-Driven Development

**Trigger:** Plan exists, user chooses subagent-driven execution.

**See:** [references/subagent-development.md](references/subagent-development.md)

> **`references/hdagentskilldev-vue-patterns.md`** — HDAgentSkillDev Vue frontend patterns: skillData multi-assignment, request.js usage, like API, localStorage conventions.

**Per-task loop (OpenClaw):**

1. `sessions_spawn` an implementer subagent
3. `sessions_spawn` a spec-reviewer subagent → must confirm code matches spec
4. `sessions_spawn` a code-quality reviewer subagent → must approve quality
5. Fix any issues, re-review if needed
6. Mark task done, move to next
7. Final: dispatch overall code reviewer → hand off to Phase 5

**TDD is mandatory in every task.** See [references/tdd.md](references/tdd.md).

---

## Phase 4: Systematic Debugging

**Trigger:** Bug, test failure, unexpected behaviour — any technical issue.

**See:** [references/systematic-debugging.md](references/systematic-debugging.md)

**HARD GATE:** No fixes without root cause investigation first.

**Four phases:**
1. Root Cause Investigation (read errors, reproduce, check recent changes, trace data flow)
2. Pattern Analysis (find working examples, compare, identify differences)
3. Hypothesis + Testing (one hypothesis at a time, test to prove/disprove)
4. Fix + Verification (fix at root, not symptom; verify fix doesn't break anything)

---

## Phase 5: Finishing a Branch

**Trigger:** All tasks complete, all tests pass.

**See:** [references/finishing-branch.md](references/finishing-branch.md)

**Summary:**
1. Verify all tests pass
2. Determine base branch
3. Present 4 options: merge locally / push + PR / keep / discard
4. Execute choice
5. Clean up

---

## OpenClaw Subagent Dispatch Pattern

When dispatching implementer or reviewer subagents, use `sessions_spawn`:

```
Goal: [one sentence]
Context: [why it matters, which plan file]
Files: [exact paths]
Constraints: [what NOT to do — no scope creep, TDD only]
Verify: [how to confirm success — tests pass, specific command]
Task text: [paste full task from plan]
```

Run `sessions_spawn` with the task as a detailed prompt. The sub-agent announces results automatically.

---

## Key Principles

- **One question at a time** during brainstorm
- **TDD always** — write failing test first, delete code written before tests
- **YAGNI** — remove unnecessary features from all designs
- **DRY** — no duplication
- **Systematic over ad-hoc** — follow the process especially under time pressure
- **Evidence over claims** — verify before declaring success
- **Frequent commits** — after each green test

## Pitfalls

### TDD vs. No Test Infrastructure
When the project has no test framework set up (common for Vue 3 + Vite frontends without Vitest/Jest configured), strict TDD is impractical. Adapt: verify via `npm run build` (no compilation errors) and manual functional check instead of unit tests. Do NOT skip verification entirely — always confirm the build succeeds.

### Subagent Rate Limiting
`delegate_task` subagents may hit API rate limits (429) during execution. If a subagent reports 429 errors but has already modified files, verify the changes locally (e.g., `mvn compile`, `npm run build`) before re-dispatching. Do not assume failure — the patches may have succeeded despite the 429 on the final status call.

### Project-Mandated Workflow Override
If the project has a mandatory development workflow (e.g., features.json status tracking, packaging, sprint reports), the superpowers pipeline must integrate those steps. After Phase 3 (subagent-driven build), before Phase 5 (finishing branch):
1. Update features.json status: design_end → dev → dev_end
2. Run project-specific packaging if required
3. Output sprint report in project-mandated format
Skipping these is a hard error — the superpowers pipeline does not replace project workflow, it augments it.

### DEBUG Logging Before Guessing (Phase 4)
When encountering HTTP 403/401/500 on new endpoints, **enable DEBUG logging BEFORE changing any Security/config code**. The most common mistake is assuming the status code's obvious cause (e.g., 403 = Security denial) when the actual cause is different (e.g., `TransactionRequiredException` surfaced as 403 by the Servlet container).

**Diagnostic-first approach:**
1. Restart with `--logging.level.org.springframework.security=DEBUG`
2. Make the failing request
3. Read the Security log: does it say "Secured" (passed) or "Denied" (actual security issue)?
4. Only THEN adjust SecurityConfig if actually a security issue

**Time impact:** 5 minutes of DEBUG logging vs 30+ minutes of blind config changes.

### Integration Verification Must Include Browser Testing
`curl` tests pass ≠ browser works. CORS preflight (OPTIONS) requests are only sent by browsers, not curl. After backend API verification with curl, always verify in the browser:
1. Open the page in browser
2. Perform the action (click button, submit form)
3. Check browser Network panel for CORS errors or unexpected 403s

**Common cause:** `FRONTEND_URL` / CORS allowed-origins missing the browser's actual origin (e.g., `http://192.168.1.77:3000` vs only `http://skills.topxtopx.com`).

### Vite Proxy Target Mismatch
When using Vite dev server with proxy, `curl localhost:8080` (direct backend) can return 200 while the browser gets 403. This happens when `vite.config.js` proxy target points to an external service instead of `localhost:8080`. The proxy silently forwards to the wrong server — no error, no warning.

**Diagnostic:** `curl localhost:3000/api/...` (through proxy) vs `curl localhost:8080/api/...` (direct). If results differ, proxy target is wrong.

**Fix:** Set proxy target to `http://localhost:8080` and restart Vite dev server.

### Git Commit Blocked by Background Processes (EulerOS)
On EulerOS, when background dev servers are running, `git commit` may be rejected as a "long-lived server/watch process". Use semicolons (`;`) instead of `&&` to chain git commands: `cd /root/project; git add -A; git commit -m "msg"`. See `references/hdagentskilldev-vue-patterns.md` → EulerOS Terminal Quirks.

### Subagent 429 Rate Limit — Do the Work Yourself
When a subagent hits 429 and produces no file changes, don't re-dispatch. Verify locally (`grep`), then do the work yourself with direct `patch` calls. See `references/subagent-development.md` for full guidance.

### execute_code write_file Unreliable for Large Files
The sandbox `write_file` may silently fail on large files (1000+ lines). Always verify with `grep` after writing. Fall back to incremental `patch` calls if verification fails. See `references/subagent-development.md` for full guidance.
