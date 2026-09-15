[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ManifestPath,
    [Parameter(Mandatory)] [string] $GeneratorPath,
    [Parameter(Mandatory)] [string] $VcpkgRoot,
    [Parameter(Mandatory)] [string] $ArchiveUrl
)

    $inputs = @($ManifestPath, $GeneratorPath)
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $stream = [System.IO.MemoryStream]::new()
    foreach ($path in $inputs) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Cache-key input is missing: $path" }
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $path))
        $stream.Write($bytes, 0, $bytes.Length)
        $separator = [Text.Encoding]::UTF8.GetBytes("`n--moonlight-ci-input--`n")
        $stream.Write($separator, 0, $separator.Length)
    }
    $urlBytes = [Text.Encoding]::UTF8.GetBytes($ArchiveUrl)
    $stream.Write($urlBytes, 0, $urlBytes.Length)
    $baseline = (& git -C $VcpkgRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $baseline) { throw "Could not resolve vcpkg baseline from $VcpkgRoot" }
    $baselineBytes = [Text.Encoding]::UTF8.GetBytes("`n--vcpkg-baseline--`n$baseline")
    $stream.Write($baselineBytes, 0, $baselineBytes.Length)
    ($sha.ComputeHash($stream.ToArray()) | ForEach-Object { $_.ToString('x2') }) -join ''
}
finally {
    $sha.Dispose()
    if ($stream) { $stream.Dispose() }
}
