$ErrorActionPreference = "Stop"

$skillDir = Split-Path -Parent $PSScriptRoot
$protocolScript = Join-Path $skillDir "protocol-file.ps1"
$waitScript = Join-Path $skillDir "wait-for-review.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("dual-review-tests-" + [Guid]::NewGuid().ToString("N"))
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$waitProcess = $null
$crashProcess = $null
$crashWatcher = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)

    [IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function New-TestSession {
    param([string]$Name, [switch]$Claimed)

    $session = Join-Path $testRoot $Name
    [void](New-Item -ItemType Directory -Path $session)
    $roundStart = @'
# Round 1

```json
{
  "round": 1,
  "scope": "plan-only",
  "session_id": "test"
}
```

## Context
Test fixture.
'@
    Write-Utf8 -Path (Join-Path $session "R1-01-round-start.md") -Text $roundStart
    if ($Claimed) {
        [IO.File]::WriteAllBytes((Join-Path $session "R1-02-claude-claimed.flg"), [byte[]]@())
    }
    return $session
}

function Invoke-Protocol {
    param([string[]]$Arguments)

    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $protocolScript @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $json = ($output -join "`n") | ConvertFrom-Json
    return [pscustomobject]@{
        ExitCode = $exitCode
        Json = $json
        Output = $output -join "`n"
    }
}

function Invoke-Wait {
    param([string]$Session, [string]$Event = "review", [int]$Timeout = 1)

    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $waitScript -SessionDir $Session -RoundId R1 -WaitFor $Event -TimeoutSec $Timeout 2>&1)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $exitCode; Json = (($output -join "`n") | ConvertFrom-Json); Output = ($output -join "`n") }
}

function Get-ApprovedReview {
    param([string]$Summary = "Everything is consistent.")

    $template = @'
# Claude Code review for round 1

```json
{
  "round": 1,
  "verdict": "APPROVED",
  "scope": "plan-only",
  "summary": "{{SUMMARY}}",
  "findings": []
}
```

## Summary
{{SUMMARY}}

## Findings

None.
'@
    return $template.Replace("{{SUMMARY}}", $Summary)
}

function Get-FindingReview {
    param([string]$EvidencePath = "path/to/file.md")

    $template = @'
# Claude Code review for round 1

```json
{
  "round": 1,
  "verdict": "NEEDS_WORK",
  "scope": "plan-only",
  "summary": "One material issue remains.",
  "findings": [
    {
      "id": 1,
      "severity": "major",
      "confidence": 90,
      "evidence_path": "{{EVIDENCE_PATH}}",
      "evidence_anchor": "section Contract",
      "summary": "Contract is incomplete"
    }
  ]
}
```

## Summary
One material issue remains.

## Findings

### Finding 1: Contract is incomplete

Problem:
The contract omits a required state.

Impact:
The next step is ambiguous.

Proposal:
Describe the missing state.
'@
    return $template.Replace("{{EVIDENCE_PATH}}", $EvidencePath)
}

[void](New-Item -ItemType Directory -Path $testRoot)
try {
    # A module scope keeps operation parameter defaults out of the caller.
    $SessionDir = "caller-session"
    $RoundId = "caller-round"
    $Kind = "caller-kind"
    $originalErrorPreference = $ErrorActionPreference
    $library = New-Module -ScriptBlock { param($Path) . $Path -Library } -ArgumentList $protocolScript
    Import-Module $library -Scope Local -DisableNameChecking
    Assert-True ($SessionDir -ceq "caller-session" -and $RoundId -ceq "caller-round" -and $Kind -ceq "caller-kind" -and $ErrorActionPreference -eq $originalErrorPreference) "Library loading changed caller variables."
    $caughtReason = $null
    try { Assert-ClaimFile -Path (Join-Path $testRoot "missing.flg") } catch { $caughtReason = $_.Exception.Data["reason"] }
    Assert-True ($caughtReason -eq "claim_missing") "Library validation did not throw a structured error."

    $session = New-TestSession -Name "publish-valid"

    $claim = Invoke-Protocol -Arguments @("-SessionDir", $session, "-RoundId", "R1", "-Kind", "claude-claim")
    Assert-True ($claim.ExitCode -eq 0 -and $claim.Json.status -eq "created") "Claude claim was not created: $($claim.Output)"
    $claudeClaimPath = Join-Path $session "R1-02-claude-claimed.flg"
    Assert-True ((Test-Path -LiteralPath $claudeClaimPath) -and (Get-Item -LiteralPath $claudeClaimPath).Length -eq 0) "Claude claim has the wrong name or content."

    $claimAgain = Invoke-Protocol -Arguments @("-SessionDir", $session, "-RoundId", "R1", "-Kind", "claude-claim")
    Assert-True ($claimAgain.ExitCode -eq 0 -and $claimAgain.Json.status -eq "already_exists") "Repeated claim is not idempotent."

    $badRound = Invoke-Protocol -Arguments @("-SessionDir", $session, "-RoundId", "round-one", "-Kind", "claude-claim")
    Assert-True ($badRound.ExitCode -eq 1 -and $badRound.Json.reason -eq "bad_round_id") "Bad RoundId was not rejected."

    $reviewDraft = Join-Path $testRoot "approved.md"
    Write-Utf8 -Path $reviewDraft -Text (Get-ApprovedReview)
    $publish = Invoke-Protocol -Arguments @("-SessionDir", $session, "-RoundId", "R1", "-Kind", "claude-review", "-ContentPath", $reviewDraft)
    Assert-True ($publish.ExitCode -eq 0 -and $publish.Json.status -eq "created") "Valid review was not published: $($publish.Output)"
    $canonicalReview = Join-Path $session "R1-03-claude-review.md"
    Assert-True (Test-Path -LiteralPath $canonicalReview) "Canonical review name was not generated."

    $validate = Invoke-Protocol -Arguments @("-SessionDir", $session, "-RoundId", "R1", "-Kind", "claude-review", "-ValidateOnly")
    Assert-True ($validate.ExitCode -eq 0 -and $validate.Json.status -eq "valid") "Canonical review did not pass validation: $($validate.Output)"

    $codexClaim = Invoke-Protocol -Arguments @("-SessionDir", $session, "-RoundId", "R1", "-Kind", "codex-claim")
    Assert-True ($codexClaim.ExitCode -eq 0 -and $codexClaim.Json.status -eq "created") "Codex claim was not created: $($codexClaim.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $session "R1-04-codex-claimed.flg")) "Codex claim has the wrong name."

    $changedDraft = Join-Path $testRoot "changed.md"
    Write-Utf8 -Path $changedDraft -Text (Get-ApprovedReview -Summary "Different valid content.")
    $originalCanonical = [IO.File]::ReadAllText($canonicalReview, [Text.Encoding]::UTF8)
    $overwrite = Invoke-Protocol -Arguments @("-SessionDir", $session, "-RoundId", "R1", "-Kind", "claude-review", "-ContentPath", $changedDraft)
    Assert-True ($overwrite.ExitCode -eq 1 -and $overwrite.Json.reason -eq "target_exists") "An existing canonical review was not protected."
    Assert-True ([IO.File]::ReadAllText($canonicalReview, [Text.Encoding]::UTF8) -ceq $originalCanonical) "Canonical review was overwritten."

    $invalidSession = New-TestSession -Name "reject-invalid" -Claimed
    $invalidDraft = Join-Path $testRoot "invalid.md"
    Write-Utf8 -Path $invalidDraft -Text ((Get-ApprovedReview) -replace '"round": 1', '"round": "1"')
    $invalid = Invoke-Protocol -Arguments @("-SessionDir", $invalidSession, "-RoundId", "R1", "-Kind", "claude-review", "-ContentPath", $invalidDraft)
    Assert-True ($invalid.ExitCode -eq 1 -and $invalid.Json.reason -eq "bad_review_round") "String round was not rejected."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalidSession "R1-03-claude-review.md"))) "Invalid review became canonical."

    $malformedSession = New-TestSession -Name "reject-malformed-json" -Claimed
    $malformedDraft = Join-Path $testRoot "malformed.md"
    Write-Utf8 -Path $malformedDraft -Text ((Get-ApprovedReview) -replace '"findings": \[\]', '"findings": [')
    $malformed = Invoke-Protocol -Arguments @("-SessionDir", $malformedSession, "-RoundId", "R1", "-Kind", "claude-review", "-ContentPath", $malformedDraft)
    Assert-True ($malformed.ExitCode -eq 1 -and $malformed.Json.reason -eq "invalid_json") "Malformed JSON was not rejected."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $malformedSession "R1-03-claude-review.md"))) "Malformed review became canonical."

    $findingSession = New-TestSession -Name "publish-finding" -Claimed
    $findingDraft = Join-Path $testRoot "finding.md"
    Write-Utf8 -Path $findingDraft -Text (Get-FindingReview)
    $findingPublish = Invoke-Protocol -Arguments @("-SessionDir", $findingSession, "-RoundId", "R1", "-Kind", "claude-review", "-ContentPath", $findingDraft)
    Assert-True ($findingPublish.ExitCode -eq 0 -and $findingPublish.Json.status -eq "created" -and $findingPublish.Json.findings -eq 1) "Valid finding review was not published: $($findingPublish.Output)"

    $pathSession = New-TestSession -Name "reject-backslash" -Claimed
    $pathDraft = Join-Path $testRoot "backslash.md"
    Write-Utf8 -Path $pathDraft -Text (Get-FindingReview -EvidencePath 'path\to\file.md')
    $badPath = Invoke-Protocol -Arguments @("-SessionDir", $pathSession, "-RoundId", "R1", "-Kind", "claude-review", "-ContentPath", $pathDraft)
    Assert-True ($badPath.ExitCode -eq 1 -and $badPath.Json.reason -in @("invalid_json", "backslash_in_evidence_path")) "Backslash path was not rejected."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $pathSession "R1-03-claude-review.md"))) "Review with bad path became canonical."

    $crashSession = New-TestSession -Name "interrupted-publish" -Claimed
    $crashDraft = Join-Path $testRoot "large-approved.md"
    $crashText = (Get-ApprovedReview) + "`n`n## Crash padding`n" + [string]::new([char]'x', 64 * 1024 * 1024)
    Write-Utf8 -Path $crashDraft -Text $crashText
    $expectedLength = $utf8NoBom.GetByteCount($crashText)
    $crashStdout = Join-Path $testRoot "crash.stdout"
    $crashStderr = Join-Path $testRoot "crash.stderr"
    $crashWatcher = [IO.FileSystemWatcher]::new($crashSession)
    $crashWatcher.NotifyFilter = [IO.NotifyFilters]::FileName
    $crashWatcher.EnableRaisingEvents = $true
    $crashArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"' + $protocolScript + '"'),
        "-SessionDir", ('"' + $crashSession + '"'),
        "-RoundId", "R1",
        "-Kind", "claude-review",
        "-ContentPath", ('"' + $crashDraft + '"')
    )
    $crashProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $crashArguments -WindowStyle Hidden -RedirectStandardOutput $crashStdout -RedirectStandardError $crashStderr -PassThru
    $createdFile = $crashWatcher.WaitForChanged([IO.WatcherChangeTypes]::Created, 30000)
    Assert-True (-not $createdFile.TimedOut) "Interrupted publish did not create an observable output file."
    if (-not $crashProcess.HasExited) {
        $crashProcess.Kill()
    }
    $crashProcess.WaitForExit()
    $crashCanonical = Join-Path $crashSession "R1-03-claude-review.md"
    $canonicalIsAbsentOrComplete = (-not (Test-Path -LiteralPath $crashCanonical)) -or ((Get-Item -LiteralPath $crashCanonical).Length -eq $expectedLength)
    Assert-True $canonicalIsAbsentOrComplete "Interrupted publish left a partial canonical review."

    $unclaimedSession = New-TestSession -Name "unclaimed"
    $unclaimedPublish = Invoke-Protocol -Arguments @("-SessionDir", $unclaimedSession, "-RoundId", "R1", "-Kind", "claude-review", "-ContentPath", $reviewDraft)
    Assert-True ($unclaimedPublish.ExitCode -eq 1 -and $unclaimedPublish.Json.reason -eq "claim_missing") "Review was published before its claim."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $unclaimedSession "R1-03-claude-review.md"))) "Unclaimed review became canonical."
    Write-Utf8 -Path (Join-Path $unclaimedSession "R1-03-claude-review.md") -Text (Get-ApprovedReview)
    $orphanWait = Invoke-Wait -Session $unclaimedSession
    Assert-True ($orphanWait.ExitCode -eq 1 -and $orphanWait.Json.reason -eq "review_without_claim") "Wait accepted an orphan review."
    foreach ($operation in @(@("-Kind", "claude-review", "-ValidateOnly"), @("-Kind", "codex-claim"), @("-Kind", "claude-claim"))) {
        $orphanOperation = Invoke-Protocol -Arguments (@("-SessionDir", $unclaimedSession, "-RoundId", "R1") + $operation)
        Assert-True ($orphanOperation.ExitCode -eq 1 -and $orphanOperation.Json.reason -in @("claim_missing", "review_without_claim")) "An orphan review was accepted or retroactively claimed: $($orphanOperation.Output)"
    }

    foreach ($flagType in @("nonempty", "directory")) {
        $badFlagSession = New-TestSession -Name "flag-$flagType"
        $badFlagPath = Join-Path $badFlagSession "R1-02-claude-claimed.flg"
        if ($flagType -eq "directory") {
            [void](New-Item -ItemType Directory -Path $badFlagPath)
            $expectedFlagReason = "sentinel_not_file"
        } else {
            Write-Utf8 -Path $badFlagPath -Text "claimed"
            $expectedFlagReason = "sentinel_not_empty"
        }
        $badFlagWait = Invoke-Wait -Session $badFlagSession
        Assert-True ($badFlagWait.ExitCode -eq 1 -and $badFlagWait.Json.reason -eq $expectedFlagReason) "Wait accepted a $flagType claim: $($badFlagWait.Output)"
        $badFlagClaim = Invoke-Protocol -Arguments @("-SessionDir", $badFlagSession, "-RoundId", "R1", "-Kind", "claude-claim")
        Assert-True ($badFlagClaim.ExitCode -eq 1 -and $badFlagClaim.Json.reason -eq $expectedFlagReason) "Claim operation accepted a $flagType claim."
    }

    $claimedSession = New-TestSession -Name "claim-before-review" -Claimed
    $claimReady = Invoke-Wait -Session $claimedSession -Event "claim"
    Assert-True ($claimReady.ExitCode -eq 0 -and $claimReady.Json.event -eq "claim") "Claim wait did not detect a valid claim."
    $claimOnly = Invoke-Wait -Session $claimedSession
    Assert-True ($claimOnly.ExitCode -eq 2 -and $claimOnly.Json.status -eq "timeout") "A claim alone was treated as a completed review."
    $orderedPublish = Invoke-Protocol -Arguments @("-SessionDir", $claimedSession, "-RoundId", "R1", "-Kind", "claude-review", "-ContentPath", $reviewDraft)
    Assert-True ($orderedPublish.ExitCode -eq 0) "Ordered review publication failed."
    $orderedWait = Invoke-Wait -Session $claimedSession
    Assert-True ($orderedWait.ExitCode -eq 0 -and $orderedWait.Json.event -eq "review") "Ordered claim and review did not become ready."

    $invalidWaitSession = New-TestSession -Name "wait-malformed-review" -Claimed
    Write-Utf8 -Path (Join-Path $invalidWaitSession "R1-03-claude-review.md") -Text ([IO.File]::ReadAllText($malformedDraft))
    $invalidWait = Invoke-Wait -Session $invalidWaitSession
    Assert-True ($invalidWait.ExitCode -eq 1 -and $invalidWait.Json.reason -eq "invalid_json") "Wait accepted a malformed review."

    $waitSession = Join-Path $testRoot "wait-next"
    [void](New-Item -ItemType Directory -Path $waitSession)
    $stdoutPath = Join-Path $testRoot "wait.stdout"
    $stderrPath = Join-Path $testRoot "wait.stderr"
    $waitReadyPath = Join-Path $testRoot "wait.ready"
    $waitRunnerPath = Join-Path $testRoot "wait-runner.ps1"
    # Observe the first real polling sleep without depending on process startup speed.
    Write-Utf8 -Path $waitRunnerPath -Text @'
param([string]$WaitScript, [string]$SessionDir, [string]$ReadyPath)
$ErrorActionPreference = "Stop"
function Start-Sleep {
    param([int]$Seconds)
    [IO.File]::WriteAllText($ReadyPath, "")
    Microsoft.PowerShell.Utility\Start-Sleep -Seconds $Seconds
}
& $WaitScript -SessionDir $SessionDir -RoundId R1 -WaitFor next-or-final -TimeoutSec 0
'@
    $argumentList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"' + $waitRunnerPath + '"'),
        "-WaitScript", ('"' + $waitScript + '"'),
        "-SessionDir", ('"' + $waitSession + '"'),
        "-ReadyPath", ('"' + $waitReadyPath + '"')
    )
    $waitProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $argumentList -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $startupDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $waitReadyPath) -and -not $waitProcess.HasExited -and [DateTime]::UtcNow -lt $startupDeadline) {
        Start-Sleep -Milliseconds 50
    }
    Assert-True (Test-Path -LiteralPath $waitReadyPath) "Wait process did not enter its polling loop."
    Assert-True (-not $waitProcess.HasExited) "Infinite wait exited before the next round existed."
    Write-Utf8 -Path (Join-Path $waitSession "R2-01-round-start.md") -Text "# Round 2"
    Assert-True ($waitProcess.WaitForExit(8000)) "Infinite wait did not wake for the next round."
    $waitProcess.WaitForExit()
    $waitProcess.Refresh()
    $waitStdout = [IO.File]::ReadAllText($stdoutPath)
    $waitStderr = [IO.File]::ReadAllText($stderrPath)
    Assert-True ([string]::IsNullOrWhiteSpace($waitStderr)) "Wait process wrote to stderr: $waitStderr"
    $waitResult = $waitStdout | ConvertFrom-Json
    Assert-True ($waitResult.status -eq "ready" -and $waitResult.event -eq "next" -and $waitResult.next_round -eq "R2") "Wait process returned the wrong event."
    Assert-True ($waitResult.elapsed_sec -ge 2) "Wait fixture appeared before the process entered its polling loop."

    $finalSession = Join-Path $testRoot "wait-final"
    [void](New-Item -ItemType Directory -Path $finalSession)
    Write-Utf8 -Path (Join-Path $finalSession "final.md") -Text "# Done"
    $finalOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $waitScript -SessionDir $finalSession -RoundId R1 -WaitFor next-or-final -TimeoutSec 0)
    Assert-True ($LASTEXITCODE -eq 0) "Final wait failed."
    $finalResult = ($finalOutput -join "`n") | ConvertFrom-Json
    Assert-True ($finalResult.status -eq "ready" -and $finalResult.event -eq "final") "Final did not take precedence."

    $timeoutSession = Join-Path $testRoot "wait-timeout"
    [void](New-Item -ItemType Directory -Path $timeoutSession)
    $timeoutOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $waitScript -SessionDir $timeoutSession -RoundId R1 -WaitFor review -TimeoutSec 1)
    Assert-True ($LASTEXITCODE -eq 2) "Finite wait did not return timeout exit code."
    $timeoutResult = ($timeoutOutput -join "`n") | ConvertFrom-Json
    Assert-True ($timeoutResult.status -eq "timeout" -and -not [string]::IsNullOrWhiteSpace($timeoutResult.path)) "Finite wait did not preserve timeout output."

    @{ status = "passed"; tests = 29 } | ConvertTo-Json -Compress
} finally {
    if ($null -ne $crashWatcher) {
        $crashWatcher.Dispose()
    }
    foreach ($testProcess in @($crashProcess, $waitProcess)) {
        if ($null -ne $testProcess) {
            if (-not $testProcess.HasExited) {
                $testProcess.Kill()
            }
            $testProcess.WaitForExit()
            $testProcess.Dispose()
        }
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        Assert-True ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTestRoot) -like "dual-review-tests-*") "Refusing cleanup outside the test directory."
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
