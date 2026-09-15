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
      POST /api/taskmanager/app                  - launch by package full name and AUMID
      GET  /api/filesystem/apps/files            - list LocalState files
      GET  /api/filesystem/apps/file             - download one LocalState file
      GET  /ext/screenshot                       - console screenshot (jpg)

    None of these calls are exercised in -DryRun mode.

.PARAMETER ArtifactDir
    Directory containing the built package, searched recursively: msbuild's
    /p:AppxPackageDir layout puts the .msixbundle/.msix one level down, in
    <name>_<version>_Test\, with a Dependencies tree beside it (neutral
    *.appx directly under Dependencies, then one subfolder per architecture).

.PARAMETER ConsoleArchitecture
    Which Dependencies\<arch> subfolder to install alongside the package.
    Default x64, the CPU of every Xbox One and Xbox Series console.

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
    Override the AUMID used for -Launch (PackageFamilyName!AppId). The package
    family is validated against the installed package.

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
    [ValidateSet('x64', 'x86', 'arm', 'arm64')]
    [string]$ConsoleArchitecture = 'x64',

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
    param(
        [Parameter(Mandatory)] [string]$ArtifactDir,
        [Parameter(Mandatory)] [string]$ConsoleArchitecture
    )

    if (-not (Test-Path -LiteralPath $ArtifactDir -PathType Container)) {
        throw "ArtifactDir not found or not a directory: $ArtifactDir"
    }

    # msbuild's /p:AppxPackageDir layout puts the package one level below the
    # artifact root (<name>_<version>_Test\<name>_<version>_<arch>.msixbundle)
    # with its Dependencies tree beside it, so search recursively, skip
    # anything under a Dependencies folder, and take the shallowest match.
    # The segment list is wrapped in @(): a single segment would otherwise
    # collapse to a scalar string, whose .Count Set-StrictMode rejects.
    $artifactRoot = (Get-Item -LiteralPath $ArtifactDir).FullName
    $bundle = $null
    foreach ($pattern in '*.msixbundle', '*.msix') {
        $match = Get-ChildItem -LiteralPath $ArtifactDir -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                $segments = @([System.IO.Path]::GetRelativePath($artifactRoot, $_.FullName) -split '[\\/]' | Where-Object { $_ })
                [pscustomobject]@{
                    File              = $_
                    Depth             = $segments.Count
                    UnderDependencies = ($segments -contains 'Dependencies')
                }
            } |
            Where-Object { -not $_.UnderDependencies } |
            Sort-Object Depth, { $_.File.FullName } |
            Select-Object -First 1
        if ($match) {
            $bundle = $match.File
            break
        }
    }
    if (-not $bundle) {
        throw "No .msixbundle or .msix package found under $ArtifactDir"
    }

    # Dependencies live beside the package, read the way Add-AppDevPackage.ps1
    # in that same folder reads them: architecture-neutral packages directly
    # under Dependencies plus the one subfolder matching the console's CPU.
    # The other architecture folders are never applicable to the console.
    $dependencies = @()
    $depDir = Join-Path $bundle.DirectoryName 'Dependencies'
    if (Test-Path -LiteralPath $depDir -PathType Container) {
        $dependencyDirs = @($depDir)
        $archDir = Join-Path $depDir $ConsoleArchitecture
        if (Test-Path -LiteralPath $archDir -PathType Container) {
            $dependencyDirs += $archDir
        }
        $dependencies = @(
            foreach ($dir in $dependencyDirs) {
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.appx', '.msix' }
            }
        )
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
            $raw = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            # Parser diagnostics may echo input content. Credential files are secret.
            throw "Failed to parse credentials file at $CredentialsPath as JSON."
        }

        $getField = {
            param($Object, [string]$Name)
            if ($null -eq $Object) { return $null }
            $property = $Object.PSObject.Properties[$Name]
            if ($property) { return $property.Value }
            return $null
        }
        $addr = if ($ConsoleAddress) { $ConsoleAddress } else { & $getField $raw 'consoleAddress' }
        $user = if ($Username) { $Username } else { & $getField $raw 'username' }
        $securePass = $Password
        if (-not $securePass) {
            $plainPass = & $getField $raw 'password'
            if (-not $plainPass) {
                throw "Credentials file $CredentialsPath is missing a 'password' field."
            }
            # Converted straight to SecureString; the plaintext field on $raw
            # is never logged and $raw goes out of scope at the end of this
            # function.
            $securePass = ConvertTo-SecureString -String ([string]$plainPass) -AsPlainText -Force
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
    # HttpClient does not inherit Invoke-WebRequest's WebRequestSession. Keep
    # its authenticated CSRF cookie paired with the CSRF header below.
    $handler.CookieContainer = $DpSession.Session.Cookies
    if ($SkipCertCheck) {
        # A scriptblock callback can run on an HttpClient worker without a
        # PowerShell runspace. Use the framework delegate instead.
        $handler.ServerCertificateCustomValidationCallback = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
    }

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $client.DefaultRequestHeaders.Add('X-CSRF-Token', $DpSession.CsrfToken)

    $content = $null
    $streams = [System.Collections.Generic.List[System.IO.Stream]]::new()
    try {
        $content = [System.Net.Http.MultipartFormDataContent]::new()

        # Framework dependencies use their original filenames. Device Portal
        # reserves a .opt suffix for optional related packages only.
        $uploadEntries = @(
            [pscustomobject]@{ File = $Package; UploadName = $Package.Name }
        )
        foreach ($dep in @($Dependencies)) {
            $uploadEntries += [pscustomobject]@{ File = $dep; UploadName = $dep.Name }
        }
        foreach ($entry in $uploadEntries) {
            $fs = [System.IO.File]::OpenRead($entry.File.FullName)
            $streams.Add($fs)
            $sc = [System.Net.Http.StreamContent]::new($fs)
            $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
            $content.Add($sc, $entry.UploadName, $entry.UploadName)
            # Device Portal's multipart parser requires quoted form-data name
            # and filename parameters, including for token-safe filenames.
            $quotedUploadName = '"' + $entry.UploadName + '"'
            $sc.Headers.ContentDisposition.Name = $quotedUploadName
            $sc.Headers.ContentDisposition.FileName = $quotedUploadName
        }

        # Windows Device Portal requires the uploaded main package's filename
        # in the package query parameter as well as the multipart payload.
        $installUri = "$($DpSession.BaseUri)/api/app/packagemanager/package?package=$([Uri]::EscapeDataString($Package.Name))"
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

function Resolve-DevicePortalPackageFamilyName {
    param([Parameter(Mandatory)] [string]$PackageFullName)

    # PackageFullName is Name_Version_Architecture_ResourceId_PublisherId.
    # The empty ResourceId in a normal package produces the double underscore.
    $parts = $PackageFullName -split '_', 5
    if ($parts.Count -ne 5 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[4])) {
        throw "Installed package returned an invalid PackageFullName: '$PackageFullName'."
    }
    return "$($parts[0])_$($parts[4])"
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
    $derivedFamily = Resolve-DevicePortalPackageFamilyName -PackageFullName ([string]$match.PackageFullName)
    $reportedFamilyProperty = $match.PSObject.Properties['PackageFamilyName']
    if ($reportedFamilyProperty -and $reportedFamilyProperty.Value -and $reportedFamilyProperty.Value -ne $derivedFamily) {
        Write-DeployLog "Device Portal reported PackageFamilyName '$($reportedFamilyProperty.Value)'; using '$derivedFamily' derived from PackageFullName." -Level Warn
    }
    $match | Add-Member -NotePropertyName PackageFamilyName -NotePropertyValue $derivedFamily -Force
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

    # Xbox Device Portal reports PackageRelativeId as a full AUMID. Use the
    # normalized package family plus manifest Application Id for appid.
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

    function Get-PortalItemField {
        param($Item, [string]$Name)
        if ($null -eq $Item) { return $null }
        $property = $Item.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
        return $null
    }
    function Test-PortalDirectory {
        param($Item)
        $type = Get-PortalItemField $Item 'Type'
        if ($type -is [string] -and ($type -eq 'Folder' -or $type -eq 'Directory')) { return $true }
        $number = $type -as [int]
        return $null -ne $number -and (($number -band 16) -ne 0)
    }
    function Assert-PortalChildName {
        param([string]$Name)
        if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in '.', '..' -or $Name.EndsWith('.') -or $Name.EndsWith(' ') -or [IO.Path]::GetFileName($Name) -ne $Name -or $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Refusing to write remote LocalState file name '$Name': not a plain Windows file name." }
        $stem = [IO.Path]::GetFileNameWithoutExtension($Name).TrimEnd('.', ' ').ToUpperInvariant()
        if ($stem -in @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')) { throw "Refusing reserved Windows LocalState file name '$Name'." }
    }
    function Assert-NoReparsePathComponent {
        param([string]$Path)
        $fullPath = [IO.Path]::GetFullPath($Path); $root = [IO.Path]::GetPathRoot($fullPath); $current = $root
        foreach ($segment in $fullPath.Substring($root.Length).TrimStart('\', '/') -split '[\\/]') {
            if (-not $segment) { continue }; $current = Join-Path $current $segment
            if (Test-Path -LiteralPath $current) { $item = Get-Item -LiteralPath $current -Force; if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing reparse-point path component: $current" } }
        }
        return $fullPath
    }
    function Resolve-PortalChildDestination {
        param([string]$Directory, [string]$Name)
        Assert-PortalChildName $Name
        $root = Assert-NoReparsePathComponent $Directory
        $destination = [IO.Path]::GetFullPath((Join-Path $root $Name)); $prefix = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing remote LocalState file name '$Name': destination escapes output directory." }
        Assert-NoReparsePathComponent $destination | Out-Null
        return $destination
    }
    function Pull-LocalStateDirectory {
        param([string]$RemotePath, [string]$LocalPath, [int]$Depth)
        if ($Depth -gt 32) { throw "LocalState directory nesting exceeds the safe limit at $RemotePath." }
        $listUri = "$($DpSession.BaseUri)/api/filesystem/apps/files?knownfolderid=LocalAppData&packagefullname=$([Uri]::EscapeDataString($PackageFullName))&path=$([Uri]::EscapeDataString($RemotePath))"
        $params = @{
            Uri = $listUri; WebSession = $DpSession.Session; Method = 'Get'; Headers = @{ 'X-CSRF-Token' = $DpSession.CsrfToken }
            ErrorAction = 'Stop'; TimeoutSec = 30
        }
        if ($SkipCertCheck) { $params['SkipCertificateCheck'] = $true }
        $response = Invoke-RestMethod @params
        $items = @(Get-PortalItemField $response 'Items')
        $results = @()
        foreach ($item in $items) {
            $name = [string](Get-PortalItemField $item 'Name')
            if (Test-PortalDirectory $item) {
                $childRemotePath = "$RemotePath\$name"
                $childLocalPath = Resolve-PortalChildDestination $LocalPath $name
                New-Item -ItemType Directory -Path $childLocalPath -Force | Out-Null
                $results += @(Pull-LocalStateDirectory $childRemotePath $childLocalPath ($Depth + 1))
                continue
            }
            $fileUri = "$($DpSession.BaseUri)/api/filesystem/apps/file?knownfolderid=LocalAppData&packagefullname=$([Uri]::EscapeDataString($PackageFullName))&filename=$([Uri]::EscapeDataString($name))&path=$([Uri]::EscapeDataString($RemotePath))"
            $dest = Resolve-PortalChildDestination $LocalPath $name
            $partial = "$dest.partial-$([guid]::NewGuid().ToString('N'))"
            $download = @{
                Uri = $fileUri; WebSession = $DpSession.Session; Method = 'Get'; Headers = @{ 'X-CSRF-Token' = $DpSession.CsrfToken }
                OutFile = $partial; ErrorAction = 'Stop'; TimeoutSec = 60
            }
            if ($SkipCertCheck) { $download['SkipCertificateCheck'] = $true }
            try { Invoke-WebRequest @download | Out-Null; Move-Item -LiteralPath $partial -Destination $dest -Force }
            finally { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
            $results += $dest
        }
        return $results
    }

    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    $pulled = @(Pull-LocalStateDirectory '\LocalState' $DestinationDir 0)
    if ($pulled.Count -eq 0) { Write-DeployLog 'No LocalState files found to pull.' -Level Warn }
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
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Summary,
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
    $artifact = Resolve-DeployArtifact -ArtifactDir $ArtifactDir -ConsoleArchitecture $ConsoleArchitecture
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

    Write-DeployLog "Authenticating to Device Portal at $($dpCred.ConsoleAddress)..."
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
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[1]) -or $parts[0] -ne $pkgInfo.PackageFamilyName) {
            throw "AppUserModelId must use the installed package family '$($pkgInfo.PackageFamilyName)' followed by '!<AppId>'."
        }
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
