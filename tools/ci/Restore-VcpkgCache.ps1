[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CacheRoot,
    [Parameter(Mandatory)] [string] $Key,
    [Parameter(Mandatory)] [string] $Destination,
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter(Mandatory)] [string] $ArchiveUrl,
    [string] $ArchivePath,
    [int] $LockTimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
$entry = Join-Path $CacheRoot $Key
$payload = Join-Path $entry 'payload\vcpkg_installed'
$lock = Join-Path $CacheRoot "$Key.lock"
if ($Key -notmatch '^[a-f0-9]{64}$') { throw 'Cache key must be a lowercase SHA-256 hex value.' }
function Resolve-ScopedPath([string] $Path, [string] $Label, [switch] $AllowCurrentDirectory) {
    $base = (Get-Location).ProviderPath
    $full = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $base $Path)) }
    if ($full -eq [IO.Path]::GetPathRoot($full) -or (-not $AllowCurrentDirectory -and $full -eq $base)) { throw "Unsafe $Label path: $Path" }
    return $full
}
function Test-Overlaps([string] $Left, [string] $Right) {
    $l = $Left.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar; $r = $Right.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $Left -eq $Right -or $l.StartsWith($r, [StringComparison]::OrdinalIgnoreCase) -or $r.StartsWith($l, [StringComparison]::OrdinalIgnoreCase)
}
function Assert-NoReparse([string] $Path) {
    $root = [IO.Path]::GetPathRoot($Path); $current = $root
    foreach ($part in $Path.Substring($root.Length).TrimStart('\', '/') -split '[\\/]') { if ($part) { $current = Join-Path $current $part; if (Test-Path -LiteralPath $current) { if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse-point path component is not allowed: $current" } } } }
}
$CacheRoot = Resolve-ScopedPath $CacheRoot 'cache root'
$Destination = Resolve-ScopedPath $Destination 'destination'
$WorkspaceRoot = Resolve-ScopedPath $WorkspaceRoot 'workspace root' -AllowCurrentDirectory
if (Test-Overlaps $CacheRoot $Destination) { throw 'Cache root and destination must be disjoint.' }
if (-not ($Destination.StartsWith($WorkspaceRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { throw 'Destination must be inside the explicitly scoped workspace root.' }
Assert-NoReparse $CacheRoot; Assert-NoReparse $Destination; Assert-NoReparse $WorkspaceRoot

function Copy-Payload {
    $metadata = Join-Path $entry 'cache-info.json'
    if (-not (Test-Path -LiteralPath $payload -PathType Container) -or -not (Test-Path -LiteralPath $metadata -PathType Leaf)) { return $false }
    try { if ((Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json).key -ne $Key) { return $false } } catch { return $false }
    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $payload -Destination $Destination -Recurse -Force
    return $true
}

New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
if (Copy-Payload) { Write-Host "vcpkg cache hit: $entry"; exit 0 }

$deadline = (Get-Date).AddSeconds($LockTimeoutSeconds)
while ($true) {
    try {
        $lockHandle = [IO.File]::Open($lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        break
    }
    catch [System.IO.IOException] {
        if (Copy-Payload) { Write-Host "vcpkg cache hit after wait: $entry"; exit 0 }
        if ((Get-Date) -ge $deadline) { throw "Timed out waiting for vcpkg cache population: $entry" }
        Start-Sleep -Seconds 1
    }
}

try {
    if (Copy-Payload) { Write-Host "vcpkg cache hit after lock: $entry"; exit 0 }
    if (Test-Path -LiteralPath $entry) { Remove-Item -LiteralPath $entry -Recurse -Force }
    $stage = Join-Path $CacheRoot ".$Key.staging.$PID"
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $archive = if ($ArchivePath) { $ArchivePath } else { Join-Path $stage 'vcpkg_installed.zip' }
    if (-not $ArchivePath) { Invoke-WebRequest -Uri $ArchiveUrl -OutFile $archive }
    $extract = Join-Path $stage 'extract'
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    $installed = Join-Path $extract 'vcpkg_installed'
    if (-not (Test-Path -LiteralPath $installed -PathType Container)) { throw "Archive does not contain vcpkg_installed: $archive" }
    New-Item -ItemType Directory -Path (Join-Path $stage 'payload') | Out-Null
    Move-Item -LiteralPath $installed -Destination (Join-Path $stage 'payload\vcpkg_installed')
    [ordered]@{ key = $Key; archiveUrl = $ArchiveUrl; createdAt = (Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'cache-info.json') -Encoding utf8
    Move-Item -LiteralPath $stage -Destination $entry
    if (-not (Copy-Payload)) { throw "Published vcpkg cache cannot be copied: $entry" }
    Write-Host "vcpkg cache populated: $entry"
}
finally {
    if ($lockHandle) { $lockHandle.Dispose() }
}
