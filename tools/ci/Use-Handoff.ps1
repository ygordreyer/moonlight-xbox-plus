[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $HandoffRoot,
    [Parameter(Mandatory)] [string] $RunId,
    [Parameter(Mandatory)] [string] $RunAttempt,
    [Parameter(Mandatory)] [string] $Destination,
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory)] [string] $ExpectedSha,
    [string] $GithubOutputPath
)

$ErrorActionPreference = 'Stop'
if ($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $RunAttempt -notmatch '^[A-Za-z0-9_-]+$') { throw 'Run identifiers may contain only letters, digits, underscores, and hyphens.' }
function Resolve-ScopedPath([string] $Path, [string] $Label, [switch] $AllowCurrentDirectory) {
    $base = (Get-Location).ProviderPath
    $full = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $base $Path)) }
    if ($full -eq [IO.Path]::GetPathRoot($full) -or (-not $AllowCurrentDirectory -and $full -eq $base)) { throw "Unsafe $Label path: $Path" }; return $full
}
function Test-Overlaps([string] $Left, [string] $Right) { $l = $Left.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar; $r = $Right.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar; return $Left -eq $Right -or $l.StartsWith($r, [StringComparison]::OrdinalIgnoreCase) -or $r.StartsWith($l, [StringComparison]::OrdinalIgnoreCase) }
function Assert-NoReparse([string] $Path) { $root = [IO.Path]::GetPathRoot($Path); $current = $root; foreach ($part in $Path.Substring($root.Length).TrimStart('\', '/') -split '[\\/]') { if ($part) { $current = Join-Path $current $part; if (Test-Path -LiteralPath $current) { if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse-point path component is not allowed: $current" } } } } }
$HandoffRoot = Resolve-ScopedPath $HandoffRoot 'handoff root'; $Destination = Resolve-ScopedPath $Destination 'destination'; $WorkspaceRoot = Resolve-ScopedPath $WorkspaceRoot 'workspace root' -AllowCurrentDirectory
if (Test-Overlaps $HandoffRoot $Destination) { throw 'Handoff root and destination must be disjoint.' }
if (-not $Destination.StartsWith($WorkspaceRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Destination must be inside the explicitly scoped workspace root.' }
Assert-NoReparse $HandoffRoot; Assert-NoReparse $Destination; Assert-NoReparse $WorkspaceRoot
$lockPath = Join-Path $HandoffRoot '.handoff.lock'
$lock = $null
$deadline = (Get-Date).AddSeconds(60)
while (-not $lock) {
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { if ((Get-Date) -ge $deadline) { throw "Timed out waiting for handoff lock: $lockPath" }; Start-Sleep -Seconds 1 }
}
try {
$source = Join-Path $HandoffRoot "$RunId-$RunAttempt"
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    $source = Get-ChildItem -LiteralPath $HandoffRoot -Directory -Filter "$RunId-*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Where-Object {
            $info = Join-Path $_.FullName 'build-info.json'
            (Test-Path -LiteralPath $info) -and ((Get-Content -LiteralPath $info -Raw | ConvertFrom-Json).sha -eq $ExpectedSha)
        } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $source) { throw "No usable handoff exists for run $RunId and SHA $ExpectedSha. Re-run all jobs." }
foreach ($required in @('ready.json', 'build-info.json', 'artifact\build-info.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $required))) { throw "Incomplete handoff at ${source}: missing $required" }
}
try {
    $outerInfo = Get-Content -LiteralPath (Join-Path $source 'build-info.json') -Raw | ConvertFrom-Json
    $artifactInfo = Get-Content -LiteralPath (Join-Path $source 'artifact\build-info.json') -Raw | ConvertFrom-Json
    if ($outerInfo.sha -ne $ExpectedSha -or $artifactInfo.sha -ne $ExpectedSha) { throw 'SHA mismatch' }
    Get-Content -LiteralPath (Join-Path $source 'ready.json') -Raw | ConvertFrom-Json | Out-Null
}
catch { throw "Invalid handoff metadata at ${source}: $($_.Exception.Message)" }
if ($GithubOutputPath) { "handoff_path=$source" | Add-Content -LiteralPath $GithubOutputPath }
$marker = Join-Path $source '.deploying'; $marked = $false
try {
    New-Item -ItemType File -Path $marker -Force | Out-Null; $marked = $true
    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $source 'artifact') -Destination $Destination -Recurse -Force
} catch { if ($marked) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }; throw }
Write-Host "Handoff acquired: $source"
}
finally { $lock.Dispose() }
