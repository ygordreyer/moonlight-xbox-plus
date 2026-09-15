#Requires -Version 7
<#
.SYNOPSIS
    Downloads Moonlight log files from an Xbox Dev Mode console.

.DESCRIPTION
    This companion to xbox-deploy.ps1 uses the same local credential file.
    It only makes read requests: package lookup, directory listings, file
    downloads, and the optional screenshot request. Credentials are never
    printed or written to the summary.
#>
[CmdletBinding()]
param(
    [Alias('CredentialsPath')]
    [string]$CredentialPath = (Join-Path $HOME '.xbox-deploy/credentials.json'),
    [string]$PackageFamilyName,
    [string]$PackageFullName,
    [string]$OutDir,
    [ValidateRange(1, [int]::MaxValue)] [int]$Newest = 3,
    [switch]$All,
    [switch]$Screenshot,
    [ValidateSet('Get', 'Post')] [string]$ScreenshotMethod = 'Get',
    [string]$Summary,
    [switch]$Require,
    [switch]$RequireValidCertificate,
    [ValidateRange(1, 600)] [int]$RequestTimeoutSec = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PackageIdentityName = '50497EliaZammuto.MoonlightUWP'
$script:MaxErrorBodyChars = 2000

function Write-PullLog {
    param([string]$Message, [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info')
    $prefix = "[$((Get-Date).ToString('HH:mm:ss'))] [$Level]"
    switch ($Level) {
        'Warn' { Write-Warning "$prefix $Message" }
        'Error' { Write-Error "$prefix $Message" -ErrorAction Continue }
        default { Write-Host "$prefix $Message" }
    }
}

function Get-JsonField {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Resolve-PullCredential {
    param([Parameter(Mandatory)][string]$Path, [switch]$Require)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($Require) { throw "No Xbox Device Portal credentials found at $Path (-Require was specified)." }
        return $null
    }
    try { $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Failed to parse credentials file at $Path as JSON." }
    $address = Get-JsonField $raw 'consoleAddress'
    $username = Get-JsonField $raw 'username'
    $plainPassword = Get-JsonField $raw 'password'
    if (-not $address -or -not $username -or -not $plainPassword) {
        throw "Credentials file $Path is missing consoleAddress, username, or password."
    }
    $password = ConvertTo-SecureString -String ([string]$plainPassword) -AsPlainText -Force
    [pscustomobject]@{ BaseUri = ([string]$address).TrimEnd('/'); Username = [string]$username; Password = $password; Source = $Path }
}

function Invoke-PortalRequest {
    param(
        [Parameter(Mandatory)]$Portal,
        [Parameter(Mandatory)][string]$RelativeUri,
        [ValidateSet('Get', 'Post')][string]$Method = 'Get',
        [string]$OutFile,
        [int]$TimeoutSec = 60
    )
    $args = @{
        Uri = "$($Portal.BaseUri)$RelativeUri"; WebSession = $Portal.Session; Credential = $Portal.Credential
        Authentication = 'Basic'; Method = $Method; Headers = $Portal.Headers; TimeoutSec = $TimeoutSec
        SkipHttpErrorCheck = $true; ErrorAction = 'Stop'
    }
    if ($Portal.SkipCertCheck) { $args.SkipCertificateCheck = $true }
    $targetUri = [Uri]$Portal.BaseUri
    if ($targetUri.Scheme -eq 'http' -and $targetUri.IsLoopback) {
        # Supports the repository's local mock portal without permitting an
        # unencrypted credential exchange with a real console.
        $args.AllowUnencryptedAuthentication = $true
    }
    if ($OutFile) { $args.OutFile = $OutFile; $args.PassThru = $true }
    try { $response = Invoke-WebRequest @args }
    catch { throw "Transport failure on $($Method.ToUpperInvariant()) $RelativeUri against $($Portal.BaseUri): $($_.Exception.Message)" }
    [pscustomobject]@{ StatusCode = [int]$response.StatusCode; StatusDescription = [string]$response.StatusDescription; Response = $response; OutFile = $OutFile }
}

function Get-PortalErrorBody {
    param([Parameter(Mandatory)]$Result)
    $body = ''
    if ($Result.OutFile -and (Test-Path -LiteralPath $Result.OutFile -PathType Leaf)) {
        try { $body = Get-Content -LiteralPath $Result.OutFile -Raw } catch {}
        Remove-Item -LiteralPath $Result.OutFile -Force -ErrorAction SilentlyContinue
    } elseif ($null -ne $Result.Response.Content) {
        if ($Result.Response.Content -is [byte[]]) { $body = [Text.Encoding]::UTF8.GetString($Result.Response.Content) }
        else { $body = [string]$Result.Response.Content }
    }
    # A portal response is untrusted. It can reflect the Authorization header,
    # query parameters, or a server-side diagnostic containing credentials.
    # Keep HTTP status information but do not print response bodies by default.
    if (-not [string]::IsNullOrEmpty($body)) { return '[response body suppressed]' }
    return ''
}

function Assert-PortalSuccess {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$What)
    if ($Result.StatusCode -ge 200 -and $Result.StatusCode -lt 300) { return }
    $body = Get-PortalErrorBody $Result
    throw "Failed to ${What}: HTTP $($Result.StatusCode) $($Result.StatusDescription). $body"
}

function New-PortalSession {
    param([Parameter(Mandatory)]$Credential, [bool]$SkipCertCheck, [int]$TimeoutSec)
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $portal = [pscustomobject]@{
        BaseUri = $Credential.BaseUri; Credential = [pscredential]::new($Credential.Username, $Credential.Password)
        Session = $session; Headers = @{}; SkipCertCheck = $SkipCertCheck; InstalledPackages = @(); CsrfHeader = $false
    }
    $result = Invoke-PortalRequest -Portal $portal -RelativeUri '/api/app/packagemanager/packages' -TimeoutSec $TimeoutSec
    Assert-PortalSuccess $result "authenticate to Device Portal at $($Credential.BaseUri)"
    try { $portal.InstalledPackages = @(Get-JsonField ($result.Response.Content | ConvertFrom-Json -ErrorAction Stop) 'InstalledPackages') }
    catch { throw "Device Portal at $($Credential.BaseUri) returned an unreadable package list." }
    if (-not $Credential.Username.StartsWith('auto-', [StringComparison]::Ordinal)) {
        $cookie = $session.Cookies.GetCookies([Uri]$Credential.BaseUri) | Where-Object Name -eq 'CSRF-Token' | Select-Object -First 1
        if ($cookie) { $portal.Headers['X-CSRF-Token'] = $cookie.Value; $portal.CsrfHeader = $true }
    }
    return $portal
}

function Get-PackageVersion {
    param($Package)
    $version = Get-JsonField $Package 'Version'
    try { return [version]::new([int](Get-JsonField $version 'Major'), [int](Get-JsonField $version 'Minor'), [int](Get-JsonField $version 'Build'), [int](Get-JsonField $version 'Revision')) }
    catch { return [version]'0.0.0.0' }
}

function Resolve-PortalPackage {
    param([object[]]$InstalledPackages, [string]$FamilyName, [Parameter(Mandatory)][string]$IdentityName)
    $matches = if ($FamilyName) { @($InstalledPackages | Where-Object { (Get-JsonField $_ 'PackageFamilyName') -eq $FamilyName }) }
    else { @($InstalledPackages | Where-Object { (Get-JsonField $_ 'Name') -eq $IdentityName -or (Get-JsonField $_ 'PackageFamilyName') -like "$IdentityName*" }) }
    if ($matches.Count -eq 0) { throw 'Could not find a matching installed Moonlight package.' }
    $matches | Sort-Object @{ Expression = { Get-PackageVersion $_ } } -Descending | Select-Object -First 1
}

function Test-PortalItemIsDirectory {
    param($Item)
    $type = Get-JsonField $Item 'Type'
    if ($type -is [string] -and ($type -eq 'Folder' -or $type -eq 'Directory')) { return $true }
    $number = $type -as [int]
    return $null -ne $number -and (($number -band 16) -ne 0)
}

function Get-LogListing {
    param([Parameter(Mandatory)]$Portal, [Parameter(Mandatory)][string]$Package, [Parameter(Mandatory)][string]$Path, [int]$TimeoutSec)
    $uri = "/api/filesystem/apps/files?knownfolderid=LocalAppData&packagefullname=$([Uri]::EscapeDataString($Package))&path=$([Uri]::EscapeDataString($Path))"
    $result = Invoke-PortalRequest $Portal $uri -TimeoutSec $TimeoutSec
    if ($result.StatusCode -eq 404) { return [pscustomobject]@{ Found = $false; Items = @() } }
    Assert-PortalSuccess $result "list $Path for $Package"
    try { $items = @(Get-JsonField ($result.Response.Content | ConvertFrom-Json -ErrorAction Stop) 'Items' | Where-Object { $_ -and -not (Test-PortalItemIsDirectory $_) }) }
    catch { throw "Device Portal returned an unreadable directory listing for $Path." }
    [pscustomobject]@{ Found = $true; Items = @($items | Sort-Object @{ Expression = { [string](Get-JsonField $_ 'Name') } } -Descending) }
}

function Test-SafeRemoteFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in '.', '..' -or $Name.EndsWith('.') -or $Name.EndsWith(' ') -or [IO.Path]::GetFileName($Name) -ne $Name -or $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    $stem = [IO.Path]::GetFileNameWithoutExtension($Name).TrimEnd('.', ' ').ToUpperInvariant()
    return $stem -notin @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
}

function Assert-NoReparsePathComponent {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $current = $root
    foreach ($segment in $fullPath.Substring($root.Length).TrimStart('\', '/') -split '[\\/]') {
        if (-not $segment) { continue }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing reparse-point path component: $current" }
        }
    }
    return $fullPath
}

function Resolve-SafeDestination {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-SafeRemoteFileName $Name)) { throw "Refusing to write remote file name '$Name': not a plain Windows file name." }
    $root = Assert-NoReparsePathComponent $Directory
    $destination = [IO.Path]::GetFullPath((Join-Path $root $Name))
    $prefix = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing remote file name '$Name': destination escapes output directory." }
    Assert-NoReparsePathComponent $destination | Out-Null
    return $destination
}

function Save-LogFile {
    param([Parameter(Mandatory)]$Portal, [Parameter(Mandatory)][string]$Package, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Destination, [int]$TimeoutSec)
    $target = Resolve-SafeDestination $Destination $Name
    $partial = "$target.partial-$([guid]::NewGuid().ToString('N'))"
    $uri = "/api/filesystem/apps/file?knownfolderid=LocalAppData&packagefullname=$([Uri]::EscapeDataString($Package))&path=$([Uri]::EscapeDataString($Path))&filename=$([Uri]::EscapeDataString($Name))"
    try {
        $result = Invoke-PortalRequest $Portal $uri -OutFile $partial -TimeoutSec $TimeoutSec
        Assert-PortalSuccess $result "download $Name"
        Move-Item -LiteralPath $partial -Destination $target -Force
        [ordered]@{ name = $Name; bytes = (Get-Item -LiteralPath $target).Length; path = $target }
    } finally { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
}

function Save-Screenshot {
    param([Parameter(Mandatory)]$Portal, [Parameter(Mandatory)][string]$Destination, [string]$Method, [int]$TimeoutSec)
    $state = [ordered]@{ requested = $true; method = $Method.ToUpperInvariant(); ok = $false }
    try {
        $result = Invoke-PortalRequest $Portal '/ext/screenshot' -Method $Method -OutFile $Destination -TimeoutSec $TimeoutSec
        $state.httpStatus = $result.StatusCode
        if ($result.StatusCode -ge 200 -and $result.StatusCode -lt 300) { $state.ok = $true; $state.bytes = (Get-Item -LiteralPath $Destination).Length; $state.path = $Destination }
        else { $state.error = "HTTP $($result.StatusCode) $($result.StatusDescription). $(Get-PortalErrorBody $result)" }
    } catch { $state.error = $_.Exception.Message; Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
    return $state
}

function Write-LogsSummary {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data, [Parameter(Mandatory)][string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    ([pscustomobject]$Data | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding utf8
    return $Path
}

$started = Get-Date
$cwd = (Get-Location).ProviderPath
if (-not $OutDir) { $OutDir = Join-Path $cwd (Join-Path 'xbox-logs' $started.ToString('yyyyMMdd-HHmmss')) }
elseif (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $cwd $OutDir }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (-not $Summary) { $Summary = Join-Path $OutDir 'logs-summary.json' }
elseif (-not [IO.Path]::IsPathRooted($Summary)) { $Summary = Join-Path $cwd $Summary }
$Summary = [IO.Path]::GetFullPath($Summary)
$summaryData = [ordered]@{ timestamp = $started.ToString('o'); outDir = $OutDir; success = $false }

try {
    $credential = Resolve-PullCredential -Path $CredentialPath -Require:$Require
    if (-not $credential) {
        $summaryData.success = $true; $summaryData.skipped = $true; $summaryData.reason = 'no credentials configured'
        Write-PullLog "No Xbox Device Portal credentials configured (checked $CredentialPath). Skipping log pull." -Level Warn
        Write-PullLog "Summary written to $(Write-LogsSummary $summaryData $Summary)"
        exit 0
    }
    $summaryData.consoleAddress = $credential.BaseUri; $summaryData.credentialSource = $credential.Source
    $portal = New-PortalSession $credential (-not $RequireValidCertificate) $RequestTimeoutSec
    $summaryData.csrfHeader = $portal.CsrfHeader
    if ($PackageFullName) { $package = $PackageFullName; $summaryData.packageSource = 'parameter' }
    else { $resolved = Resolve-PortalPackage $portal.InstalledPackages $PackageFamilyName $script:PackageIdentityName; $package = [string](Get-JsonField $resolved 'PackageFullName'); if (-not $package) { throw 'Resolved package has no PackageFullName.' }; $summaryData.packageSource = 'lookup' }
    $summaryData.packageFullName = $package
    $listings = @()
    $preferredPath = '\LocalState\logs'
    $preferredListing = Get-LogListing $portal $package $preferredPath $RequestTimeoutSec
    $listings += [pscustomobject]@{ path = $preferredPath; found = [bool]$preferredListing.Found; fileCount = @($preferredListing.Items).Count; listing = $preferredListing }
    if ($preferredListing.Found -and @($preferredListing.Items).Count -gt 0) {
        $selectedListing = $listings[0]
    } else {
        $alternatePath = '\logs'
        $alternateListing = Get-LogListing $portal $package $alternatePath $RequestTimeoutSec
        $listings += [pscustomobject]@{ path = $alternatePath; found = [bool]$alternateListing.Found; fileCount = @($alternateListing.Items).Count; listing = $alternateListing }
        $selectedListing = @($listings | Where-Object { $_.found -and $_.fileCount -gt 0 } | Select-Object -First 1)
        if (-not $selectedListing) { $selectedListing = @($listings | Where-Object found | Select-Object -First 1) }
    }
    if ($selectedListing) { $listing = $selectedListing.listing; $logPath = $selectedListing.path }
    else { $listing = [pscustomobject]@{ Items = @() }; $logPath = $null; $summaryData.note = 'No known log directory exists yet.' }
    $summaryData.logPathFindings = @($listings | ForEach-Object { [ordered]@{ path = $_.path; found = $_.found; fileCount = $_.fileCount } })
    $summaryData.logPath = $logPath
    $remote = @($listing.Items); $summaryData.remoteFileCount = $remote.Count
    $selected = if ($All) { $remote } else { @($remote | Select-Object -First $Newest) }
    $pulled = @()
    if ($selected.Count) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    foreach ($item in $selected) { $file = Save-LogFile $portal $package $logPath ([string](Get-JsonField $item 'Name')) $OutDir $RequestTimeoutSec; Write-PullLog "$($file.name) $($file.bytes) bytes"; $pulled += $file }
    $summaryData.files = @($pulled)
    if ($Screenshot) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null; $summaryData.screenshot = Save-Screenshot $portal (Join-Path $OutDir 'screenshot.jpg') $ScreenshotMethod $RequestTimeoutSec }
    else { $summaryData.screenshot = [ordered]@{ requested = $false } }
    $summaryData.success = $true
} catch {
    $summaryData.error = $_.Exception.Message
    Write-PullLog "Log pull failed: $($_.Exception.Message)" -Level Error
    Write-LogsSummary $summaryData $Summary | Out-Null
    throw
}
$summaryData.durationSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
Write-PullLog "Summary written to $(Write-LogsSummary $summaryData $Summary)"
