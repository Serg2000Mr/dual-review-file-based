[CmdletBinding()]
param(
    [ValidateSet('init', 'status', 'prompt-shown', 'advance', 'finish', 'cancel', 'stop', 'hook')]
    [string]$Action = 'status',
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$SessionDir,
    [string]$ThreadId = $env:CODEX_THREAD_ID,
    [ValidateSet('plan-only', 'production-change', 'lookup-test', 'architecture-check')]
    [string]$Scope = 'production-change',
    [ValidateRange(1, 100)][int]$MaxRounds = 5,
    [ValidateSet('manual', 'authorized-cli')][string]$LaunchMode = 'manual',
    [string]$Reviewer = 'Independent reviewer',
    [string]$InputPath,
    [string]$DecisionsPath,
    [string]$Reason
)

$ErrorActionPreference = 'Stop'
$protocolScript = Join-Path $PSScriptRoot 'protocol-file.ps1'
$protocolModule = New-Module -ScriptBlock { param($Path) . $Path -Library } -ArgumentList $protocolScript
Import-Module $protocolModule -Scope Local -DisableNameChecking
$encoding = New-Object Text.UTF8Encoding($false)
$protocolName = 'claude-dual-review-file-based'

function Publish-SessionFile([string]$Name, [string]$Text) {
    $path = Join-Path $SessionDir $Name
    if (Test-Path -LiteralPath $path) {
        if ([IO.File]::ReadAllText($path) -ceq $Text) { return }
        throw "Append-only file already exists: $path"
    }
    Publish-NewFileAtomically -Path $path -Bytes $encoding.GetBytes($Text)
}

function Read-SessionJson([string]$Path) {
    return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Get-FileSnapshot($Files) {
    if ($Files -isnot [Array] -or $Files.Count -eq 0) { throw 'files must be a non-empty JSON array.' }
    $snapshot = [ordered]@{}
    foreach ($file in $Files) {
        if ($file -isnot [string] -or [string]::IsNullOrWhiteSpace($file) -or
            [IO.Path]::IsPathRooted($file) -or $file.Contains('\') -or $file -match '(^|/)\.\.(/|$)') {
            throw 'files must contain project-relative paths with forward slashes and no parent traversal.'
        }
        $path = Join-Path $ProjectRoot $file
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $snapshot[$file] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        } else { $snapshot[$file] = $null }
    }
    return $snapshot
}

function New-RoundText([int]$Number, $Context, $Decisions) {
    foreach ($name in @('context', 'task')) {
        if ($Context.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($Context.$name)) {
            throw "Round context requires non-empty $name."
        }
    }
    $fields = [ordered]@{ round = $Number; scope = $meta.scope; session_id = $meta.session_id
        snapshot = (Get-FileSnapshot $Context.files) }
    $json = $fields | ConvertTo-Json -Depth 8
    $filesText = ($Context.files | ForEach-Object { '- ' + (Join-Path $ProjectRoot $_).Replace('\', '/') }) -join "`n"
    $text = "# Round $Number`n`n" + '```json' + "`n$json`n" + '```' +
        "`n`n## Context`n$($Context.context)`n`n## Task`n$($Context.task)`n`n## Files`n$filesText`n`n## Special notes`n$($Context.notes)`n"
    if ($Number -gt 1) {
        $accepted = @($Decisions | Where-Object { $_.resolution -ne 'REJECTED' })
        $rejected = @($Decisions | Where-Object { $_.resolution -eq 'REJECTED' })
        $text += "`n## What changed since the previous round`n"
        $text += ($accepted | ForEach-Object { "- F$($_.id): $($_.reason) Verification: $($_.verification)" }) -join "`n"
        if ($accepted.Count -eq 0) { $text += 'No edits; all findings were rejected with evidence.' }
        $text += "`n`n## Accepted Issues`n" + (($accepted | ForEach-Object { "- F$($_.id): $($_.reason)" }) -join "`n")
        $text += "`n`n## Rejected Issues`n" + (($rejected | ForEach-Object { "- F$($_.id): $($_.reason) Evidence: $($_.verification)" }) -join "`n") + "`n"
    }
    return $text
}

function Initialize-SessionFiles {
    [void][IO.Directory]::CreateDirectory($SessionDir)
    if (-not (Test-Path -LiteralPath (Join-Path $SessionDir 'session.json'))) {
        Publish-SessionFile 'session.json' ($meta | ConvertTo-Json -Depth 8)
    }
    if (-not (Test-Path -LiteralPath (Join-Path $SessionDir 'R1-01-round-start.md'))) {
        if (@(Get-ChildItem -LiteralPath $SessionDir -Filter 'R*' -File).Count -gt 0) { throw 'Round artifacts exist without R1 context; initialization cannot repair them.' }
        Publish-SessionFile 'R1-01-round-start.md' (New-RoundText 1 $meta.initial_context @())
    }
    if (-not (Test-Path -LiteralPath (Join-Path $SessionDir 'starter-prompt.txt'))) {
        $promptPath = (Join-Path $PSScriptRoot 'reviewer-prompt.txt').Replace('\', '/')
        $waitPath = (Join-Path $PSScriptRoot 'wait-for-review.ps1').Replace('\', '/')
        $protocolPath = $protocolScript.Replace('\', '/')
        $prompt = "Read $promptPath and follow that protocol through final.md. You are the independent reviewer ($($meta.reviewer)), not the initiator. Do not replace it with a one-shot or another skill.`nReviewed project/worktree root: $ProjectRoot. Resolve any relative project file against this root, never your own cwd.`nFor all steps substitute:`n  {{SESSION_ID}} -> $($meta.session_id)`n  {{SESSION_DIR}} -> $SessionDir`n  {{ROUND_ID}} -> R1`n  {{WAIT_SCRIPT}} -> $waitPath`n  {{PROTOCOL_SCRIPT}} -> $protocolPath`n"
        Publish-SessionFile 'starter-prompt.txt' $prompt
    }
}

function Get-SessionState {
    $state = [ordered]@{ protocol = $protocolName; session_dir = $SessionDir; session_id = $meta.session_id
        launch_mode = $meta.launch_mode; max_rounds = $meta.max_rounds; scope = $meta.scope
        allow_final = $false; round = 1; action = 'prepare-round'; instruction = 'Recover initialization in this same directory; do not create a new session.' }
    $starts = @(Get-ChildItem -LiteralPath $SessionDir -File | Where-Object { $_.Name -match '^R[1-9]\d*-01-round-start\.md$' } |
        Sort-Object { [int]($_.Name.Split('-')[0].Substring(1)) })
    $previousReview = $null
    for ($index = 0; $index -lt $starts.Count; $index++) {
        $number = $index + 1
        if ($starts[$index].Name -cne "R$number-01-round-start.md" -or $number -gt $meta.max_rounds) { throw 'Round gap or round limit violation.' }
        $start = Get-LeadingJson -Text ([IO.File]::ReadAllText($starts[$index].FullName)) -Path $starts[$index].FullName
        if ($start.round -ne $number -or $start.scope -cne $meta.scope -or $start.session_id -cne $meta.session_id) { throw 'Round metadata does not match the fixed session.' }
        if ($number -gt 1 -and ($null -eq $previousReview -or $previousReview.verdict -ne 'NEEDS_WORK')) { throw 'Next round requires a preceding NEEDS_WORK review.' }
        if ($number -gt 1) {
            Assert-ClaimFile -Path (Join-Path $SessionDir "R$($number - 1)-04-codex-claimed.flg")
            $priorDecisions = @(Read-SessionJson (Join-Path $SessionDir "R$($number - 1)-05-decisions.json"))
            $priorState = @{ review = $previousReview; round_start = $starts[$index - 1].FullName }
            Assert-Decisions $priorDecisions $priorState $start.snapshot
        }
        $state.Remove('review')
        $state.round = $number
        $state.round_start = $starts[$index].FullName
        $state.action = 'wait-claim'
        $state.instruction = 'Wait for the reviewer claim with wait-for-review.ps1 -WaitFor review. Keep polling the same running shell session; no final answer.'
        $claim = Join-Path $SessionDir "R$number-02-claude-claimed.flg"
        $reviewPath = Join-Path $SessionDir "R$number-03-claude-review.md"
        $processed = Join-Path $SessionDir "R$number-04-codex-claimed.flg"
        $previousReview = $null
        if (Test-Path -LiteralPath $claim) {
            Assert-ClaimFile -Path $claim
            $state.action = 'wait-review'
            $state.instruction = 'The reviewer claimed this round. Wait for its validated review in the same shell session; no final answer.'
        }
        if (Test-Path -LiteralPath $reviewPath) {
            $previousReview = Assert-Review -Text ([IO.File]::ReadAllText($reviewPath)) -ReviewPath $reviewPath -RoundStartPath $starts[$index].FullName -ExpectedRound $number
            $state.review = $previousReview
            $state.action = 'fix-and-advance'
            $state.instruction = 'Verify every finding, apply accepted fixes to real files and test them. Prepare decisions and next context, then run advance. NEEDS_WORK is not completion; you are the initiator, not the read-only reviewer.'
            if ($previousReview.verdict -ne 'NEEDS_WORK' -or $number -eq $meta.max_rounds) {
                $state.action = 'finish'
                $state.instruction = 'Run finish to publish the derived final result, then give the Russian session summary.'
            }
        }
        if (Test-Path -LiteralPath $processed) {
            Assert-ClaimFile -Path $processed
            if ($null -eq $previousReview) { throw 'Initiator claim has no review.' }
        }
    }
    $finalPath = Join-Path $SessionDir 'final.md'
    $deliveryClaim = Join-Path $SessionDir 'starter-shown.flg'
    if (Test-Path -LiteralPath $deliveryClaim) { Assert-ClaimFile -Path $deliveryClaim }
    if (Test-Path -LiteralPath $finalPath) {
        $final = Get-LeadingJson -Text ([IO.File]::ReadAllText($finalPath)) -Path $finalPath
        if ($final.status -notin @('approved', 'failed', 'limit', 'cancelled', 'stopped')) { throw 'Invalid final status.' }
        if (-not (Test-Integer $final.round) -or $final.round -ne $state.round) { throw 'Final round does not match this session.' }
        if ($final.status -in @('cancelled', 'stopped')) {
            if ([string]::IsNullOrWhiteSpace($final.reason)) { throw 'Cancellation or technical stop needs a reason.' }
        } else {
            if ($state.action -ne 'finish' -or $final.status -ne (Get-FinalStatus $previousReview $state.round)) { throw 'Premature or inconsistent final file.' }
            Assert-ClaimFile -Path (Join-Path $SessionDir "R$($state.round)-04-codex-claimed.flg")
        }
        $state.action = 'done'; $state.allow_final = $true; $state.final_status = $final.status
        $state.instruction = 'The session is closed. Report its actual final status in Russian.'
    } elseif ($starts.Count -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $SessionDir 'starter-shown.flg'))) {
        $state.action = 'deliver-prompt'
        $state.prompt_path = Join-Path $SessionDir 'starter-prompt.txt'
        $state.instruction = 'Show the exact prompt from prompt_path once in chat and open it in the host file panel when available, and show the Windows notification with the current project and task title as described in the skill; then run prompt-shown and wait in this turn. Manual mode never launches any reviewer CLI. Authorized CLI changes only delivery, never the multi-round protocol.'
        if ($meta.launch_mode -eq 'authorized-cli') {
            $state.instruction = 'Send the saved prompt through the explicitly authorized reviewer launcher; do not ask the user to pass it. Then run prompt-shown and wait in this turn. Preserve this exact multi-round protocol: no one-shot mode, no switch to another review skill.'
        }
    }
    return $state
}

function Get-FinalStatus($Review, [int]$Number) {
    if ($Review.verdict -eq 'APPROVED') { return 'approved' }
    if ($Review.verdict -eq 'REJECTED') { return 'failed' }
    if ($Review.verdict -eq 'NEEDS_WORK' -and $Number -eq $meta.max_rounds) { return 'limit' }
    throw 'This round cannot be finalized. Apply fixes and continue in the same session.'
}

function Assert-Decisions($Decisions, $State, $AfterSnapshot = $null) {
    if ($Decisions -isnot [Array] -or $Decisions.Count -ne @($State.review.findings).Count) { throw 'Decisions must cover every finding exactly once.' }
    $start = Get-LeadingJson -Text ([IO.File]::ReadAllText($State.round_start)) -Path $State.round_start
    $seen = @{}
    foreach ($decision in $Decisions) {
        if (-not (Test-Integer $decision.id) -or $decision.id -notin @($State.review.findings.id) -or $seen.ContainsKey($decision.id)) { throw 'Unknown or duplicate finding id.' }
        $seen[$decision.id] = $true
        if ($decision.resolution -notin @('ACCEPTED', 'REJECTED', 'INLINE FIX') -or
            [string]::IsNullOrWhiteSpace($decision.reason) -or [string]::IsNullOrWhiteSpace($decision.verification)) { throw 'Every decision requires resolution, reason and verification evidence.' }
        if ($decision.resolution -eq 'REJECTED') { continue }
        if ($decision.changed_files -isnot [Array] -or $decision.changed_files.Count -eq 0) { throw 'Accepted fixes require changed_files.' }
        $changed = $false
        foreach ($file in $decision.changed_files) {
            $before = $start.snapshot.PSObject.Properties[$file]
            if ($null -eq $before) { throw "No pre-review snapshot for changed file: $file" }
            if ($null -ne $AfterSnapshot) {
                $after = $AfterSnapshot.PSObject.Properties[$file]
                if ($null -eq $after) { throw "The next round omits a changed file: $file" }
                $afterHash = $after.Value
            } else { $afterHash = (Get-FileSnapshot @($file))[$file] }
            if ($afterHash -cne $before.Value) { $changed = $true }
        }
        if (-not $changed) { throw "Finding $($decision.id): accepted fix has no actual file change since this round started." }
    }
}

try {
    if ($Action -eq 'hook') {
        $event = [Console]::In.ReadToEnd() | ConvertFrom-Json
        if ($event.hook_event_name -notin @('Stop', 'UserPromptSubmit', 'SessionStart')) { exit 0 }
        $ThreadId = [string]$event.session_id
        # The event cwd may be a nested directory; the installed driver identifies its project.
        if (-not $PSBoundParameters.ContainsKey('ProjectRoot')) {
            $ProjectRoot = Join-Path $PSScriptRoot '../../..'
        }
    }
    if ($ThreadId -notmatch '^[a-zA-Z0-9_-]+$') { throw 'A concrete Codex thread id is required (ThreadId or CODEX_THREAD_ID).' }
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).Replace('\', '/')
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { throw 'The supplied project root does not exist.' }
    $pointerPath = Join-Path $ProjectRoot ".dual-review/active-$ThreadId.json"
    if ([string]::IsNullOrWhiteSpace($SessionDir)) {
        if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
            $locator = Read-SessionJson $pointerPath
            $SessionDir = $locator.session_dir
        }
        elseif ($Action -ne 'init') {
            if ($Action -eq 'hook') { exit 0 }
            throw 'No review is bound to this thread. Use init once; for an existing session provide its exact SessionDir.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($SessionDir)) {
        $SessionDir = [IO.Path]::GetFullPath($SessionDir).Replace('\', '/')
        $metadataPath = Join-Path $SessionDir 'session.json'
        if ($Action -eq 'init' -and -not (Test-Path -LiteralPath $metadataPath) -and $null -ne $locator.pending_init) {
            $meta = $locator.pending_init
        } else { $meta = Read-SessionJson $metadataPath }
        if ($meta.protocol -cne $protocolName -or $meta.thread_id -cne $ThreadId) { throw 'Session belongs to another protocol or thread; do not replace it.' }
        if (-not (Test-Integer $meta.max_rounds) -or $meta.max_rounds -lt 1 -or $meta.max_rounds -gt 100 -or
            $meta.scope -notin @('plan-only', 'production-change', 'lookup-test', 'architecture-check') -or
            $meta.launch_mode -notin @('manual', 'authorized-cli')) { throw 'Invalid fixed session metadata.' }
        $ProjectRoot = $meta.project_root
        if ($Action -eq 'init' -and -not (Test-Path -LiteralPath (Join-Path $SessionDir 'final.md'))) {
            Initialize-SessionFiles
        }
        $state = Get-SessionState
        if ($Action -eq 'init' -and $state.action -ne 'done') { $state | ConvertTo-Json -Depth 12 -Compress; exit 0 }
    }
    if ($Action -eq 'init') {
        $context = Read-SessionJson $InputPath
        $sessionId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $SessionDir = Join-Path $ProjectRoot ".dual-review/$sessionId"
        $meta = [pscustomobject]@{ protocol = $protocolName; thread_id = $ThreadId; session_id = $sessionId
            project_root = $ProjectRoot; scope = $Scope; max_rounds = $MaxRounds; launch_mode = $LaunchMode; reviewer = $Reviewer
            initial_context = $context }
        $null = New-RoundText 1 $context @()
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $pointerPath))
        # Reserve the directory first. This descriptor can finish an interrupted initialization.
        # Once session.json exists it is authoritative; the locator never overrides it.
        $pointerText = @{ session_dir = $SessionDir; pending_init = $meta } | ConvertTo-Json -Depth 10 -Compress
        if (Test-Path -LiteralPath $pointerPath) {
            $pointerTemp = "$pointerPath.$([Guid]::NewGuid().ToString('N')).tmp"
            [IO.File]::WriteAllText($pointerTemp, $pointerText, $encoding)
            [IO.File]::Replace($pointerTemp, $pointerPath, $null)
        } else { Publish-NewFileAtomically -Path $pointerPath -Bytes $encoding.GetBytes($pointerText) }
        Initialize-SessionFiles
    } elseif ($Action -eq 'prompt-shown') {
        if ($state.action -ne 'deliver-prompt') { throw 'Prompt delivery is not the current action.' }
        Publish-SessionFile 'starter-shown.flg' ''
    } elseif ($Action -eq 'advance') {
        if ($state.action -ne 'fix-and-advance') { throw 'The current round is not ready for corrections and advancement.' }
        $decisions = @(Read-SessionJson $DecisionsPath)
        Assert-Decisions $decisions $state
        $nextText = New-RoundText ($state.round + 1) (Read-SessionJson $InputPath) $decisions
        $nextSnapshot = (Get-LeadingJson -Text $nextText -Path $InputPath).snapshot
        Assert-Decisions $decisions $state $nextSnapshot
        Publish-SessionFile "R$($state.round)-05-decisions.json" (ConvertTo-Json -InputObject $decisions -Depth 10)
        $claimResult = (& $protocolScript -SessionDir $SessionDir -RoundId "R$($state.round)" -Kind codex-claim) | ConvertFrom-Json
        if ($claimResult.status -notin @('created', 'already_exists')) { throw ($claimResult | ConvertTo-Json -Compress) }
        Publish-SessionFile "R$($state.round + 1)-01-round-start.md" $nextText
    } elseif ($Action -in @('finish', 'cancel', 'stop')) {
        if ($state.action -eq 'done') { $state | ConvertTo-Json -Depth 12 -Compress; exit 0 }
        if ($Action -eq 'finish') {
            if ($state.action -ne 'finish') { throw 'Premature finish: this session still has work or a pending wait.' }
            $finalStatus = Get-FinalStatus $state.review $state.round
            $Reason = $state.review.summary
            $claimResult = (& $protocolScript -SessionDir $SessionDir -RoundId "R$($state.round)" -Kind codex-claim) | ConvertFrom-Json
            if ($claimResult.status -notin @('created', 'already_exists')) { throw ($claimResult | ConvertTo-Json -Compress) }
        } else {
            if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'An explicit cancellation or actual technical stop needs a reason.' }
            $finalStatus = if ($Action -eq 'cancel') { 'cancelled' } else { 'stopped' }
        }
        $finalJson = @{ status = $finalStatus; round = $state.round; reason = $Reason } | ConvertTo-Json
        Publish-SessionFile 'final.md' ("# Dual Review Result`n`n" + '```json' + "`n$finalJson`n" + '```' + "`n`n## Status`n$finalStatus`n`n## Summary`n$Reason`n")
    } elseif ($Action -eq 'hook') {
        if ($state.allow_final) { exit 0 }
        $driver = (Join-Path $PSScriptRoot 'review-session.ps1').Replace('\', '/')
        $resume = "Active $protocolName review: $($state.action), R$($state.round). $($state.instruction) Preserve $SessionDir and launch_mode=$($meta.launch_mode). Run & '$driver' -Action status -SessionDir '$SessionDir' -ThreadId '$ThreadId'. Answer questions briefly and resume; an explicit user cancellation takes precedence and requires -Action cancel -Reason."
        if ($event.hook_event_name -eq 'Stop') {
            # ponytail: one continuation per automatic Stop chain; repeated model refusal needs user attention.
            if ($event.stop_hook_active -eq $true) {
                @{ systemMessage = "Review remains unfinished in $SessionDir. The automatic continuation limit was reached; inspect the pending action instead of reporting success." } | ConvertTo-Json -Compress
                exit 0
            }
            @{ decision = 'block'; reason = $resume } | ConvertTo-Json -Compress
        } else {
            @{ hookSpecificOutput = @{ hookEventName = $event.hook_event_name; additionalContext = $resume } } | ConvertTo-Json -Compress -Depth 4
        }
        exit 0
    }
    Get-SessionState | ConvertTo-Json -Depth 12 -Compress
} catch {
    $failure = @{ status = 'error'; reason = $_.Exception.Message; session_dir = $SessionDir; allow_final = $false }
    if ($_.Exception.Data.Contains('path')) { $failure.path = $_.Exception.Data['path'] }
    if ($_.Exception.Data.Contains('reason')) { $failure.code = $_.Exception.Data['reason'] }
    if ($Action -eq 'hook') {
        # An invalid session must never create an automatic continuation loop.
        @{ systemMessage = "Review continuation unavailable: $($_.Exception.Message). The review has not been marked complete." } | ConvertTo-Json -Compress
        exit 0
    }
    $failure | ConvertTo-Json -Compress
    exit 1
}
