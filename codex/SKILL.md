---
name: claude-dual-review-file-based
description: "Run or resume the manual file-based, multi-round review and correction protocol with an independent reviewer. Preserve this protocol when the user changes the reviewer or explicitly authorizes CLI delivery."
---

# File-based review and correction

You are the **initiator**: verify findings, make accepted fixes in the actual
plan/code/documents, test, and continue. The **reviewer** only reads the project
and writes review files. An ordinary invocation includes this correction loop;
`NEEDS_WORK` does not mean the task is finished or that edits are forbidden.
Respect an explicit user restriction on edits; report it as a constraint rather
than silently adopting another skill's `review-only` mode.

Agent identity does not define either role: Codex can review Codex, ZCode can
review Codex, and other pairings are valid. Use the reviewer selected by the
user. The skill name, `claude`/`codex` filenames and the required
`# Claude Code review for round N` heading are compatibility identifiers;
every reviewer must preserve them regardless of its actual agent name.

## Fixed rules

- Keep the selected skill, session directory, scope and round limit throughout
  review, questions, compaction and recovery. Default limit: 5 rounds.
- **Manual delivery is the default for every reviewer.** Do not run Claude,
  ZCode, Codex CLI, their wrappers, another reviewer task, or a fallback launcher
  without the user's explicit authorization. Neither continuation nor recovery
  authorizes a launch. Authorization to change delivery or reviewer changes
  only that condition; a launcher skill cannot substitute a one-shot review.
  A confirmed dead reviewer uses the same authorized delivery and session;
  never restart as the normal next-round action.
- Files in `SESSION_DIR` are append-only. Use the scripts for publication and
  transitions. Never invent a next round number or another session directory.
- Generated review artifacts, context, decisions and prompts are **English**.
  User-facing summaries and answers are **Russian**. Preserve literal names,
  source quotes and paths as needed.
- Answer questions briefly in commentary, then resume the same pending action.
  Empty tool output and a running shell `session_id` are not completion.

## Start once; recover from status

Set the exact project/worktree root explicitly. Resolve
`review-session.ps1`, `wait-for-review.ps1`, `protocol-file.ps1` and
`reviewer-prompt.txt` beside this file as absolute paths with forward slashes.
Verify they exist before creating a session. Do not search for another project
when the supplied root is wrong.

Follow the reviewed project's code-navigation rules. This bundle does not require Serena or another skill.
Choose `plan-only` for future changes; `production-change` requires existing
code changes. Other scopes: `lookup-test`, `architecture-check`.

Prepare a UTF-8 JSON context file outside canonical protocol filenames:

```json
{
  "context": "What the task is and what has already changed.",
  "task": "What the reviewer must verify.",
  "files": ["relative/path/to/file.md"],
  "notes": "Relevant constraints, or an empty string."
}
```

`files` are relative to the project root. Include files that may need correction;
the driver snapshots them before the round, including missing files as absent.
Snapshot changes prove that bytes changed, not that the fix is correct.

Run in PowerShell, substituting absolute paths:

```powershell
& '<skill>/review-session.ps1' -Action init -ProjectRoot '<project>' -Scope plan-only -InputPath '<context.json>'
```

The driver binds the session to `CODEX_THREAD_ID`. If absent, pass the actual
current task id with `-ThreadId`; never invent one. An existing active binding
returns its current action instead of creating another directory. Use
`-MaxRounds` for a user-specified limit and `-Reviewer` for the selected reviewer. Use
`-LaunchMode authorized-cli` only when the user explicitly authorizes that delivery method.

After an interruption, a question, or a round, obtain the next action:

```powershell
& '<skill>/review-session.ps1' -Action status -ProjectRoot '<project>'
```

If cwd changed, use the saved `-SessionDir '<session>'`. This is the durable
checklist: execute the returned `action` and `instruction`. If a native plan
tool is available, mirror that action there; a checked plan item never replaces
file validation. Do not create a Goal or automation without a user request.

## Execute only the returned action

| Action | Do now |
| --- | --- |
| `deliver-prompt` | Read `prompt_path`. In manual mode open it using `open_in_codex`, then show the exact prompt once in a copyable commentary block. If the host has no file panel, show the absolute file link and prompt in chat. Check the panel result: `queued` is not visible yet; give the absolute file link and report the limitation. In authorized CLI mode send this same prompt through the verified launcher contract, preserving the multi-round loop; do not ask the user to pass the prompt manually. For manual delivery, show the Windows notification below. Then run `-Action prompt-shown` and wait in this turn; no delivery confirmation from the user. |
| `wait-claim` / `wait-review` | Run the wait command below. It checks `.flg` before `.md` and validates the review. Continue the same running shell session until terminal JSON. |
| `fix-and-advance` | Read the validated `review` returned by status. Verify every finding; reject unsupported/out-of-scope findings with evidence. Apply accepted changes and test. Prepare decisions and the next English context, run `advance`, then immediately wait in this same session. |
| `finish` | Run `-Action finish`. The driver derives `approved`, `failed` or `limit` and refuses premature completion. Read its final state and give the Russian session summary. |
| `done` | Report the actual final status; only now is the protocol finished. |
| `prepare-round` / error | Inspect the exact incomplete/corrupt session and report the failure. Never overwrite canonical files, invent success, launch another reviewer or create another directory as recovery. |

## Manual handoff notification (Windows)

For each manual delivery, set `$projectTitle` to the actual project name
(or the leaf name of the explicit project root) and `$taskTitle` to the current
task title. Use the host task list when available; otherwise use a concise title
from the current user request. Never reuse another project's or chat's title.

Launch one notification in a separate hidden PowerShell process. It identifies the current project and task, remains visible until
the user dismisses it and does not block the active turn:

```powershell
$message = "Проект: $projectTitle`r`nЗадача: $taskTitle`r`n`r`nЗадание на ревью готово. Скопируйте его из файла или сообщения инициатора и передайте проверяющему."
$caption = "Dual Review — $projectTitle — $taskTitle"
$messageBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message))
$captionBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($caption))
$popupCommand = "`$message=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$messageBase64'));`$caption=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$captionBase64'));(New-Object -ComObject WScript.Shell).Popup(`$message,0,`$caption,64) | Out-Null"
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($popupCommand))
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-EncodedCommand', $encodedCommand
```

Show it once per delivery action. Do not interpret dismissal as reviewer claim;
the protocol claim file remains the only evidence that review started.

Wait command (`R<N>` comes from the driver):

```powershell
& '<skill>/wait-for-review.ps1' -SessionDir '<session>' -RoundId 'R<N>' -WaitFor review -TimeoutSec 3600
```

The script owns quiet polling. If the shell returns `session_id`, poll that same
process with `write_stdin`; keep each tool wait at most 60 seconds. Do not send
Ctrl+C, start duplicate waiters, or finish the turn because output is empty.
Do not narrate every poll. Report material changes and answer questions;
higher-priority host communication requirements still apply.

On `ready`, run `status` and proceed immediately. On timeout, inspect current
files again; report the actual timeout without claiming success or changing
the launch method. If the process is confirmed gone, restart only the waiter
for this session/round. On explicit user cancellation run `cancel` with their
reason. For a confirmed unrecoverable failure or exhausted wait deadline, run
`stop` with the actual reason. Both produce a non-approved final status; never
use either to bypass ordinary waiting or accepted corrections.

## Advance after real corrections

Decisions JSON is an array covering every finding id once:

```json
[
  {
    "id": 1,
    "resolution": "ACCEPTED",
    "reason": "The defect was confirmed and the condition was corrected.",
    "verification": "Exact reproduction/check and observed result.",
    "changed_files": ["relative/path/to/file.md"]
  }
]
```

Other resolutions: `REJECTED`, `INLINE FIX`. Rejection needs a concrete
argument and evidence in `verification`, with no `changed_files` required.
Accepted and inline fixes require real changes to snapshotted files. Describing
a future fix is insufficient; fixes to a plan must change the plan itself.

```powershell
& '<skill>/review-session.ps1' -Action advance -SessionDir '<session>' -InputPath '<next-context.json>' -DecisionsPath '<decisions.json>'
```

The driver checks decisions, publishes the initiator claim and next round in
order, and preserves scope/limit/directory. The existing reviewer picks it up.
Show a short Russian round summary, then perform the returned action without
waiting for a reaction. An incompatible launcher is a reported limitation,
not permission to change the protocol.

## Optional host integration

The driver accepts `hook` events for `Stop`, `UserPromptSubmit` and
`SessionStart`. No hooks are installed by this bundle. Only wire them into a
host that supports this contract, with an explicit `-ProjectRoot` and the same
real task id in `session_id`. Do not infer a project from a global installation.
Manual `status` recovery remains available without hooks. Synthetic tests do
not prove that host continuation or prompt display works in a live app.

## Verification

On Windows PowerShell 5.1, run `tests/run-tests.ps1` and
`tests/session-tests.ps1` from this skill directory. They use temporary files
and synthetic reviews; they do not launch an external reviewer.