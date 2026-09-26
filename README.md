[Русская версия](README.ru.md)

# Dual Review File Based

Two AI agents review plans and code iteratively, coordinating through plain files with no server or orchestrator needed.

## Why

AI-generated plans and code benefit from a second opinion before implementation. But setting up a review pipeline between agents usually requires MCP servers, orchestrators, or custom infrastructure. This skill replaces all of that with a simple file-based protocol: agents read and write markdown files in a shared directory, each round producing a structured review with verdicts and evidence-backed issues.

Roles are not tied to applications: Codex → Codex, Codex → ZCode, Claude Code → Codex, and other pairings all work. For cross-model review, select different models inside those applications. A separate chat using the same model is also supported and still provides independent context. Both agents work in the same project directory; no MCP server or CLI bridge is required.

## How it works

The initiator gives an independent agent the task and a list of files. The reviewer examines the actual project files and writes structured findings. The initiator verifies each finding, applies justified fixes, and opens another round. The updated files are reviewed again until approval or the configured round limit.

Session state lives in `.dual-review/` inside the project, so the review can continue after a restart or interruption. By default, the reviewer receives the task manually once and then follows subsequent rounds in the same session.

## Installation

Choose the bundle for the application where the initiator manages the session. Do not mix files from the two bundles, and finish active sessions before updating an installed copy.

### Codex

Copy the contents of `codex/` to `.agents/skills/claude-dual-review-file-based/` in your project:

```powershell
New-Item -ItemType Directory -Force .agents/skills/claude-dual-review-file-based
Copy-Item codex/* .agents/skills/claude-dual-review-file-based/ -Recurse -Force
```

Ask Codex to use `$claude-dual-review-file-based` with your task or plan. Pass the generated task to the selected reviewer, such as another Codex chat or ZCode.

### Claude Code

Copy the contents of `claude-code/` to `.claude/skills/codex-dual-review-file-based/` in your project:

```bash
mkdir -p .claude/skills/codex-dual-review-file-based
cp claude-code/* .claude/skills/codex-dual-review-file-based/
```

Then invoke the skill:

```text
/codex-dual-review-file-based <task description> [path/to/plan.md] [max_rounds=5]
```
