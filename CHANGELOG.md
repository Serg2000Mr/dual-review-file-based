# Changelog

All notable changes to this project will be documented in this file.

This project uses a lightweight Keep a Changelog style. Dates are in UTC.

## [Unreleased]

## [2026-09-26]

### Added
- Added the current Codex-initiated manual review bundle in `codex/`, including the session driver, atomic protocol publisher, reviewer prompt, and Windows checks.
- Added task-bound recovery, recorded decisions with file-change evidence, explicit cancellation/technical-stop outcomes, and guarded completion.
- Documented both installation directions and their distinct platform requirements in English and Russian.

### Changed
- Renamed the project to Dual Review File Based; agent pairings are examples.
- Clarified agent-independent roles, including Codex-to-Codex and Codex-to-ZCode; historical protocol identifiers remain unchanged.
- Made the exported Codex bundle independent of project-specific paths, Serena requirements, and local hook configuration. Preserved the persistent Windows handoff notification with the actual project and task titles.
- Resuming an already-written review in the Claude-initiated bundle now continues waiting for the next round instead of treating that round as session completion.

## Earlier unreleased changes

### Added
- Added a machine-readable JSON contract to round-start and review files.
- Added `wait-for-review.ps1` for native Windows sessions.

### Changed
- Made session, reviewer-prompt, and wait-script paths absolute and safe for Git worktrees.
- Made skill assets self-locating so project-local and global installations use the files that belong to the loaded skill.
- Updated both wait helpers to validate arguments, use adaptive polling, return compact JSON, and enforce a timeout.
- Updated English and Russian documentation around installation, recovery, completion, and supported environments.

### Removed
- Removed model-version recommendations that become stale independently of the protocol.
- Removed Codex channel-specific `commentary`/`final` instructions; the protocol now defines visible summaries without prescribing runtime channels.

## [2026-04-23]
### Added
- Added `CHANGELOG.md` to track notable repository changes.

### Changed
- Clarified Codex runtime behavior in `claude-code/reviewer-prompt.txt`: round and session summaries must go through `commentary`, `final` is reserved for true completion, and Step 8 requires a real poll-and-sleep wait loop.
- Reworded the `description` in `claude-code/SKILL.md`: removed angle brackets (forbidden in frontmatter per Anthropic skills guidelines) and added clearer trigger phrases for async plan/production-change review.
- Added a Trivially-passing test check to `claude-code/reviewer-prompt.txt` for the `production-change` review scope.
- Made `claude-code/wait-for-review.sh` resolve `PROJECT_ROOT` via `BASH_SOURCE`, so the script works regardless of the caller's working directory.

## [2026-04-16]
### Changed
- Updated the initiator flow to use `Monitor` instead of Bash `run_in_background` for waiting on review completion.

## [2026-04-10]
### Changed
- Synced the English and Russian README files with protocol and documentation updates.
- Removed outdated license references from the documentation.

## [2026-04-09]
### Added
- Initial public release of the file-based dual-review skill for Claude Code + Codex.
- Added the core skill files in `claude-code/` and the supporting documentation in `docs/`.
