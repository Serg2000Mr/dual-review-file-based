[Русская версия](README.ru.md)

# Dual Review File Based

An agent reviewing its own plan or code may carry forward the assumptions that caused a mistake. Cross-review by another model provides an independent perspective: the reviewer examines the requirements and actual files afresh, looking for defects, omissions, and unnecessary complexity. Different models may notice different problems, helping uncover what the author missed. This does not guarantee correctness or replace tests.

The skill organizes the complete correction loop: one agent does the work, another reviews it, the author verifies findings and applies justified fixes, and the reviewer checks the updated files. Findings lead to checked changes rather than ending as a list of suggestions.

For cross-model review, choose different underlying models, not just different applications: the names Codex, ZCode, and Claude Code do not by themselves identify the model in use. A separate chat with the same model is also supported; it provides separate context, but not model diversity.

These skills let an initiator and an independent reviewer check a plan or code change through a file protocol. Agent brands do not define the roles: Codex → Codex, Codex → ZCode, Claude Code → Codex, and other pairings use the same role separation. Both need access to the same project directory. Manual prompt delivery is the default; no MCP server or CLI bridge is required.

| Installation example | Skill directory | Environment |
|---|---|---|
| Claude Code | `claude-code/` | PowerShell or Bash wait helper |
| Codex | `codex/` | Windows PowerShell 5.1 |

Directory names, skill names, review headings, and `claude`/`codex` filename components are historical compatibility identifiers, not requirements on the actual agents. Choose a bundle by its runtime and host integration. The bundles have different role-specific filenames and helpers. Install them separately; do not mix their files or migrate an active session between them.

## Quick start

### Script-managed sessions (installation example for Codex)

Copy the complete `codex/` directory, including `tests/`, into your project's Codex skill directory:

```powershell
New-Item -ItemType Directory -Force .agents/skills/claude-dual-review-file-based
Copy-Item codex/* .agents/skills/claude-dual-review-file-based/ -Recurse -Force
```

Ask Codex to use `$claude-dual-review-file-based` with your task or plan. Codex saves one starter prompt for the independent reviewer. Pass it to the selected reviewer (including another Codex chat or ZCode) once; subsequent rounds continue in the same session.

The Codex bundle includes a session driver, atomic review publication, validation, and runnable checks. It preserves the task binding, review scope, round limit, and delivery mode after interruption. Accepted findings require changed file snapshots and recorded verification before the next round; a snapshot change alone does not establish correctness. The initiator makes fixes; the reviewer only writes review artifacts.

To inspect an existing session:

```powershell
& '<skill>/review-session.ps1' -Action status -ProjectRoot '<project>' -ThreadId '<actual-task-id>'
```

`CODEX_THREAD_ID` is used automatically when available. The driver returns the next action. It refuses premature completion and records `approved`, `failed`, `limit`, or explicit `cancelled`/`stopped` outcomes in `final.md`. Instructions and review artifacts are English; chat summaries are Russian.

Host hooks are optional and are not installed automatically. The bundle has no dependency on Serena or project-specific skills. Follow the reviewed project's own rules.

On Windows, manual handoff also opens a persistent notification with the current project and task titles. Dismissing it does not claim the review; the reviewer must still publish the claim file.

### Original instruction-driven bundle (installation example for Claude Code)

Copy the complete `claude-code/` directory into the project skill directory:

```bash
mkdir -p .claude/skills/codex-dual-review-file-based
cp claude-code/* .claude/skills/codex-dual-review-file-based/
```

Then run in Claude Code:

```text
/codex-dual-review-file-based <task description> [path/to/plan.md] [max_rounds=5]
```

The initiator creates the first round and prints one ready-to-use instruction for the selected reviewer. The reviewer keeps watching the same session for later rounds; the user does not need to pass the prompt again.

## How it works

Each session lives in an absolute `<project_root>/.dual-review/<session_id>/` directory. If the initiator runs inside a Git worktree, the session remains inside that worktree.

```text
R1-01-round-start.md     <- Initiator writes the review contract
R1-02-codex-claimed.flg  <- Reviewer claims the round
R1-03-codex-review.md    <- Reviewer writes the review
R1-04-claude-claimed.flg <- Initiator processes the result
final.md                 <- Initiator records the session outcome
```

Round-start and review files contain a machine-readable JSON block plus a human-readable explanation. The initiator verifies every finding as a hypothesis, applies accepted changes before opening the next round, and records rejected findings with evidence.

The session ends with:

- `approved` after `APPROVED`;
- `failed` after the rare `REJECTED` verdict;
- `limit` when `max_rounds` is reached.

`APPROVED` alone does not finish a session: `final.md` is the completion marker.

## Protocol guarantees

- Session files are append-only: protocol files are never overwritten or deleted.
- Absolute `SESSION_DIR`, reviewer-prompt, and helper-script paths prevent main-checkout/worktree mix-ups.
- Claim flags allow interrupted agents to resume from files instead of reconstructing state from chat.
- Review scope is fixed in round 1 and cannot drift between rounds.
- JSON fields provide a stable contract for verdicts, severity, confidence, evidence, and finding IDs.
- Missing or malformed review JSON is reported as a recoverable protocol error instead of being guessed from prose.

## Review scopes

| Scope | When to use |
|---|---|
| `plan-only` | Review a plan before code changes |
| `production-change` | Review actual code and tests |
| `architecture-check` | Evaluate an architectural decision |
| `lookup-test` | Verify a hypothesis or API behavior |

## Environment

Both bundles resolve helpers beside the loaded `SKILL.md`, supporting project-local or global installation. Always supply the actual reviewed project/worktree root.

For the `claude-code/` bundle, use the helper that matches the environment:

- `wait-for-review.ps1` on Windows with PowerShell;
- `wait-for-review.sh` on macOS, Linux, or Git Bash.

Both helpers accept an absolute session directory, validate the round, use adaptive polling, return a compact JSON result, and stop after a configurable timeout.

The `codex/` bundle requires Windows PowerShell 5.1 and includes its own `wait-for-review.ps1`. Its reviewer waits for the next round or final file with `-TimeoutSec 0`; the initiator's default wait is one hour. A timeout is not approval. Finish active sessions with the bundle version that created them before replacing installed files.

## Checks

From the repository root on Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File codex/tests/run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File codex/tests/session-tests.ps1
```

Checks exercise invalid reviews, append-only publication, interrupted writes, waiting, correction/approval, task isolation, recovery, cancellation, and round limits. They use temporary fixtures and start no external reviewer. They do not establish live host-hook activation or end-to-end model behavior.

## Design decisions

- **Separate context, independent inspection.** A second agent is useful because it does not automatically preserve the initiator's blind spots.
- **Findings are hypotheses.** The initiator accepts, rejects, or fixes each finding with explicit reasoning; reviewer suggestions are not commands.
- **Round-start is a contract.** Claims about completed changes must match the actual files listed for review.
- **Files are the source of truth.** A restarted agent resumes from `.dual-review/<session_id>/`, not from chat history.

## Repository structure

```text
codex/
  SKILL.md              # Codex initiator instructions
  review-session.ps1    # Session state and correction loop
  protocol-file.ps1     # Validated atomic publication
  reviewer-prompt.txt   # Independent reviewer instructions
  wait-for-review.ps1   # Windows wait helper
  tests/                # Protocol and session checks
claude-code/
  SKILL.md              # Original initiator protocol
  reviewer-prompt.txt   # Independent reviewer protocol
  wait-for-review.ps1   # Windows wait helper
  wait-for-review.sh    # Bash wait helper
docs/
  review-findings.md    # Historical self-review of the original protocol
```

## Limitations

- The automated session driver belongs to the Windows `codex/` bundle. The original `claude-code/` bundle remains a separate instruction-driven workflow.
- Both agents must keep access to the same project or worktree for the duration of the session.
- File polling is intentionally simple and may detect a transition a few seconds after it occurs.
- A session can run for up to five rounds by default.
