[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ("runner-register-test-" + [guid]::NewGuid())
function gh {
    param([Parameter(ValueFromRemainingArguments)] $Arguments)
    $global:LASTEXITCODE = 0
    if ($script:ghMode -eq 'failure') { $global:LASTEXITCODE = 1; return '' }
    if ($script:ghMode -eq 'duplicate') { return '{"runners":[{"name":"duplicate"}]}' }
    throw 'Registration token must not be requested in this test.'
}
try {
    $source = Join-Path $root 'source'
    New-Item -ItemType Directory -Path (Join-Path $source 'bin'), (Join-Path $source 'externals') -Force | Out-Null
    '@exit /b 0' | Set-Content -LiteralPath (Join-Path $source 'config.cmd')
    '@exit /b 0' | Set-Content -LiteralPath (Join-Path $source 'run.cmd')
    $script:ghMode = 'duplicate'
    $duplicateFailed = $false
    try { & (Join-Path $repo 'tools\ci\register-runner.ps1') -Register -Name duplicate -SourceDir $source -TargetDir (Join-Path $root 'duplicate') } catch { $duplicateFailed = $true }
    if (-not $duplicateFailed) { throw 'Duplicate runner did not stop registration.' }
    $script:ghMode = 'failure'
    $lookupFailed = $false
    try { & (Join-Path $repo 'tools\ci\register-runner.ps1') -Register -Name unavailable -SourceDir $source -TargetDir (Join-Path $root 'failure') } catch { $lookupFailed = $true }
    if (-not $lookupFailed) { throw 'Runner lookup failure did not stop registration.' }
    & (Join-Path $repo 'tools\ci\register-runner.ps1') -Register -Name whatif -SourceDir $source -TargetDir (Join-Path $root 'whatif') -WhatIf
    if (Test-Path (Join-Path $root 'whatif')) { throw 'WhatIf created a runner target.' }
    Write-Host 'PASS register-runner duplicate, lookup-failure, and WhatIf tests'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
