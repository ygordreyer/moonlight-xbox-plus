[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Name = 'ygor-desktop-xbox-lan-2',
    [string] $SourceDir = 'C:\actions-runner\moonlight-xbox-plus',
    [string] $TargetDir = 'C:\actions-runner\moonlight-xbox-plus-2',
    [string] $Labels = 'xbox-lan',
    [string] $Repo = 'ygordreyer/moonlight-xbox-plus',
    [switch] $Register
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) { throw "Runner source does not exist: $SourceDir" }
$SourceDir = [IO.Path]::GetFullPath($SourceDir)
$TargetDir = [IO.Path]::GetFullPath($TargetDir)
if ($TargetDir -eq [IO.Path]::GetPathRoot($TargetDir) -or
    $TargetDir.StartsWith($SourceDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    $SourceDir.StartsWith($TargetDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    $TargetDir -eq $SourceDir) { throw 'Runner source and target must be distinct, disjoint non-root paths.' }
foreach ($required in @('bin', 'config.cmd', 'run.cmd')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $required))) { throw "Runner source is missing required distribution item: $required" }
}

$distributionNames = @('bin', 'externals', 'config.cmd', 'run.cmd', 'run-helper.cmd', 'run-helper.cmd.template', 'run-helper.sh.template')
$files = Get-ChildItem -LiteralPath $SourceDir -Force | Where-Object { $distributionNames -contains $_.Name }
if ($files.Count -eq 0) { throw "Runner source contains no known distribution files: $SourceDir" }
function Write-LaunchGuidance {
	Write-Host 'Launch guidance only. This script does not create or start a scheduled task.'
    $cmdline = Join-Path $TargetDir "$Name.cmdline"
    $shim = Join-Path $env:USERPROFILE 'ai-hub-work\tools\shim\run-hidden.vbs'
    Write-Host "Cmdline file (not created): $cmdline"
    Write-Host "Cmdline content: cmd.exe /d /c `"$TargetDir\run.cmd`""
    Write-Host "Scheduled-task action (not created): wscript.exe //B `"$shim`" `"$cmdline`""
}
if (-not $Register) {
	Write-Host "Dry plan: copy $($files.Count) runner distribution items from $SourceDir to $TargetDir. No files or runner registration are created without -Register."
    Write-LaunchGuidance
    exit 0
}
if (Test-Path -LiteralPath $TargetDir) { throw "Runner target already exists: $TargetDir" }
foreach ($item in $files) {
    if ($PSCmdlet.ShouldProcess($TargetDir, "Copy runner distribution item $($item.Name)")) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        Copy-Item -LiteralPath $item.FullName -Destination $TargetDir -Recurse -Force
    }
}

Write-LaunchGuidance
if (-not $PSCmdlet.ShouldProcess($TargetDir, "Register runner $Name for $Repo")) { exit 0 }

$runnerJson = & gh api "repos/$Repo/actions/runners"
if ($LASTEXITCODE -ne 0) { throw "Could not list registered runners for $Repo" }
try { $runners = $runnerJson | ConvertFrom-Json } catch { throw "GitHub returned invalid runner data for $Repo" }
if ($runners.runners | Where-Object { $_.name -eq $Name }) { throw "A runner named $Name is already registered for $Repo" }

$token = & gh api -X POST "repos/$Repo/actions/runners/registration-token" --jq .token
if ($LASTEXITCODE -ne 0) { throw "Could not create a runner registration token for $Repo" }
if (-not $token) { throw "GitHub did not return a registration token for $Repo" }
try {
    & (Join-Path $TargetDir 'config.cmd') --unattended --url "https://github.com/$Repo" --token $token --name $Name --labels $Labels --work _work
    if ($LASTEXITCODE -ne 0) { throw "Runner configuration failed with exit code $LASTEXITCODE" }
}
finally {
    $token = $null
}
