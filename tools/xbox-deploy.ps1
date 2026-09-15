#Requires -Version 7
<#
.SYNOPSIS
    Deploys a built Moonlight UWP package to an Xbox Dev Mode console over the
    Windows Device Portal (WDP) REST API.

.DESCRIPTION
    Takes the output of an MSBuild AppX build (a .msixbundle/.msix plus a
    Dependencies\<arch>\*.appx tree), installs it on a paired Xbox Dev Mode
    console, and optionally launches it, pulls LocalState files, and grabs a
    screenshot. Writes a JSON summary of what happened.

    Credentials (console address, username, password) are resolved in this
    order: explicit parameters, then a local JSON file (-CredentialsPath,
    default "$HOME/.xbox-deploy/credentials.json"):

        {
          "consoleAddress": "https://192.168.1.50:11443",
          "username": "xboxuser",
          "password": "xboxpassword"
        }

    If neither source resolves, the script SOFT-FAILS: it logs a warning and
    exits 0 without making any network call, so a CI pipeline without a
    configured Xbox console does not fail the build. Pass -Require to make
    missing credentials a hard (non-zero exit) failure instead.

    The Device Portal password is never written to the console, to logs, or
    to the summary JSON. It is kept as a SecureString end to end and handed
    to HttpClient via the SecureString overload of NetworkCredential.

    WDP endpoints used (documented Windows/Xbox Device Portal REST API):
      GET  /                                    - CSRF-Token cookie bootstrap
      POST /api/app/packagemanager/package       - multipart package install
      GET  /api/app/packagemanager/state         - install progress/result
      GET  /api/app/packagemanager/packages      - installed package lookup
      POST /api/taskmanager/app                  - launch by AUMID
      GET  /api/filesystem/apps/files            - list LocalState files
      GET  /api/filesystem/apps/file             - download one LocalState file
      GET  /ext/screenshot                       - console screenshot (jpg)

    None of these calls are exercised in -DryRun mode.

.PARAMETER ArtifactDir
    Directory containing the built package: a .msixbundle/.msix at its root
    and, optionally, a Dependencies\<arch>\*.appx tree (msbuild's
    /p:AppxPackageDir layout).

.PARAMETER ConsoleAddress
    Device Portal base URL, e.g. https://192.168.1.50:11443. Overrides the
    credentials file when supplied together with -Username and -Password.

.PARAMETER Username
    Device Portal username. See -ConsoleAddress.

.PARAMETER Password
    Device Portal password, as a SecureString. See -ConsoleAddress.

.PARAMETER CredentialsPath
    Path to the JSON credentials file. Default: $HOME/.xbox-deploy/credentials.json

.PARAMETER Require
    Make missing/incomplete credentials a terminating error instead of a
    soft-fail (exit 0, no deploy).

.PARAMETER DryRun
    Resolve and validate the artifact and print the plan, but make no
    network call and require no credentials.

.PARAMETER Launch
    Launch the app after a successful install.

.PARAMETER AppUserModelId
    Override the AUMID used for -Launch (PackageFamilyName!AppId). Default is
    computed from the installed package's PackageFamilyName plus the app id
    "App" from Package.appxmanifest.

.PARAMETER PullLocalState
    Download every file under the app's LocalState folder to
    <OutputDir>\LocalState\.

.PARAMETER Screenshot
    Save a console screenshot to <OutputDir>\screenshot.jpg.

.PARAMETER OutputDir
    Where to write deploy-summary.json, pulled LocalState files, and the
    screenshot. Default: <ArtifactDir>\deploy-out.

.PARAMETER RequireValidCertificate
    Do not skip TLS certificate validation. Dev Mode consoles normally serve
    a self-signed certificate, so certificate checking is skipped by default.

.PARAMETER InstallPollIntervalSec
    Seconds between install-state polls. Default 3.

.PARAMETER InstallPollTimeoutSec
    Seconds to wait for install completion before failing. Default 300.

.PARAMETER RequestTimeoutSec
    Per-request timeout in seconds for auth/install/launch calls. Default 60.

.EXAMPLE
    pwsh -File tools/xbox-deploy.ps1 -ArtifactDir output -DryRun

.EXAMPLE
    pwsh -File tools/xbox-deploy.ps1 -ArtifactDir output -Launch -Screenshot -PullLocalState
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ArtifactDir,

    [string]$ConsoleAddress,
    [string]$Username,
    [SecureString]$Password,
    [string]$CredentialsPath = (Join-Path $HOME '.xbox-deploy/credentials.json'),

    [switch]$Require,
    [switch]$DryRun,
    [switch]$Launch,
    [string]$AppUserModelId,
    [switch]$PullLocalState,
    [switch]$Screenshot,
    [string]$OutputDir,
    [switch]$RequireValidCertificate,

    [int]$InstallPollIntervalSec = 3,
    [int]$InstallPollTimeoutSec = 300,
    [int]$RequestTimeoutSec = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Source of truth: Package.appxmanifest <Identity Name=...> and
# <Application Id="App" ...>. Kept as literals rather than parsed out of the
# manifest so a manifest edit cannot silently change deploy behavior.
$script:PackageIdentityName = '50497EliaZammuto.MoonlightUWP'
$script:ManifestAppId = 'App'
$script:MaxErrorBodyChars = 2000

function Write-DeployLog {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')]
        [string]$Level = 'Info'
    )
    $ts = (Get-Date).ToString('HH:mm:ss')
    $prefix = "[$ts] [$Level]"
    switch ($Level) {
        'Warn'  { Write-Warning "$prefix $Message" }
        'Error' { Write-Error "$prefix $Message" -ErrorAction Continue }
        default { Write-Host "$prefix $Message" }
    }
}

function ConvertTo-TruncatedErrorBody {
    param([string]$Body)
    if ([string]::IsNullOrEmpty($Body)) { return '' }
    if ($Body.Length -le $script:MaxErrorBodyChars) { return $Body }
    return $Body.Substring(0, $script:MaxErrorBodyChars) + "... [truncated, $($Body.Length) chars total]"
}

function Resolve-DeployArtifact {
    param([Parameter(Mandatory)] [string]$ArtifactDir)

    if (-not (Test-Path -LiteralPath $ArtifactDir -PathType Container)) {
        throw "ArtifactDir not found or not a directory: $ArtifactDir"
    }

    $bundle = Get-ChildItem -LiteralPath $ArtifactDir -Filter '*.msixbundle' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $bundle) {
        $bundle = Get-ChildItem -LiteralPath $ArtifactDir -Filter '*.msix' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if (-not $bundle) {
        throw "No .msixbundle or .msix package found directly under $ArtifactDir"
    }

    $dependencies = @()
    $depDir = Join-Path $ArtifactDir 'Dependencies'
    if (Test-Path -LiteralPath $depDir -PathType Container) {
        $dependencies = @(Get-ChildItem -LiteralPath $depDir -Recurse -File -Include '*.appx', '*.msix' -ErrorAction SilentlyContinue)
    }

    [pscustomobject]@{
        Package      = $bundle
        Dependencies = $dependencies
    }
}

function Resolve-DeployCredential {
    param(
        [string]$ConsoleAddress,
        [string]$Username,
        [SecureString]$Password,
        [Parameter(Mandatory)] [string]$CredentialsPath,
        [switch]$Require
    )

    if ($ConsoleAddress -and $Username -and $Password) {
        return [pscustomobject]@{
            ConsoleAddress = $ConsoleAddress.TrimEnd('/')
            Username       = $Username
            Password       = $Password
            Source         = 'parameters'
        }
    }

    if (Test-Path -LiteralPath $CredentialsPath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json
        } catch {
            throw "Failed to parse credentials file at $CredentialsPath as JSON: $($_.Exception.Message)"
        }

        $addr = if ($ConsoleAddress) { $ConsoleAddress } else { $raw.consoleAddress }
        $user = if ($Username) { $Username } else { $raw.username }
        $securePass = $Password
        if (-not $securePass) {
            if (-not $raw.password) {
                throw "Credentials file $CredentialsPath is missing a 'password' field."
            }
            # Converted straight to SecureString; the plaintext field on $raw
            # is never logged and $raw goes out of scope at the end of this
            # function.
            $securePass = ConvertTo-SecureString -String $raw.password -AsPlainText -Force
        }

        if (-not $addr -or -not $user -or -not $securePass) {
            throw "Credentials file $CredentialsPath is missing consoleAddress, username, or password."
        }

        return [pscustomobject]@{
            ConsoleAddress = $addr.TrimEnd('/')
            Username       = $user
            Password       = $securePass
            Source         = $CredentialsPath
        }
    }

    if ($Require) {
        throw "No Xbox Device Portal credentials supplied (parameters) and none found at $CredentialsPath (-Require was specified)."
    }

    return $null
}

function New-DevicePortalSession {
    param(
        [Parameter(Mandatory)] [string]$ConsoleAddress,
        [Parameter(Mandatory)] [string]$Username,
        [Parameter(Mandatory)] [SecureString]$Password,
        [bool]$SkipCertCheck,
        [int]$TimeoutSec
    )

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $cred = New-Object System.Management.Automation.PSCredential($Username, $Password)

    $params = @{
        Uri            = $ConsoleAddress
        WebSession     = $session
        Credential     = $cred
        Authentication = 'Basic'
        Method         = 'Get'
        TimeoutSec     = $TimeoutSec
        ErrorAction    = 'Stop'
    }
    if ($SkipCertCheck) { $params['SkipCertificateCheck'] = $true }

    try {
        Invoke-WebRequest @params | Out-Null
    } catch {
        $body = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $body = $_.ErrorDetails.Message }
        throw "Failed to authenticate to Device Portal at $ConsoleAddress : $($_.Exception.Message) $(ConvertTo-TruncatedErrorBody $body)"
    }

    $csrfCookie = $session.Cookies.GetCookies([Uri]$ConsoleAddress) | Where-Object { $_.Name -eq 'CSRF-Token' }
    if (-not $csrfCookie) {
        throw "Device Portal at $ConsoleAddress did not return a CSRF-Token cookie; cannot proceed."
    }

    [pscustomobject]@{
        Session    = $session
        Credential = $cred
        CsrfToken  = $csrfCookie.Value
        BaseUri    = $ConsoleAddress
    }
}

function Install-DevicePortalPackage {
    param(
        [Parameter(Mandatory)] [pscustomobject]$DpSession,
        [Parameter(Mandatory)] [System.IO.FileInfo]$Package,
        [System.IO.FileInfo[]]$Dependencies,
        [bool]$SkipCertCheck,
        [int]$TimeoutSec
    )

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

    $handler = [System.Net.Http.HttpClientHandler]::new()
    # SecureString overload: the plaintext password is materialized inside
    # NetworkCredential's own internals, never assigned to a script variable.
    $handler.Credentials = [System.Net.NetworkCredential]::new($DpSession.Credential.UserName, $DpSession.Credential.Password)
    $handler.PreAuthenticate = $true
    if ($SkipCertCheck) {
        $handler.ServerCertificateCustomValidationCallback = { $true }
    }

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $client.DefaultRequestHeaders.Add('X-CSRF-Token', $DpSession.CsrfToken)

    $content = $null
    $streams = [System.Collections.Generic.List[System.IO.Stream]]::new()
    try {
        $content = [System.Net.Http.MultipartFormDataContent]::new()

        # Dependency files are uploaded with a .opt suffix appended to their
        # filename. The main bundle keeps its own filename unchanged.
        $uploadEntries = @(
            [pscustomobject]@{ File = $Package; UploadName = $Package.Name }
        )
        foreach ($dep in @($Dependencies)) {
            $uploadEntries += [pscustomobject]@{ File = $dep; UploadName = "$($dep.Name).opt" }
        }
        foreach ($entry in $uploadEntries) {
            $fs = [System.IO.File]::OpenRead($entry.File.FullName)
            $streams.Add($fs)
            $sc = [System.Net.Http.StreamContent]::new($fs)
            $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
            $content.Add($sc, $entry.UploadName, $entry.UploadName)
        }

        $installUri = "$($DpSession.BaseUri)/api/app/packagemanager/package"
        $response = $client.PostAsync($installUri, $content).GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "Install request failed: HTTP $([int]$response.StatusCode) $($response.ReasonPhrase). $(ConvertTo-TruncatedErrorBody $body)"
        }

        Write-DeployLog "Install request accepted (HTTP $([int]$response.StatusCode))."
    }
    finally {
        foreach ($s in $streams) { $s.Dispose() }
        if ($content) { $content.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Wait-DevicePortalInstall {
    param(
        [Parameter(Mandatory)] [pscustomobject]$DpSession,
        [bool]$SkipCertCheck,
        [int]$PollIntervalSec,
        [int]$PollTimeoutSec
    )

    $deadline = (Get-Date).AddSeconds($PollTimeoutSec)
    $stateUri = "$($DpSession.BaseUri)/api/app/packagemanager/state"
    $lastObservedState = 'no response received yet'

    while ($true) {
        $params = @{
            Uri         = $stateUri
            WebSession  = $DpSession.Session
            Method      = 'Get'
            Headers     = @{ 'X-CSRF-Token' = $DpSession.CsrfToken }
            ErrorAction = 'Stop'
            TimeoutSec  = 30
        }
        if ($SkipCertCheck) { $params['SkipCertificateCheck'] = $true }

        $handledAsInProgress = $false
        try {
            $resp = Invoke-WebRequest @params
            $json = $null
            if ($resp.Content) { try { $json = $resp.Content | ConvertFrom-Json } catch {} }

            if ($json -and ($json.PSObject.Properties.Name -contains 'Success')) {
                if ($json.Success -eq $true) {
                    Write-DeployLog 'Install completed successfully.'
                    return
                } else {
                    throw "Install reported failure: $($json.Reason)"
                }
            }
            $lastObservedState = 'HTTP 200 with no terminal result yet'
            Write-DeployLog 'Install still in progress (state endpoint returned 200 with no terminal result yet)...'
            $handledAsInProgress = $true
        } catch [System.Net.Http.HttpRequestException] {
            throw
        } catch {
            $statusCode = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($statusCode -eq 400) {
                $lastObservedState = 'HTTP 400 (in progress)'
                Write-DeployLog 'Install still in progress (state endpoint returned 400)...'
                $handledAsInProgress = $true
            } else {
                $body = ''
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $body = $_.ErrorDetails.Message }
                throw "Failed to poll install state: $($_.Exception.Message) $(ConvertTo-TruncatedErrorBody $body)"
            }
        }

        if (-not $handledAsInProgress) { return }

        if ((Get-Date) -ge $deadline) {
            throw "Timed out after $PollTimeoutSec seconds waiting for install to complete. Last observed state: $lastObservedState."
        }
        Start-Sleep -Seconds $PollIntervalSec
    }
}

function Get-DevicePortalInstalledPackage {
    param(
        [Parameter(Mandatory)] [pscustomobject]$DpSession,
        [bool]$SkipCertCheck,
        [Parameter(Mandatory)] [string]$IdentityName
    )

    $params = @{
        Uri         = "$($DpSession.BaseUri)/api/app/packagemanager/packages"
        WebSession  = $DpSession.Session
        Method      = 'Get'
        Headers     = @{ 'X-CSRF-Token' = $DpSession.CsrfToken }
        ErrorAction = 'Stop'
        TimeoutSec  = 30
    }
    if ($SkipCertCheck) { $params['SkipCertificateCheck'] = $true }

    $resp = Invoke-RestMethod @params
    $match = $resp.InstalledPackages |
        Where-Object { $_.Name -eq $IdentityName -or $_.PackageFamilyName -like "$IdentityName*" } |
        Select-Object -First 1
    if (-not $match) {
        throw "Could not find an installed package matching identity '$IdentityName' after install."
    }
    return $match
}

function Start-DevicePortalApp {
    param(
        [Parameter(Mandatory)] [pscustomobject]$DpSession,
        [bool]$SkipCertCheck,
        [Parameter(Mandatory)] [string]$PackageFamilyName,
        [Parameter(Mandatory)] [string]$PackageFullName,
        [Parameter(Mandatory)] [string]$AppId
    )

    # Device Portal's package launch parameter expects the package full name,
    # not the package family name. The appid parameter still uses the family
    # name as part of the PRAID (PackageFamilyName!AppId).
    $aumidB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$PackageFamilyName!$AppId"))
    $pfnB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PackageFullName))

    $uri = "$($DpSession.BaseUri)/api/taskmanager/app?appid=$aumidB64&package=$pfnB64"
    $params = @{
        Uri         = $uri
        WebSession  = $DpSession.Session
        Method      = 'Post'
        Headers     = @{ 'X-CSRF-Token' = $DpSession.CsrfToken }
        ErrorAction = 'Stop'
        TimeoutSec  = 30
    }
    if ($SkipCertCheck) { $params['SkipCertificateCheck'] = $true }

    try {
        Invoke-WebRequest @params | Out-Null
        Write-DeployLog "Launched $PackageFamilyName!$AppId."
    } catch {
        $body = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $body = $_.ErrorDetails.Message }
        throw "Failed to launch app: $($_.Exception.Message) $(ConvertTo-TruncatedErrorBody $body)"
    }
}

function Save-DevicePortalLocalState {
    param(
        [Parameter(Mandatory)] [pscustomobject]$DpSession,
        [bool]$SkipCertCheck,
        [Parameter(Mandatory)] [string]$PackageFullName,
        [Parameter(Mandatory)] [string]$DestinationDir
    )

    $listUri = "$($DpSession.BaseUri)/api/filesystem/apps/files?knownfolderid=LocalAppData&packagefullname=$([Uri]::EscapeDataString($PackageFullName))&path=%5CLocalState"
    $params = @{
        Uri         = $listUri
        WebSession  = $DpSession.Session
        Method      = 'Get'
        Headers     = @{ 'X-CSRF-Token' = $DpSession.CsrfToken }
        ErrorAction = 'Stop'
        TimeoutSec  = 30
    }
    if ($SkipCertCheck) { $params['SkipCertificateCheck'] = $true }

    $resp = Invoke-RestMethod @params
    $files = @($resp.Items | Where-Object { -not $_.Type -or $_.Type -ne 'Folder' })

    if (-not $files -or $files.Count -eq 0) {
        Write-DeployLog 'No LocalState files found to pull.' -Level Warn
        return @()
    }

    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    $pulled = @()

    foreach ($f in $files) {
        $fileUri = "$($DpSession.BaseUri)/api/filesystem/apps/file?knownfolderid=LocalAppData&packagefullname=$([Uri]::EscapeDataString($PackageFullName))&filename=$([Uri]::EscapeDataString($f.Name))&path=%5CLocalState"
        $dest = Join-Path $DestinationDir $f.Name
        $dlParams = @{
            Uri         = $fileUri
            WebSession  = $DpSession.Session
            Method      = 'Get'
            Headers     = @{ 'X-CSRF-Token' = $DpSession.CsrfToken }
            OutFile     = $dest
            ErrorAction = 'Stop'
            TimeoutSec  = 60
        }
        if ($SkipCertCheck) { $dlParams['SkipCertificateCheck'] = $true }
        Invoke-WebRequest @dlParams | Out-Null
        $pulled += $dest
    }

    return $pulled
}

function Save-DevicePortalScreenshot {
    param(
        [Parameter(Mandatory)] [pscustomobject]$DpSession,
        [bool]$SkipCertCheck,
        [Parameter(Mandatory)] [string]$DestinationPath
    )

    $params = @{
        Uri         = "$($DpSession.BaseUri)/ext/screenshot"
        WebSession  = $DpSession.Session
        Method      = 'Get'
        Headers     = @{ 'X-CSRF-Token' = $DpSession.CsrfToken }
        OutFile     = $DestinationPath
        ErrorAction = 'Stop'
        TimeoutSec  = 30
    }
    if ($SkipCertCheck) { $params['SkipCertificateCheck'] = $true }

    Invoke-WebRequest @params | Out-Null
    return $DestinationPath
}

function Write-DeploySummary {
    param(
        [Parameter(Mandatory)] [hashtable]$Summary,
        [Parameter(Mandatory)] [string]$OutputDir
    )
    New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction SilentlyContinue | Out-Null
    $summaryPath = Join-Path $OutputDir 'deploy-summary.json'
    ([pscustomobject]$Summary) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    return $summaryPath
}

# --- Main ---------------------------------------------------------------

$startTime = Get-Date
$summary = [ordered]@{
    timestamp   = $startTime.ToString('o')
    artifactDir = $ArtifactDir
    dryRun      = [bool]$DryRun
    success     = $false
}

if (-not $OutputDir) { $OutputDir = Join-Path $ArtifactDir 'deploy-out' }

try {
    $artifact = Resolve-DeployArtifact -ArtifactDir $ArtifactDir
    $summary.package = $artifact.Package.Name
    $summary.dependencies = @($artifact.Dependencies | ForEach-Object { $_.Name })

    Write-DeployLog "Resolved package: $($artifact.Package.FullName)"
    Write-DeployLog "Resolved $($artifact.Dependencies.Count) dependency package(s)."

    if ($DryRun) {
        Write-DeployLog '--- DRY RUN: no network calls will be made ---'

        $credPreview = if ($ConsoleAddress -and $Username -and $Password) {
            'parameters'
        } elseif (Test-Path -LiteralPath $CredentialsPath -PathType Leaf) {
            "file present at $CredentialsPath (not read in dry run)"
        } else {
            "none found at $CredentialsPath"
        }
        Write-DeployLog "Would resolve credentials from: $credPreview"
        Write-DeployLog "Would install: $($artifact.Package.Name) plus $($artifact.Dependencies.Count) dependency file(s)"
        if ($Launch) { Write-DeployLog "Would launch app id '$script:ManifestAppId' after install." }
        if ($PullLocalState) { Write-DeployLog "Would pull LocalState files to $(Join-Path $OutputDir 'LocalState')" }
        if ($Screenshot) { Write-DeployLog "Would capture a screenshot to $(Join-Path $OutputDir 'screenshot.jpg')" }
        Write-DeployLog "Would write summary JSON to $(Join-Path $OutputDir 'deploy-summary.json')"

        $summary.success = $true
        $summary.note = 'dry run: no network calls were made'
        $summaryPath = Write-DeploySummary -Summary $summary -OutputDir $OutputDir
        Write-DeployLog "Dry run summary written to $summaryPath"
        exit 0
    }

    $dpCred = Resolve-DeployCredential -ConsoleAddress $ConsoleAddress -Username $Username -Password $Password -CredentialsPath $CredentialsPath -Require:$Require

    if (-not $dpCred) {
        Write-DeployLog "No Xbox Device Portal credentials configured (checked parameters and $CredentialsPath). Skipping deploy. Pass -Require to make this a hard failure." -Level Warn
        $summary.success = $true
        $summary.skipped = $true
        $summary.reason = 'no credentials configured'
        $summaryPath = Write-DeploySummary -Summary $summary -OutputDir $OutputDir
        Write-DeployLog "Summary written to $summaryPath"
        exit 0
    }

    $summary.consoleAddress = $dpCred.ConsoleAddress
    $summary.credentialSource = $dpCred.Source
    $skipCert = -not $RequireValidCertificate.IsPresent

    Write-DeployLog "Authenticating to Device Portal at $($dpCred.ConsoleAddress) as $($dpCred.Username)..."
    $dp = New-DevicePortalSession -ConsoleAddress $dpCred.ConsoleAddress -Username $dpCred.Username -Password $dpCred.Password -SkipCertCheck $skipCert -TimeoutSec $RequestTimeoutSec

    Write-DeployLog "Installing $($artifact.Package.Name)..."
    Install-DevicePortalPackage -DpSession $dp -Package $artifact.Package -Dependencies $artifact.Dependencies -SkipCertCheck $skipCert -TimeoutSec $RequestTimeoutSec

    Write-DeployLog 'Waiting for install to complete...'
    Wait-DevicePortalInstall -DpSession $dp -SkipCertCheck $skipCert -PollIntervalSec $InstallPollIntervalSec -PollTimeoutSec $InstallPollTimeoutSec

    Write-DeployLog 'Resolving installed package info...'
    $pkgInfo = Get-DevicePortalInstalledPackage -DpSession $dp -SkipCertCheck $skipCert -IdentityName $script:PackageIdentityName
    $summary.packageFullName = $pkgInfo.PackageFullName
    $summary.packageFamilyName = $pkgInfo.PackageFamilyName
    Write-DeployLog "Installed: $($pkgInfo.PackageFullName)"

    if ($Launch) {
        $aumid = if ($AppUserModelId) { $AppUserModelId } else { "$($pkgInfo.PackageFamilyName)!$script:ManifestAppId" }
        $parts = $aumid -split '!', 2
        Write-DeployLog "Launching $aumid..."
        Start-DevicePortalApp -DpSession $dp -SkipCertCheck $skipCert -PackageFamilyName $parts[0] -PackageFullName $pkgInfo.PackageFullName -AppId $parts[1]
        $summary.launched = $true
    }

    if ($PullLocalState) {
        Write-DeployLog 'Pulling LocalState files...'
        $pulled = Save-DevicePortalLocalState -DpSession $dp -SkipCertCheck $skipCert -PackageFullName $pkgInfo.PackageFullName -DestinationDir (Join-Path $OutputDir 'LocalState')
        $summary.localStateFiles = @($pulled | ForEach-Object { Split-Path $_ -Leaf })
    }

    if ($Screenshot) {
        Write-DeployLog 'Capturing screenshot...'
        $shotPath = Save-DevicePortalScreenshot -DpSession $dp -SkipCertCheck $skipCert -DestinationPath (Join-Path $OutputDir 'screenshot.jpg')
        $summary.screenshotPath = $shotPath
    }

    $summary.success = $true
}
catch {
    $summary.success = $false
    $summary.error = $_.Exception.Message
    Write-DeployLog "Deploy failed: $($_.Exception.Message)" -Level Error
    Write-DeploySummary -Summary $summary -OutputDir $OutputDir | Out-Null
    throw
}

$summary.durationSec = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$summaryPath = Write-DeploySummary -Summary $summary -OutputDir $OutputDir
Write-DeployLog "Deploy summary written to $summaryPath"
Write-DeployLog 'Deploy completed successfully.'
