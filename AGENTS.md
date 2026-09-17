# AGENTS.md — mob_scene3d

Conventions for agents (and humans) working in this repo. These transcribe
the hygiene the Mob repos (`mob`, `mob_dev`, `mob_new`) converged on —
much of it paid for in incidents; the *why* is noted where it was earned.

## Toolchain

Pinned in `.tool-versions` (mise and asdf both read it; **the zig pin
requires mise** — asdf cannot fetch historical Zig dev nightlies):

- erlang 29.0 (matches device runtime tarballs)
- elixir 1.20.0-otp-29
- java temurin-17.0.18 (Gradle)
- zig 0.17.0-dev.269+ebff43698 — **the exact dev version is deliberate**;
  native build files track it. Never "upgrade" it casually; mob_dev's
  doctor/deploy preflight hard-fails on any other version.

Run everything through `mise exec -- mix ...`. Filament binaries (AAR /
xcframework) are pinned by exact version in the build files — record any
bump in the changelog.

## Gates — run before any push, in this order

```
mix format --check-formatted
mix credo --strict
mix compile --warnings-as-errors
mix test                       # full suite; no skipped-by-default surprises
mix erlfmt --check src/        # if .erl sources exist
clang-format --dry-run -Werror <c/objc/c++ sources>
swiftlint <ios dirs>           # zero new warnings; pre-existing ones documented here
ktlint                         # kotlin sources, repo config
```

A two-tier pre-push hook (copy the pattern from mob's `.githooks/`,
activated via `git config core.hooksPath .githooks`): cheap checks always;
full test preflight only when `mix.exs` changed in the push (that's a
release). CI runs the full suite regardless — the hook exists to catch the
80% cheaply, not to punish pushing.

## Release flow

Same trigger model as the other Mob repos (see mob's `RELEASE.md` — it is
the canonical doc):

- `mix.exs` is the single source of truth for the version. Bump it, commit,
  push to master → the release workflow tags, creates the GitHub Release,
  and publishes to Hex. Each step idempotent.
- **Every release ships a changelog.** Keep a Changelog format in
  `CHANGELOG.md`; the entry goes in the bump commit; the workflow lifts it
  into the GitHub Release body. Reference PR numbers.
- Default bump is patch. **Ask before bumping**; never auto-bump inside a
  feature commit.
- Bump-commit subject style: `Bump to X.Y.Z — short summary`.

### The packaging lesson (paid for twice, 2026-08-30)

**Compile-time resources must ship inside the Hex package.** Hex includes
`priv/` but omits repo-root dotfiles. Two releases (mob_new 0.4.27,
mob_dev 0.6.29) shipped packages that could not compile because a
compile-time `File.read!` targeted root `.tool-versions`. Rules:

1. Anything read at compile time lives in `priv/` or inline in source,
   with a lockstep test against the repo-root authority if one exists.
2. **Every release-able repo carries a packed-artifact regression test**:
   build/unpack the real Hex package (`mix hex.build --unpack`), compile it
   cleanly in isolation, and exercise the code path that used the resource.
3. Repo tests passing is not release verification. After publishing,
   fetch the artifact from Hex (`mix hex.package fetch ... --unpack`) and
   compile it before declaring the release good.

## Verify effects, not exit codes

`mix mob.deploy` historically exited 0 on silently skipped builds (missing
toolchain, unmatched device id) — this burned five separate agent-sessions.
After any deploy: prove the app is installed (`adb shell pidof` /
`pm list`), the node connects, and `Mob.Test.screen/1` answers, before
believing anything else. The same skepticism applies to any tool here.

## Device work

- **One driver per device at a time.** Mob's tap-effect detection is
  process-wide; concurrent drivers produce false signals.
- Lease hardware; unique client id per session; humans outrank agents;
  release leases in an exit path. (The shared device pool scripts are the
  reference implementation.)
- **Never `mix mob.push` with a fleet attached** — it hot-pushes modules to
  *every* live node and ignores `--device`. Use per-device
  `mix mob.deploy --native --device <id>`. (`mob.watch` has the same
  fan-out property.)
- Pool-sim traps: per-device `MOB_SIM_RUNTIME_DIR` dirs must exist or apps
  boot-crash ("cannot get bootfile"); concurrent BEAMs collide on the
  default dist port — **fatal on iOS**, tolerated on Android — use
  `SIMCTL_CHILD_MOB_NODE_SUFFIX` and a non-default port per session.
- Physical hardware for final acceptance. Emulator pools hide real bugs
  (an API-33-only call was invisible on an all-Android-13 pool; wide-color
  capture differs on real iOS hardware). Keep pool API-level diversity.
- Evidence discipline: `element_frames`/`pick`/`scene` readback for
  geometry decisions, pixel sampling for exact color, screen recordings
  for animation (stills prove nothing about motion), screenshots mainly
  for human-facing records.

## Cross-platform parity

One scene semantics; platform shims are mechanics only. Where platform
behavior genuinely diverges, the divergence is **documented in the guides
at the moment it ships** (precedent: mob #98 — iOS divides weighted space
evenly, Android honors ratios; the docs say so in the same PR). An
undocumented divergence is a bug even when both behaviors are defensible.

## Agent legibility is a feature gate

No rendering feature merges without its introspection counterpart
(pick / scene readback / honest errors). Success means *the effect
happened*, not *the call returned* — APIs return `{:error, :no_effect}`
-style honest failures, never phantom `:ok`s (precedent: mob #80).

## Code review

- Adversarial by default: reviewers try to refute, with findings tagged
  (Blocking/Suggestion/Question/Nit) and `file:line` anchors; claims about
  runtime behavior need reproduction or a traced interleaving, not vibes.
- Fresh-context review beats author-context review; findings become beads,
  any agent picks them up.
- Source-contract tests assert token-level strings plus ordering, never
  exact whitespace blocks (precedent: mob #104 review).
- PRs squash-merge; PR body lists verification actually performed.

## Worktrees and shared state

- Never work in another session's checkout. Fresh `git worktree add` per
  task; prune your own when merged; never prune another lane's.
- Durable conclusions go in files (beads, PR comments, decision records) —
  agent context windows are ephemeral; the artifact is the handoff.

## Housekeeping

- `mob.exs` and `.envrc` are gitignored, never committed.
- Decision records live in `decisions/` (dated markdown), mob-style.
- Beads (`bd`) is the issue tracker in this repo; keep the dependency DAG
  honest — "blocked by" is load-bearing with parallel agents.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->

## Beads on a fresh clone

The tracker's Dolt database (`.beads/embeddeddolt/`) is gitignored by bd's
own design, so a clone arrives with no issues in it. What travels through git
is `.beads/issues.jsonl`, kept current by `export.auto` in
`.beads/config.yaml`.

To rebuild the tracker after cloning:

```bash
bd init --reinit-local --prefix mob_scene3d
bd import .beads/issues.jsonl
bd list
```

`--reinit-local` is required: plain `bd init` aborts because `.beads/` already
exists in the clone. Do not commit `.beads/embeddeddolt/` or
`.beads-credential-key` — the first is a 4 MB binary working set that will
conflict on every merge, the second is a federation auth key.
