# Run with powershell.exe -NoProfile -ExecutionPolicy Bypass -File this-file.ps1.
# All reviewers below are synthetic local files; no model or reviewer CLI is started.
$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$driver = Join-Path $skillRoot 'review-session.ps1'
$protocol = Join-Path $skillRoot 'protocol-file.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dual-review-session-tests-' + [Guid]::NewGuid().ToString('N'))
$encoding = New-Object Text.UTF8Encoding($false)
$script:checks = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Invoke-Script([string]$Path, [string[]]$Arguments, [string]$Stdin) {
    if ($PSBoundParameters.ContainsKey('Stdin')) {
        $output = @($Stdin | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments)
    } else {
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments)
    }
    $code = $LASTEXITCODE
    $text = $output -join "`n"
    $json = if (-not [string]::IsNullOrWhiteSpace($text)) { $text | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ Code = $code; Json = $json; Text = $text }
}

function Invoke-Driver([string]$Action, [string[]]$Extra = @(), [string]$Thread = 'test-main') {
    Invoke-Script $driver (@('-Action', $Action, '-ProjectRoot', $testRoot, '-ThreadId', $Thread) + $Extra)
}

function Expect-Action($Result, [string]$Action) {
    Assert-True ($Result.Code -eq 0 -and $Result.Json.action -eq $Action) "Expected $Action; got $($Result.Text)"
}

function Expect-Refusal($Result, [string]$Reason) {
    Assert-True ($Result.Code -eq 1 -and $Result.Json.reason -match $Reason -and -not $Result.Json.allow_final) "Expected refusal /$Reason/; got $($Result.Text)"
}

function Invoke-Hook([string]$Event = 'Stop', [string]$Thread = 'test-main', [bool]$RepeatedStop = $false) {
    $eventJson = @{ hook_event_name = $Event; session_id = $Thread; cwd = $testRoot
        stop_hook_active = $RepeatedStop; prompt = 'What is the review status?'; source = 'compact' } | ConvertTo-Json -Compress
    Invoke-Script -Path $driver -Arguments @('-Action', 'hook', '-ProjectRoot', $testRoot) -Stdin $eventJson
}

function Publish-Review([string]$Session, [int]$Round, [string]$Verdict = 'NEEDS_WORK') {
    $claim = Invoke-Script $protocol @('-SessionDir', $Session, '-RoundId', "R$Round", '-Kind', 'claude-claim')
    Assert-True ($claim.Code -eq 0) "Synthetic reviewer claim failed: $($claim.Text)"
    $findings = @()
    $prose = "## Findings`n`nNone.`n"
    if ($Verdict -ne 'APPROVED') {
        $findings = @(@{ id = 1; severity = 'major'; confidence = 95; evidence_path = 'contract.md'
            evidence_anchor = 'Contract'; summary = 'Missing completion rule' })
        $prose = "## Findings`n`n### Finding 1: Missing completion rule`n`nProblem:`nCompletion is undefined.`n`nImpact:`nReview can stop early.`n`nProposal:`nDefine completion.`n"
    }
    $json = @{ round = $Round; verdict = $Verdict; scope = 'plan-only'; summary = 'Synthetic integration review.'; findings = $findings } | ConvertTo-Json -Depth 5
    $draft = Join-Path $testRoot 'review-draft.md'
    Write-Utf8 $draft ("# Claude Code review for round $Round`n`n" + '```json' + "`n$json`n" + '```' + "`n`n## Summary`nSynthetic integration review.`n`n$prose")
    $published = Invoke-Script $protocol @('-SessionDir', $Session, '-RoundId', "R$Round", '-Kind', 'claude-review', '-ContentPath', $draft)
    Assert-True ($published.Code -eq 0) "Synthetic review publication failed: $($published.Text)"
}

[void][IO.Directory]::CreateDirectory($testRoot)
try {
    Assert-True ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1) 'Run this integration check on Windows PowerShell 5.1.'
    $contextPath = Join-Path $testRoot 'context.json'
    $decisionPath = Join-Path $testRoot 'decisions.json'
    $contractPath = Join-Path $testRoot 'contract.md'
    Write-Utf8 $contractPath "# Contract`nA review starts here.`n"
    Write-Utf8 $contextPath (@{ context = 'Review the local contract.'; task = 'Check completeness.'; files = @('contract.md'); notes = 'Synthetic test.' } | ConvertTo-Json)
    $initArgs = @('-InputPath', $contextPath, '-Scope', 'plan-only')
    $created = Invoke-Driver 'init' $initArgs
    Expect-Action $created 'deliver-prompt'
    $session = $created.Json.session_dir.Replace('\', '/')
    $sessionId = $created.Json.session_id
    Assert-True ($created.Json.launch_mode -eq 'manual' -and $created.Json.max_rounds -eq 5 -and -not $created.Json.allow_final) 'Default mode, round limit, or completion permission changed.'
    $starter = [IO.File]::ReadAllText($created.Json.prompt_path)
    Assert-True ($starter -match 'through final.md' -and $starter -match 'Do not replace it with a one-shot or another skill') 'Starter prompt lost multi-round protocol continuity.'

    # Re-entry cannot silently change the original protocol, scope, limit, or directory.
    $again = Invoke-Driver 'init' @('-LaunchMode', 'authorized-cli', '-Scope', 'architecture-check', '-MaxRounds', '1')
    Expect-Action $again 'deliver-prompt'
    Assert-True ($again.Json.session_id -eq $sessionId -and $again.Json.scope -eq 'plan-only' -and $again.Json.launch_mode -eq 'manual' -and $again.Json.max_rounds -eq 5) 'Repeated init replaced the selected review process.'
    Expect-Refusal (Invoke-Driver 'finish') 'Premature finish'
    Expect-Action (Invoke-Driver 'prompt-shown') 'wait-claim'
    Expect-Action (Invoke-Driver 'status') 'wait-claim'
    $claim = Invoke-Script $protocol @('-SessionDir', $session, '-RoundId', 'R1', '-Kind', 'claude-claim')
    Assert-True ($claim.Code -eq 0) 'Claim could not be published.'
    Expect-Action (Invoke-Driver 'status') 'wait-review'

    # Actual stdin contracts, including a question and compacted context recovery.
    $stop = Invoke-Hook
    Assert-True ($stop.Code -eq 0 -and $stop.Json.decision -eq 'block' -and $stop.Json.reason.Contains($session)) "Stop did not continue this active session: exit=$($stop.Code), output=$($stop.Text)"
    $repeatStop = Invoke-Hook -RepeatedStop $true
    Assert-True ($repeatStop.Code -eq 0 -and $repeatStop.Json.decision -ne 'block' -and -not [string]::IsNullOrWhiteSpace($repeatStop.Json.systemMessage)) 'Repeated Stop must report the continuation failure without looping.'
    $other = Invoke-Hook -Thread 'unrelated-thread'
    Assert-True ($other.Code -eq 0 -and [string]::IsNullOrWhiteSpace($other.Text)) 'Hook affected another task.'
    foreach ($eventName in @('UserPromptSubmit', 'SessionStart')) {
        $context = Invoke-Hook -Event $eventName
        Assert-True ($context.Code -eq 0 -and $context.Json.hookSpecificOutput.hookEventName -eq $eventName -and $context.Json.hookSpecificOutput.additionalContext.Contains($session)) "$eventName lost the active session."
    }
    Expect-Action (Invoke-Driver 'status') 'wait-review'

    Publish-Review $session 1
    Expect-Action (Invoke-Driver 'status') 'fix-and-advance'
    Expect-Refusal (Invoke-Driver 'finish') 'Premature finish'
    Write-Utf8 $decisionPath '[]'
    Expect-Refusal (Invoke-Driver 'advance' @('-InputPath', $contextPath, '-DecisionsPath', $decisionPath)) 'cover every finding'
    $decision = @(@{ id = 1; resolution = 'ACCEPTED'; reason = 'Added the completion rule.'; verification = 'Read and checked the changed contract.'; changed_files = @('contract.md') })
    Write-Utf8 $decisionPath (ConvertTo-Json -InputObject $decision -Depth 5)
    Expect-Refusal (Invoke-Driver 'advance' @('-InputPath', $contextPath, '-DecisionsPath', $decisionPath)) 'no actual file change'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $session 'R2-01-round-start.md'))) 'Rejected advance still created the next round.'
    Write-Utf8 $contractPath "# Contract`nA review finishes after approval, rejection, or the round limit.`n"
    $advanced = Invoke-Driver 'advance' @('-InputPath', $contextPath, '-DecisionsPath', $decisionPath)
    Expect-Action $advanced 'wait-claim'
    Assert-True ([IO.File]::ReadAllText((Join-Path $session 'R1-05-decisions.json')).TrimStart().StartsWith('[')) 'A single decision was stored as an object instead of a JSON array.'
    Assert-True ($advanced.Json.round -eq 2 -and $advanced.Json.session_id -eq $sessionId -and $advanced.Json.session_dir -eq $session) 'Advance created another review session.'
    $recovered = Invoke-Driver 'init'
    Expect-Action $recovered 'wait-claim'
    Assert-True ($recovered.Json.round -eq 2 -and $recovered.Json.session_dir -eq $session) 'Recovery lost the second round.'
    Publish-Review $session 2 'APPROVED'
    Expect-Action (Invoke-Driver 'status') 'finish'
    $finished = Invoke-Driver 'finish'
    Expect-Action $finished 'done'
    Assert-True ($finished.Json.allow_final -and $finished.Json.final_status -eq 'approved') 'Approval did not produce a consistent final result.'
    Expect-Action (Invoke-Driver 'finish') 'done'
    $closedHook = Invoke-Hook
    Assert-True ($closedHook.Code -eq 0 -and [string]::IsNullOrWhiteSpace($closedHook.Text)) 'Hook continued a completed review.'

    # Recovery validates the historical evidence and final round, not just final.md existence.
    $storedDecisions = Join-Path $session 'R1-05-decisions.json'
    $decisionText = [IO.File]::ReadAllText($storedDecisions)
    Write-Utf8 $storedDecisions '{broken'
    Expect-Refusal (Invoke-Driver 'status') '.' # Native JSON parser wording varies by PowerShell version.
    Write-Utf8 $storedDecisions $decisionText
    $finalPath = Join-Path $session 'final.md'
    $finalText = [IO.File]::ReadAllText($finalPath)
    Write-Utf8 $finalPath ([regex]::Replace($finalText, '"round"\s*:\s*2', '"round": 1'))
    Expect-Refusal (Invoke-Driver 'status') 'round'
    Write-Utf8 $finalPath $finalText
    $finalClaim = Join-Path $session 'R2-04-codex-claimed.flg'
    Remove-Item -LiteralPath $finalClaim
    Expect-Refusal (Invoke-Driver 'status') 'claim'
    Write-Utf8 $finalClaim ''
    Expect-Action (Invoke-Driver 'status') 'done'

    # The explicit ZCode launch exception affects delivery only, including after NEEDS_WORK.
    $cli = Invoke-Driver 'init' ($initArgs + @('-LaunchMode', 'authorized-cli', '-Reviewer', 'ZCode')) 'test-cli'
    Expect-Action $cli 'deliver-prompt'
    $cliSession = $cli.Json.session_dir
    Assert-True ($cli.Json.protocol -eq 'claude-dual-review-file-based' -and $cli.Json.launch_mode -eq 'authorized-cli' -and $cli.Json.max_rounds -eq 5) 'Authorized CLI silently selected another review protocol.'
    $cliStarter = [IO.File]::ReadAllText($cli.Json.prompt_path)
    Assert-True ($cliStarter -match 'ZCode' -and $cliStarter -match 'through final.md' -and $cliStarter -notmatch 'Do not wait for a next round') 'ZCode starter changed the selected multi-round process.'
    Expect-Action (Invoke-Driver 'prompt-shown' @() 'test-cli') 'wait-claim'
    Publish-Review $cliSession 1
    Expect-Action (Invoke-Driver 'status' @() 'test-cli') 'fix-and-advance'
    Expect-Refusal (Invoke-Driver 'finish' @() 'test-cli') 'Premature finish'
    Expect-Refusal (Invoke-Driver 'cancel' @() 'test-cli') 'needs a reason'
    $cancelled = Invoke-Driver 'cancel' @('-Reason', 'The user explicitly cancelled this synthetic review.') 'test-cli'
    Expect-Action $cancelled 'done'
    Assert-True ($cancelled.Json.allow_final -and $cancelled.Json.final_status -eq 'cancelled') 'Explicit cancellation was not honored.'
    $cancelHook = Invoke-Hook -Thread 'test-cli'
    Assert-True ($cancelHook.Code -eq 0 -and [string]::IsNullOrWhiteSpace($cancelHook.Text)) 'Hook restarted a cancelled review.'

    # Another Codex chat can review without changing historical protocol identifiers.
    $peer = Invoke-Driver 'init' ($initArgs + @('-Reviewer', 'Codex')) 'test-codex-reviewer'
    Expect-Action $peer 'deliver-prompt'
    $peerStarter = [IO.File]::ReadAllText($peer.Json.prompt_path)
    Assert-True ($peerStarter.Contains('independent reviewer (Codex)')) 'Selected peer reviewer was lost.'
    Expect-Action (Invoke-Driver 'prompt-shown' @() 'test-codex-reviewer') 'wait-claim'
    Publish-Review $peer.Json.session_dir 1 'APPROVED'
    $peerFinal = Invoke-Driver 'finish' @() 'test-codex-reviewer'
    Expect-Action $peerFinal 'done'
    Assert-True ($peerFinal.Json.final_status -eq 'approved') 'Peer review could not finish through the same protocol.'

    # Rejected findings need evidence, not invented edits; the stored limit still closes the cycle.
    $limited = Invoke-Driver 'init' ($initArgs + @('-MaxRounds', '2')) 'test-limit'
    Expect-Action (Invoke-Driver 'prompt-shown' @() 'test-limit') 'wait-claim'
    Publish-Review $limited.Json.session_dir 1
    $rejectedDecision = @(@{ id = 1; resolution = 'REJECTED'; reason = 'The completion rule is already present.'; verification = 'Read the existing completion sentence.'; changed_files = @() })
    Write-Utf8 $decisionPath (ConvertTo-Json -InputObject $rejectedDecision -Depth 5)
    Expect-Action (Invoke-Driver 'advance' @('-InputPath', $contextPath, '-DecisionsPath', $decisionPath) 'test-limit') 'wait-claim'
    Publish-Review $limited.Json.session_dir 2
    $limitResult = Invoke-Driver 'finish' @() 'test-limit'
    Expect-Action $limitResult 'done'
    Assert-True ($limitResult.Json.final_status -eq 'limit') 'The configured round limit was ignored or reported as approval.'

    # Model interruption immediately after the thread locator reserves its directory.
    $interrupted = Invoke-Driver 'init' $initArgs 'test-init-crash'
    Expect-Action $interrupted 'deliver-prompt'
    foreach ($name in @('session.json', 'R1-01-round-start.md', 'starter-prompt.txt')) {
        Remove-Item -LiteralPath (Join-Path $interrupted.Json.session_dir $name)
    }
    $restored = Invoke-Driver 'init' @() 'test-init-crash'
    Expect-Action $restored 'deliver-prompt'
    Assert-True ($restored.Json.session_id -eq $interrupted.Json.session_id -and $restored.Json.session_dir.Replace('\', '/') -eq $interrupted.Json.session_dir.Replace('\', '/')) 'Interrupted init allocated a different review directory.'
    Assert-True ((Test-Path -LiteralPath $restored.Json.prompt_path) -and (Test-Path -LiteralPath (Join-Path $restored.Json.session_dir 'R1-01-round-start.md'))) 'Interrupted init did not restore the initial protocol files.'

    # Corrupt only temporary fixtures, never real review artifacts.
    foreach ($field in @('scope', 'session_id')) {
        $thread = "test-corrupt-$field"
        $corrupt = Invoke-Driver 'init' $initArgs $thread
        Expect-Action $corrupt 'deliver-prompt'
        $roundPath = Join-Path $corrupt.Json.session_dir 'R1-01-round-start.md'
        $text = [IO.File]::ReadAllText($roundPath)
        $replacement = if ($field -eq 'scope') { 'architecture-check' } else { 'another-session' }
        Write-Utf8 $roundPath ([regex]::Replace($text, ('"' + $field + '"\s*:\s*"[^"]+"'), ('"' + $field + '": "' + $replacement + '"')))
        Expect-Refusal (Invoke-Driver 'status' @() $thread) 'metadata does not match'
        $corruptHook = Invoke-Hook -Thread $thread
        Assert-True ($corruptHook.Code -eq 0 -and $corruptHook.Json.decision -ne 'block' -and -not [string]::IsNullOrWhiteSpace($corruptHook.Json.systemMessage)) 'Corrupt session was hidden or caused a continuation loop.'
    }
    Expect-Refusal (Invoke-Driver 'status' @('-SessionDir', $session) 'unrelated-thread') 'another protocol or thread'
    @{ status = 'passed'; checks = $script:checks; powershell = $PSVersionTable.PSVersion.ToString(); external_reviewers_started = 0 } | ConvertTo-Json -Compress
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'dual-review-session-tests-*') { throw 'Refusing cleanup outside the synthetic test directory.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
