param(
    [Parameter(Mandatory = $true)][string]$SessionDir,
    [Parameter(Mandatory = $true)][string]$RoundId,
    [ValidateSet("claim", "review", "next", "final", "next-or-final")][string]$WaitFor = "review",
    [int]$TimeoutSec = 3600
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $SessionDir -PathType Container)) {
    @{ status = "error"; reason = "session_dir_missing"; path = $SessionDir } |
        ConvertTo-Json -Compress
    exit 1
}

if ($RoundId -notmatch '^R[1-9]\d*$') {
    @{ status = "error"; reason = "bad_round_id"; round = $RoundId } |
        ConvertTo-Json -Compress
    exit 1
}

if ($TimeoutSec -lt 0) {
    @{ status = "error"; reason = "bad_timeout"; timeout_sec = $TimeoutSec } |
        ConvertTo-Json -Compress
    exit 1
}

function Get-NextRoundId {
    param([string]$Current)
    $n = [int]($Current.Substring(1))
    return "R$($n + 1)"
}

# Isolate protocol parameters and preferences from this script's own variables.
$protocolModule = New-Module -ScriptBlock {
    param($ProtocolPath)
    . $ProtocolPath -Library
} -ArgumentList (Join-Path $PSScriptRoot "protocol-file.ps1")
Import-Module $protocolModule -Scope Local -DisableNameChecking
$claimPath = Join-Path $SessionDir "$RoundId-02-claude-claimed.flg"
$reviewPath = Join-Path $SessionDir "$RoundId-03-claude-review.md"

switch ($WaitFor) {
    "claim" {
        $targets = @(@{ event = "claim"; path = $claimPath })
    }
    "review" {
        $target = Join-Path $SessionDir "$RoundId-03-claude-review.md"
        $targets = @(@{ event = "review"; path = $target })
    }
    "next" {
        $nextRound = Get-NextRoundId $RoundId
        $target = Join-Path $SessionDir "$nextRound-01-round-start.md"
        $targets = @(@{ event = "next"; path = $target; next_round = $nextRound })
    }
    "final" {
        $target = Join-Path $SessionDir "final.md"
        $targets = @(@{ event = "final"; path = $target })
    }
    "next-or-final" {
        $nextRound = Get-NextRoundId $RoundId
        $targets = @(
            @{ event = "final"; path = (Join-Path $SessionDir "final.md") }
            @{ event = "next"; path = (Join-Path $SessionDir "$nextRound-01-round-start.md"); next_round = $nextRound }
        )
    }
}

$start = Get-Date
$deadline = if ($TimeoutSec -eq 0) { $null } else { $start.AddSeconds($TimeoutSec) }

try {
while ($true) {
    if ($WaitFor -in @("claim", "review")) {
        if (Test-Path -LiteralPath $claimPath) {
            Assert-ClaimFile -Path $claimPath
        } elseif (Test-Path -LiteralPath $reviewPath) {
            Stop-Protocol -Reason "review_without_claim" -Path $reviewPath -Detail "A review appeared without its preceding zero-byte claim."
        }
    }
    foreach ($candidate in $targets) {
        if (-not (Test-Path -LiteralPath $candidate.path)) {
            continue
        }

        if ($candidate.event -eq "review") {
            Assert-ClaimFile -Path $claimPath
            $reviewText = [IO.File]::ReadAllText($reviewPath, [Text.Encoding]::UTF8)
            $null = Assert-Review -Text $reviewText -ReviewPath $reviewPath -RoundStartPath (Join-Path $SessionDir "$RoundId-01-round-start.md") -ExpectedRound ([int]$RoundId.Substring(1))
        }

        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $readyResult = [ordered]@{
            status = "ready"
            wait_for = $WaitFor
            event = $candidate.event
            round = $RoundId
            path = $candidate.path
            elapsed_sec = $elapsed
        }
        if ($candidate.event -eq "next") {
            $readyResult.next_round = $candidate.next_round
        }
        $readyResult | ConvertTo-Json -Compress
        exit 0
    }

    if ($null -ne $deadline -and (Get-Date) -ge $deadline) {
        break
    }

    # Адаптивный sleep: 0-30s по 2с, 30-90s по 5с, далее по 10с
    $elapsed = ((Get-Date) - $start).TotalSeconds
    if ($elapsed -lt 30) {
        $sleepSec = 2
    } elseif ($elapsed -lt 90) {
        $sleepSec = 5
    } else {
        $sleepSec = 10
    }

    if ($null -ne $deadline) {
        $remainingSec = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        if ($remainingSec -le 0) {
            continue
        }
        $sleepSec = [Math]::Min($sleepSec, $remainingSec)
    }

    Start-Sleep -Seconds $sleepSec
}
} catch {
    $reason = $_.Exception.Data["reason"]
    $errorPath = $_.Exception.Data["path"]
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $reason = "wait_failed"
        $errorPath = $SessionDir
    }
    @{ status = "error"; reason = $reason; path = $errorPath; detail = $_.Exception.Message } | ConvertTo-Json -Compress
    exit 1
}

$elapsed = [int]((Get-Date) - $start).TotalSeconds
$timeoutResult = [ordered]@{
    status = "timeout"
    wait_for = $WaitFor
    round = $RoundId
    elapsed_sec = $elapsed
}
if ($targets.Count -eq 1) {
    $timeoutResult.path = $targets[0].path
} else {
    $timeoutResult.paths = @($targets | ForEach-Object { $_.path })
}
$timeoutResult | ConvertTo-Json -Compress
exit 2
