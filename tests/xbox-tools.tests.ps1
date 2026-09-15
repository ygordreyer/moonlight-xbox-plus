#Requires -Version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$logsTool = Join-Path $root 'tools/xbox-logs.ps1'
$deployTool = Join-Path $root 'tools/xbox-deploy.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('moonlight-xbox-tools-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null

function Assert-That {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-FreePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

function Start-MockPortal {
    param([ValidateSet('success', 'evil', 'failure')][string]$Mode)
    $port = Get-FreePort
    $job = Start-Job -ArgumentList $port, $Mode -ScriptBlock {
        param($Port, $ServerMode)
        $listener = [Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Start()
        $requests = if ($ServerMode -eq 'success') { 5 } elseif ($ServerMode -eq 'evil') { 3 } else { 1 }
        try {
            for ($i = 0; $i -lt $requests; $i++) {
                $context = $listener.GetContext()
                $response = $context.Response
                $path = $context.Request.Url.AbsolutePath
                $query = [Web.HttpUtility]::ParseQueryString($context.Request.Url.Query)
                if ($ServerMode -eq 'failure') { $response.StatusCode = 500; $body = 'mock portal failure' }
                elseif ($path -eq '/api/app/packagemanager/packages') {
                    $body = '{"InstalledPackages":[{"Name":"50497EliaZammuto.MoonlightUWP","PackageFamilyName":"50497EliaZammuto.MoonlightUWP_test","PackageFullName":"Moonlight_1.2.3.4_x64","Version":{"Major":1,"Minor":2,"Build":3,"Revision":4}}]}'
                } elseif ($path -eq '/api/filesystem/apps/files' -and $query['path'] -eq '\LocalState\logs') {
                    if ($ServerMode -eq 'success') { $body = '{"Items":[]}' }
                    else { $response.StatusCode = 404; $body = 'not found' }
                } elseif ($path -eq '/api/filesystem/apps/files') {
                    if ($ServerMode -eq 'evil') { $body = '{"Items":[{"Name":"..\\escape.log","Type":0}]}' }
                    else { $body = '{"Items":[{"Name":"nested","Type":"16"},{"Name":"moonlight-20260915-100000.log","Type":0},{"Name":"moonlight-20260915-090000.log","Type":32}]}' }
                } elseif ($path -eq '/api/filesystem/apps/file') { $body = "log:$($query['filename'])" }
                else { $response.StatusCode = 404; $body = 'not found' }
                $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                $response.ContentType = 'application/json'
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.Close()
            }
        } finally { $listener.Stop(); $listener.Close() }
    }
    Start-Sleep -Milliseconds 100
    [pscustomobject]@{ Port = $port; Job = $job }
}

function Invoke-LogsTool {
    param([string]$CredentialPath, [string]$OutDir)
    & pwsh -NoProfile -File $logsTool -CredentialPath $CredentialPath -OutDir $OutDir -RequireValidCertificate | Out-Host
    return $LASTEXITCODE
}

function Invoke-DeployTool {
    param([string]$CredentialPath, [string]$ArtifactDir)
    $output = & pwsh -NoProfile -File $deployTool -ArtifactDir $ArtifactDir -CredentialsPath $CredentialPath -Require 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Invoke-RecursiveLocalStateMock {
    param([ValidateSet('success', 'traversal', 'depth')][string]$Mode, [string]$Destination)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($deployTool, [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-DevicePortalLocalState' }, $true)
    Invoke-Expression $definition.Extent.Text
    $script:localStateMode = $Mode
    function global:Invoke-RestMethod {
        param([string]$Uri, [Parameter(ValueFromRemainingArguments = $true)]$Unused)
        $query = [Web.HttpUtility]::ParseQueryString(([Uri]$Uri).Query)
        $path = $query['path']
        if ($script:localStateMode -eq 'traversal') { return [pscustomobject]@{ Items = @([pscustomobject]@{ Name = '..'; Type = '16' }) } }
        if ($script:localStateMode -eq 'depth') {
            $depth = ([regex]::Matches($path, '\\d')).Count
            if ($depth -lt 33) { return [pscustomobject]@{ Items = @([pscustomobject]@{ Name = 'd'; Type = 16 }) } }
            return [pscustomobject]@{ Items = @() }
        }
        switch ($path) {
            '\LocalState' { return [pscustomobject]@{ Items = @([pscustomobject]@{ Name = 'root.log'; Type = 0 }, [pscustomobject]@{ Name = 'nested'; Type = '16' }, [pscustomobject]@{ Name = 'empty'; Type = 16 }) } }
            '\LocalState\nested' { return [pscustomobject]@{ Items = @([pscustomobject]@{ Name = 'deep.log'; Type = 0 }) } }
            '\LocalState\empty' { return [pscustomobject]@{ Items = @() } }
            default { throw "Unexpected mocked LocalState path: $path" }
        }
    }
    function global:Invoke-WebRequest {
        param([string]$Uri, [string]$OutFile, [Parameter(ValueFromRemainingArguments = $true)]$Unused)
        Set-Content -LiteralPath $OutFile -Value "mock:$Uri"
        return [pscustomobject]@{ StatusCode = 200 }
    }
    try {
        $session = [pscustomobject]@{ BaseUri = 'http://mock'; Session = $null; CsrfToken = 'mock' }
        return @(Save-DevicePortalLocalState -DpSession $session -SkipCertCheck:$false -PackageFullName 'Moonlight_mock' -DestinationDir $Destination)
    } finally {
        Remove-Item Function:\global:Invoke-RestMethod -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\global:Invoke-WebRequest -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\Save-DevicePortalLocalState -Force -ErrorAction SilentlyContinue
    }
}

try {
    $parseErrors = @()
    [System.Management.Automation.Language.Parser]::ParseFile($logsTool, [ref]$null, [ref]$parseErrors) | Out-Null
    Assert-That ($parseErrors.Count -eq 0) 'xbox-logs.ps1 did not parse.'
    $parseErrors = @()
    [System.Management.Automation.Language.Parser]::ParseFile($deployTool, [ref]$null, [ref]$parseErrors) | Out-Null
    Assert-That ($parseErrors.Count -eq 0) 'xbox-deploy.ps1 did not parse.'

    $missingOut = Join-Path $work 'missing'
    Assert-That ((Invoke-LogsTool (Join-Path $work 'absent.json') $missingOut) -eq 0) 'Missing credentials must soft-skip.'
    $missing = Get-Content -Raw (Join-Path $missingOut 'logs-summary.json') | ConvertFrom-Json
    Assert-That ($missing.skipped -and $missing.reason -eq 'no credentials configured') 'Missing credential summary is incorrect.'

    $success = Start-MockPortal success
    $successOut = Join-Path $work 'success'
    $successCred = Join-Path $work 'success.json'
    Set-Content -LiteralPath $successCred -Value "{`"consoleAddress`":`"http://127.0.0.1:$($success.Port)`",`"username`":`"mock-user`",`"password`":`"mock-password`"}"
    Assert-That ((Invoke-LogsTool $successCred $successOut) -eq 0) 'Mock list/pull must succeed.'
    Wait-Job $success.Job | Out-Null; Receive-Job $success.Job | Out-Null
    $successSummary = Get-Content -Raw (Join-Path $successOut 'logs-summary.json') | ConvertFrom-Json
    Assert-That ($successSummary.files.Count -eq 2) 'Directory entries must not be downloaded.'
    Assert-That (-not (Test-Path (Join-Path $successOut 'nested'))) 'Directory traversal must not create nested output.'
    Assert-That ($successSummary.logPath -eq '\logs') 'The primary log root must be recorded.'
    Assert-That ($successSummary.logPathFindings[0].found -and $successSummary.logPathFindings[0].fileCount -eq 0) 'An empty LocalState root must be recorded before falling back.'

    $evil = Start-MockPortal evil
    $evilOut = Join-Path $work 'evil'
    $evilCred = Join-Path $work 'evil.json'
    Set-Content -LiteralPath $evilCred -Value "{`"consoleAddress`":`"http://127.0.0.1:$($evil.Port)`",`"username`":`"mock-user`",`"password`":`"mock-password`"}"
    Assert-That ((Invoke-LogsTool $evilCred $evilOut) -ne 0) 'Traversal-shaped remote names must fail.'
    Wait-Job $evil.Job | Out-Null; Receive-Job $evil.Job | Out-Null
    Assert-That (-not (Test-Path (Join-Path $work 'escape.log'))) 'Remote file names must not escape OutDir.'

    $failure = Start-MockPortal failure
    $failureOut = Join-Path $work 'failure'
    $failureCred = Join-Path $work 'failure.json'
    Set-Content -LiteralPath $failureCred -Value "{`"consoleAddress`":`"http://127.0.0.1:$($failure.Port)`",`"username`":`"mock-user`",`"password`":`"mock-password`"}"
    Assert-That ((Invoke-LogsTool $failureCred $failureOut) -ne 0) 'Portal failures must be non-zero.'
    Wait-Job $failure.Job | Out-Null; Receive-Job $failure.Job | Out-Null
    $failureSummary = Get-Content -Raw (Join-Path $failureOut 'logs-summary.json') | ConvertFrom-Json
    Assert-That ($failureSummary.error -match 'HTTP 500') 'Failure summary must retain the HTTP status.'

    $badCredentials = Join-Path $work 'malformed.json'
    Set-Content -LiteralPath $badCredentials -Value '{"consoleAddress":"fixture-secret-should-not-appear'
    Assert-That ((Invoke-LogsTool $badCredentials (Join-Path $work 'malformed')) -ne 0) 'Malformed credentials must fail.'
    $malformedSummary = Get-Content -Raw (Join-Path $work 'malformed\logs-summary.json')
    Assert-That ($malformedSummary -notmatch 'fixture-secret-should-not-appear') 'Malformed JSON diagnostics exposed credential-shaped content.'

    $artifactDir = Join-Path $work 'deploy-artifact'
    New-Item -ItemType Directory -Path $artifactDir | Out-Null
    Set-Content -LiteralPath (Join-Path $artifactDir 'mock.msix') -Value ''
    $missingDeployFields = Join-Path $work 'deploy-missing-fields.json'
    Set-Content -LiteralPath $missingDeployFields -Value '{"consoleAddress":"https://example.invalid"}'
    $missingDeployResult = Invoke-DeployTool $missingDeployFields $artifactDir
    Assert-That ($missingDeployResult.ExitCode -ne 0 -and $missingDeployResult.Output -match "missing a 'password' field") 'Deploy credential reads must tolerate absent optional fields under StrictMode.'
    $malformedDeploy = Join-Path $work 'deploy-malformed.json'
    Set-Content -LiteralPath $malformedDeploy -Value '{"password":"deploy-fixture-secret-should-not-appear'
    $malformedDeployResult = Invoke-DeployTool $malformedDeploy $artifactDir
    Assert-That ($malformedDeployResult.ExitCode -ne 0 -and $malformedDeployResult.Output -notmatch 'deploy-fixture-secret-should-not-appear') 'Deploy malformed JSON diagnostics exposed credential-shaped content.'

    $recursiveOut = Join-Path $work 'recursive-localstate'
    $recursiveFiles = Invoke-RecursiveLocalStateMock success $recursiveOut
    Assert-That ($recursiveFiles.Count -eq 2) 'Recursive LocalState pull must include root and nested files.'
    Assert-That ((Test-Path (Join-Path $recursiveOut 'nested\deep.log')) -and (Test-Path (Join-Path $recursiveOut 'empty'))) 'Recursive LocalState pull must retain nested and empty folders.'
    $traversalError = $null
    try { Invoke-RecursiveLocalStateMock traversal (Join-Path $work 'recursive-traversal') | Out-Null } catch { $traversalError = $_ }
    Assert-That ($null -ne $traversalError -and $traversalError.Exception.Message -match 'not a plain Windows file name') 'Recursive LocalState pull must reject dot-segment directories.'
    $depthError = $null
    try { Invoke-RecursiveLocalStateMock depth (Join-Path $work 'recursive-depth') | Out-Null } catch { $depthError = $_ }
    Assert-That ($null -ne $depthError -and $depthError.Exception.Message -match 'nesting exceeds') 'Recursive LocalState pull must enforce its depth limit.'
    Write-Host 'xbox tools tests passed'
} finally {
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
