[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceDir,
    [Parameter(Mandatory)] [string] $HandoffRoot,
    [Parameter(Mandatory)] [string] $RunId,
    [Parameter(Mandatory)] [string] $RunAttempt,
    [int] $RetentionCount = 10,
    [switch] $ExpectDeploy,
    [string] $Repo,
    [scriptblock] $RunStatusResolver
)

$ErrorActionPreference = 'Stop'
if ($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $RunAttempt -notmatch '^[A-Za-z0-9_-]+$') { throw 'Run identifiers may contain only letters, digits, underscores, and hyphens.' }
$HandoffRoot = [IO.Path]::GetFullPath($HandoffRoot)
if ($HandoffRoot -eq [IO.Path]::GetPathRoot($HandoffRoot) -or $HandoffRoot -eq [Environment]::CurrentDirectory) { throw "Unsafe handoff root: $HandoffRoot" }
$sourceInfo = Join-Path $SourceDir 'build-info.json'
if (-not (Test-Path -LiteralPath $sourceInfo -PathType Leaf)) { throw "build-info.json is missing from $SourceDir" }
New-Item -ItemType Directory -Path $HandoffRoot -Force | Out-Null
$lockPath = Join-Path $HandoffRoot '.handoff.lock'
$lock = $null
$deadline = (Get-Date).AddSeconds(60)
while (-not $lock) {
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { if ((Get-Date) -ge $deadline) { throw "Timed out waiting for handoff lock: $lockPath" }; Start-Sleep -Seconds 1 }
}
try {
$name = "$RunId-$RunAttempt"
$destination = Join-Path $HandoffRoot $name
if (Test-Path -LiteralPath $destination) { throw "Handoff already exists: $destination" }
$stage = Join-Path $HandoffRoot ".$name.staging.$PID"
New-Item -ItemType Directory -Path (Join-Path $stage 'artifact') -Force | Out-Null
Copy-Item -Path (Join-Path $SourceDir '*') -Destination (Join-Path $stage 'artifact') -Recurse -Force
Copy-Item -LiteralPath $sourceInfo -Destination (Join-Path $stage 'build-info.json') -Force
[ordered]@{ runId = $RunId; runAttempt = $RunAttempt; publishedAt = (Get-Date).ToUniversalTime().ToString('o') } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'ready.json') -Encoding utf8
if ($ExpectDeploy) { New-Item -ItemType File -Path (Join-Path $stage '.pending-deploy') | Out-Null }
Move-Item -LiteralPath $stage -Destination $destination

# A deploy writes .deploying before it reads artifact data. Retention never removes
# that directory, even if a build publishes while the console is busy.
if (-not $RunStatusResolver -and $Repo -and $env:GH_TOKEN) {
    $RunStatusResolver = {
        param([string] $Id)
        & gh api "repos/$Repo/actions/runs/$Id" --jq .status
        if ($LASTEXITCODE -ne 0) { throw "GitHub run lookup failed for $Id" }
    }
}
foreach ($pending in Get-ChildItem -LiteralPath $HandoffRoot -Directory | Where-Object {
    (Test-Path -LiteralPath (Join-Path $_.FullName '.pending-deploy')) -or
    (Test-Path -LiteralPath (Join-Path $_.FullName '.deploying'))
}) {
    if (-not $RunStatusResolver) { continue }
    try {
        $ready = Get-Content -LiteralPath (Join-Path $pending.FullName 'ready.json') -Raw | ConvertFrom-Json
        if ((& $RunStatusResolver $ready.runId).Trim() -eq 'completed') {
            $pendingMarker = Join-Path $pending.FullName '.pending-deploy'
            $deployingMarker = Join-Path $pending.FullName '.deploying'
            if (Test-Path -LiteralPath $pendingMarker) { Remove-Item -LiteralPath $pendingMarker -Force }
            if (Test-Path -LiteralPath $deployingMarker) { Remove-Item -LiteralPath $deployingMarker -Force }
        }
    }
    catch {
        Write-Warning "Keeping pending handoff $($pending.Name): terminal run status could not be confirmed."
    }
}
Get-ChildItem -LiteralPath $HandoffRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'ready.json') } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -Skip $RetentionCount |
    Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $_.FullName '.deploying')) -and
        -not (Test-Path -LiteralPath (Join-Path $_.FullName '.pending-deploy'))
    } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
Write-Host "Handoff published: $destination"
}
finally { $lock.Dispose() }
