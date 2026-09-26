[CmdletBinding(DefaultParameterSetName = "Operation")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Library")][switch]$Library,
    [Parameter(Mandatory = $true, ParameterSetName = "Operation")][string]$SessionDir,
    [Parameter(Mandatory = $true, ParameterSetName = "Operation")][string]$RoundId,
    [Parameter(Mandatory = $true, ParameterSetName = "Operation")]
    [ValidateSet("claude-claim", "codex-claim", "claude-review")]
    [string]$Kind,
    [Parameter(ParameterSetName = "Operation")][string]$ContentPath,
    [Parameter(ParameterSetName = "Operation")][switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-ProtocolResult {
    param(
        [string]$Status,
        [string]$Path,
        [hashtable]$Extra = @{}
    )

    $result = [ordered]@{
        status = $Status
        kind = $Kind
        round = $RoundId
        path = $Path
    }
    foreach ($key in $Extra.Keys) {
        $result[$key] = $Extra[$key]
    }
    $result | ConvertTo-Json -Compress -Depth 6
}

function Stop-Protocol {
    param(
        [string]$Reason,
        [string]$Path,
        [string]$Detail
    )

    if ($Library) {
        $exception = New-Object System.InvalidOperationException($Detail)
        $exception.Data["reason"] = $Reason
        $exception.Data["path"] = $Path
        $exception.Data["detail"] = $Detail
        throw $exception
    }

    $extra = @{ reason = $Reason }
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $extra.detail = $Detail
    }
    Write-ProtocolResult -Status "error" -Path $Path -Extra $extra
    exit 1
}

function Get-LeadingJsonText {
    param(
        [string]$Text,
        [string]$Path
    )

    $pattern = '\A(?:\uFEFF)?[ \t]*#[^\r\n]*\r?\n(?:[ \t]*\r?\n)*[ \t]*```json[ \t]*\r?\n(?<json>.*?)[ \t]*\r?\n[ \t]*```'
    $match = [regex]::Match($Text, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        Stop-Protocol -Reason "json_block_missing" -Path $Path -Detail "The JSON block must be the first content after the heading."
    }

    return $match.Groups["json"].Value
}

function Get-LeadingJson {
    param(
        [string]$Text,
        [string]$Path
    )

    $jsonText = Get-LeadingJsonText -Text $Text -Path $Path
    try {
        return ($jsonText | ConvertFrom-Json)
    } catch {
        Stop-Protocol -Reason "invalid_json" -Path $Path -Detail $_.Exception.Message
    }
}

function Test-Integer {
    param([object]$Value)

    return (
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    )
}

function Assert-Text {
    param(
        [object]$Value,
        [string]$Reason,
        [string]$Path
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        Stop-Protocol -Reason $Reason -Path $Path -Detail "Expected a non-empty string."
    }
}

function Assert-ClaimFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Stop-Protocol -Reason "claim_missing" -Path $Path -Detail "The reviewer must claim the round before publishing a review."
    }
    $claim = Get-Item -LiteralPath $Path -Force
    if ($claim -isnot [IO.FileInfo] -or ($claim.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Stop-Protocol -Reason "sentinel_not_file" -Path $Path -Detail "Claim files must be regular files, not directories or links."
    }
    if ($claim.Length -ne 0) {
        Stop-Protocol -Reason "sentinel_not_empty" -Path $Path -Detail "Claim files must be zero-byte sentinels."
    }
}

function Assert-Review {
    param(
        [string]$Text,
        [string]$ReviewPath,
        [string]$RoundStartPath,
        [int]$ExpectedRound
    )

    $claimPath = Join-Path (Split-Path -Parent $RoundStartPath) "R$ExpectedRound-02-claude-claimed.flg"
    Assert-ClaimFile -Path $claimPath

    $headingPattern = '\A(?:\uFEFF)?# Claude Code review for round (?<round>[1-9]\d*)\r?\n'
    $heading = [regex]::Match($Text, $headingPattern)
    if (-not $heading.Success -or [int]$heading.Groups["round"].Value -ne $ExpectedRound) {
        Stop-Protocol -Reason "bad_review_heading" -Path $ReviewPath -Detail "Expected '# Claude Code review for round $ExpectedRound'."
    }

    $jsonText = Get-LeadingJsonText -Text $Text -Path $ReviewPath
    try {
        $review = $jsonText | ConvertFrom-Json
    } catch {
        Stop-Protocol -Reason "invalid_json" -Path $ReviewPath -Detail $_.Exception.Message
    }
    if (-not (Test-Integer $review.round) -or [int]$review.round -ne $ExpectedRound) {
        Stop-Protocol -Reason "bad_review_round" -Path $ReviewPath -Detail "round must be integer $ExpectedRound."
    }

    $verdicts = @("APPROVED", "NEEDS_WORK", "REJECTED")
    if ($review.verdict -isnot [string] -or $verdicts -notcontains $review.verdict) {
        Stop-Protocol -Reason "bad_verdict" -Path $ReviewPath -Detail "verdict must be APPROVED, NEEDS_WORK, or REJECTED."
    }

    $scopes = @("plan-only", "production-change", "lookup-test", "architecture-check")
    if ($review.scope -isnot [string] -or $scopes -notcontains $review.scope) {
        Stop-Protocol -Reason "bad_scope" -Path $ReviewPath -Detail "scope is not canonical."
    }
    Assert-Text -Value $review.summary -Reason "bad_summary" -Path $ReviewPath

    if (-not (Test-Path -LiteralPath $RoundStartPath -PathType Leaf)) {
        Stop-Protocol -Reason "round_start_missing" -Path $RoundStartPath -Detail "The review cannot be published before the round start."
    }
    $roundStartText = [IO.File]::ReadAllText($RoundStartPath, [Text.Encoding]::UTF8)
    $roundStart = Get-LeadingJson -Text $roundStartText -Path $RoundStartPath
    if (-not (Test-Integer $roundStart.round) -or [int]$roundStart.round -ne $ExpectedRound) {
        Stop-Protocol -Reason "bad_round_start_round" -Path $RoundStartPath -Detail "round must be integer $ExpectedRound."
    }
    if ($roundStart.scope -isnot [string] -or $roundStart.scope -ne $review.scope) {
        Stop-Protocol -Reason "scope_mismatch" -Path $ReviewPath -Detail "Review scope must match the round-start scope."
    }

    if ($review.findings -isnot [System.Array]) {
        Stop-Protocol -Reason "findings_not_array" -Path $ReviewPath -Detail "findings must be a JSON array."
    }
    $findings = @($review.findings)
    $rawEvidencePaths = [regex]::Matches($jsonText, '"evidence_path"\s*:\s*"(?<path>(?:\\.|[^"\\])*)"')
    if ($rawEvidencePaths.Count -ne $findings.Count) {
        Stop-Protocol -Reason "bad_evidence_path" -Path $ReviewPath -Detail "Every finding must contain one JSON string evidence_path."
    }
    foreach ($rawEvidencePath in $rawEvidencePaths) {
        if ($rawEvidencePath.Groups["path"].Value.Contains('\')) {
            Stop-Protocol -Reason "backslash_in_evidence_path" -Path $ReviewPath -Detail "evidence_path must use forward slashes."
        }
    }

    if ($review.verdict -eq "APPROVED" -and $findings.Count -ne 0) {
        Stop-Protocol -Reason "approved_with_findings" -Path $ReviewPath -Detail "APPROVED requires an empty findings array."
    }
    if ($review.verdict -ne "APPROVED" -and $findings.Count -eq 0) {
        Stop-Protocol -Reason "verdict_without_findings" -Path $ReviewPath -Detail "$($review.verdict) requires at least one finding."
    }

    $severities = @("critical", "major", "minor")
    for ($index = 0; $index -lt $findings.Count; $index++) {
        $finding = $findings[$index]
        $expectedId = $index + 1
        if (-not (Test-Integer $finding.id) -or [int]$finding.id -ne $expectedId) {
            Stop-Protocol -Reason "bad_finding_id" -Path $ReviewPath -Detail "Finding ids must be consecutive integers starting at 1."
        }
        if ($finding.severity -isnot [string] -or $severities -notcontains $finding.severity) {
            Stop-Protocol -Reason "bad_severity" -Path $ReviewPath -Detail "Finding $expectedId has a non-canonical severity."
        }
        if (-not (Test-Integer $finding.confidence) -or [int]$finding.confidence -lt 75 -or [int]$finding.confidence -gt 100) {
            Stop-Protocol -Reason "bad_confidence" -Path $ReviewPath -Detail "Finding $expectedId confidence must be an integer from 75 to 100."
        }
        Assert-Text -Value $finding.evidence_path -Reason "bad_evidence_path" -Path $ReviewPath
        if ($finding.evidence_path.Contains('\')) {
            Stop-Protocol -Reason "backslash_in_evidence_path" -Path $ReviewPath -Detail "Finding $expectedId must use forward slashes."
        }
        Assert-Text -Value $finding.evidence_anchor -Reason "bad_evidence_anchor" -Path $ReviewPath
        Assert-Text -Value $finding.summary -Reason "bad_finding_summary" -Path $ReviewPath

        $findingHeading = "(?m)^### Finding ${expectedId}: $([regex]::Escape($finding.summary))[ \t]*\r?$"
        $findingMatch = [regex]::Match($Text, $findingHeading)
        if (-not $findingMatch.Success) {
            Stop-Protocol -Reason "finding_prose_missing" -Path $ReviewPath -Detail "Finding $expectedId prose heading is missing or does not match its JSON summary."
        }

        $sectionStart = $findingMatch.Index + $findingMatch.Length
        $remainder = $Text.Substring($sectionStart)
        $nextFinding = [regex]::Match($remainder, '(?m)^### Finding \d+:')
        $section = if ($nextFinding.Success) { $remainder.Substring(0, $nextFinding.Index) } else { $remainder }
        foreach ($label in @("Problem:", "Impact:", "Proposal:")) {
            if ($section -notmatch "(?m)^$([regex]::Escape($label))[ \t]*\r?$") {
                Stop-Protocol -Reason "finding_prose_incomplete" -Path $ReviewPath -Detail "Finding $expectedId is missing '$label'."
            }
        }
    }

    if ($findings.Count -eq 0 -and $Text -notmatch '(?ms)^## Findings[ \t]*\r?\n[ \t]*\r?\n[ \t]*None\.[ \t]*(?:\r?\n|\z)') {
        Stop-Protocol -Reason "empty_findings_prose_missing" -Path $ReviewPath -Detail "An approved review must contain '## Findings' followed by 'None.'."
    }

    return $review
}

function Write-NewFile {
    param(
        [string]$Path,
        [byte[]]$Bytes
    )

    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        if ($Bytes.Length -gt 0) {
            $stream.Write($Bytes, 0, $Bytes.Length)
        }
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Publish-NewFileAtomically {
    param(
        [string]$Path,
        [byte[]]$Bytes
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    $fileName = [IO.Path]::GetFileName($Path)
    $tempPath = Join-Path $directory (".$fileName.$([Guid]::NewGuid().ToString('N')).tmp")
    $stream = $null
    $published = $false
    try {
        $stream = [IO.File]::Open($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        if ($Bytes.Length -gt 0) {
            $stream.Write($Bytes, 0, $Bytes.Length)
        }
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        [IO.File]::Move($tempPath, $Path)
        $published = $true
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (-not $published -and (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

if ($Library) {
    return
}

if (-not (Test-Path -LiteralPath $SessionDir -PathType Container)) {
    Stop-Protocol -Reason "session_dir_missing" -Path $SessionDir -Detail "Session directory does not exist."
}
if ($RoundId -notmatch '^R(?<number>[1-9]\d*)$') {
    Stop-Protocol -Reason "bad_round_id" -Path $SessionDir -Detail "RoundId must match R<N>, where N is positive."
}
if ($ValidateOnly -and $Kind -ne "claude-review") {
    Stop-Protocol -Reason "validate_only_not_supported" -Path $SessionDir -Detail "ValidateOnly is supported only for claude-review."
}

$roundNumber = [int]$Matches["number"]
$roundStartPath = Join-Path $SessionDir "$RoundId-01-round-start.md"
$reviewerClaimPath = Join-Path $SessionDir "$RoundId-02-claude-claimed.flg"
switch ($Kind) {
    "claude-claim" { $targetPath = Join-Path $SessionDir "$RoundId-02-claude-claimed.flg" }
    "claude-review" { $targetPath = Join-Path $SessionDir "$RoundId-03-claude-review.md" }
    "codex-claim" { $targetPath = Join-Path $SessionDir "$RoundId-04-codex-claimed.flg" }
}

if ($Kind -eq "claude-review") {
    Assert-ClaimFile -Path $reviewerClaimPath
    if ($ValidateOnly) {
        $sourcePath = $targetPath
    } else {
        if ([string]::IsNullOrWhiteSpace($ContentPath) -or -not (Test-Path -LiteralPath $ContentPath -PathType Leaf)) {
            Stop-Protocol -Reason "content_file_missing" -Path $ContentPath -Detail "A review draft file is required."
        }
        $sourcePath = $ContentPath
    }

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Stop-Protocol -Reason "content_file_missing" -Path $sourcePath -Detail "The review file does not exist."
    }

    $content = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8)
    $review = Assert-Review -Text $content -ReviewPath $sourcePath -RoundStartPath $roundStartPath -ExpectedRound $roundNumber

    if ($ValidateOnly) {
        Write-ProtocolResult -Status "valid" -Path $targetPath -Extra @{ verdict = $review.verdict; findings = @($review.findings).Count }
        exit 0
    }

    if (Test-Path -LiteralPath $targetPath) {
        $existing = [IO.File]::ReadAllText($targetPath, [Text.Encoding]::UTF8)
        if ($existing -ceq $content) {
            Write-ProtocolResult -Status "already_exists" -Path $targetPath
            exit 0
        }
        Stop-Protocol -Reason "target_exists" -Path $targetPath -Detail "Append-only protocol files cannot be overwritten."
    }

    try {
        Publish-NewFileAtomically -Path $targetPath -Bytes $utf8NoBom.GetBytes($content)
    } catch [IO.IOException] {
        Stop-Protocol -Reason "target_exists" -Path $targetPath -Detail "Append-only protocol files cannot be overwritten."
    }
    Write-ProtocolResult -Status "created" -Path $targetPath -Extra @{ verdict = $review.verdict; findings = @($review.findings).Count }
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($ContentPath)) {
    Stop-Protocol -Reason "unexpected_content_file" -Path $ContentPath -Detail "Claim files are always empty and do not accept content."
}
if (-not (Test-Path -LiteralPath $roundStartPath -PathType Leaf)) {
    Stop-Protocol -Reason "round_start_missing" -Path $roundStartPath -Detail "The round must be opened before it can be claimed."
}
if ($Kind -eq "codex-claim") {
    Assert-ClaimFile -Path $reviewerClaimPath
    $reviewPath = Join-Path $SessionDir "$RoundId-03-claude-review.md"
    if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
        Stop-Protocol -Reason "review_missing" -Path $reviewPath -Detail "Codex cannot claim an unpublished review."
    }
    $reviewText = [IO.File]::ReadAllText($reviewPath, [Text.Encoding]::UTF8)
    $null = Assert-Review -Text $reviewText -ReviewPath $reviewPath -RoundStartPath $roundStartPath -ExpectedRound $roundNumber
}

if ($Kind -eq "claude-claim" -and -not (Test-Path -LiteralPath $targetPath) -and
    (Test-Path -LiteralPath (Join-Path $SessionDir "$RoundId-03-claude-review.md"))) {
    Stop-Protocol -Reason "review_without_claim" -Path $targetPath -Detail "An orphan review cannot be legitimized by creating its claim afterwards."
}

if (Test-Path -LiteralPath $targetPath) {
    Assert-ClaimFile -Path $targetPath
    Write-ProtocolResult -Status "already_exists" -Path $targetPath
    exit 0
}

try {
    Write-NewFile -Path $targetPath -Bytes ([byte[]]@())
} catch [IO.IOException] {
    if (Test-Path -LiteralPath $targetPath) {
        Assert-ClaimFile -Path $targetPath
        Write-ProtocolResult -Status "already_exists" -Path $targetPath
        exit 0
    }
    Stop-Protocol -Reason "target_exists" -Path $targetPath -Detail "Could not create the zero-byte sentinel atomically."
}

Write-ProtocolResult -Status "created" -Path $targetPath
