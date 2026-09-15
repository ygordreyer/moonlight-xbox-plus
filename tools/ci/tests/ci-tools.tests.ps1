[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ("moonlight-ci-tests-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
Push-Location $temp
try {
    $source = Join-Path $temp 'source'
    New-Item -ItemType Directory -Path $source | Out-Null
    '{"run":1,"sha":"test-sha"}' | Set-Content -LiteralPath (Join-Path $source 'build-info.json')
    'package' | Set-Content -LiteralPath (Join-Path $source 'package.msix')
    $handoff = Join-Path $temp 'handoff'
    & (Join-Path $repo 'tools\ci\Publish-Handoff.ps1') -SourceDir $source -HandoffRoot $handoff -RunId 1 -RunAttempt 1 -RetentionCount 1
    $ready = Join-Path $handoff '1-1'
    if (-not (Test-Path (Join-Path $ready 'ready.json'))) { throw 'Published handoff has no ready marker' }
    $artifact = Join-Path $temp 'artifact'
    & (Join-Path $repo 'tools\ci\Use-Handoff.ps1') -HandoffRoot $handoff -RunId 1 -RunAttempt 1 -Destination $artifact -WorkspaceRoot $temp -ExpectedSha test-sha
    if ((Get-Content (Join-Path $artifact 'package.msix')) -ne 'package') { throw 'Handoff did not copy package' }
    $useScript = Join-Path $repo 'tools\ci\Use-Handoff.ps1'
    $useJobs = 1..2 | ForEach-Object {
        Start-Job -ScriptBlock {
            param($script, $root, $destination, $workspace)
            & $script -HandoffRoot $root -RunId 1 -RunAttempt 1 -Destination $destination -WorkspaceRoot $workspace -ExpectedSha test-sha
        } -ArgumentList $useScript, $handoff, (Join-Path $temp "artifact-concurrent-$_"), $temp
    }
    $useCompleted = Wait-Job -Job $useJobs -Timeout 30
    if ($useCompleted.Count -ne 2 -or @($useJobs | Where-Object State -eq 'Failed').Count) { throw 'Concurrent handoff destinations did not complete safely' }
    $useJobs | Receive-Job | Write-Host; $useJobs | Remove-Job
    $incomplete = Join-Path $handoff 'bad-1'
    New-Item -ItemType Directory -Path $incomplete | Out-Null
    $failed = $false
    try { & (Join-Path $repo 'tools\ci\Use-Handoff.ps1') -HandoffRoot $handoff -RunId bad -RunAttempt 1 -Destination $artifact -WorkspaceRoot $temp -ExpectedSha test-sha } catch { $failed = $true }
    if (-not $failed) { throw 'Incomplete handoff was accepted' }

    '{"run":2}' | Set-Content -LiteralPath (Join-Path $source 'build-info.json')
    & (Join-Path $repo 'tools\ci\Publish-Handoff.ps1') -SourceDir $source -HandoffRoot $handoff -RunId 2 -RunAttempt 1 -RetentionCount 1
    if (-not (Test-Path $ready)) { throw 'Retention removed active deploy handoff' }
    Remove-Item -LiteralPath (Join-Path $ready '.deploying') -Force
    & (Join-Path $repo 'tools\ci\Publish-Handoff.ps1') -SourceDir $source -HandoffRoot $handoff -RunId 3 -RunAttempt 1 -RetentionCount 1 -ExpectDeploy
    & (Join-Path $repo 'tools\ci\Publish-Handoff.ps1') -SourceDir $source -HandoffRoot $handoff -RunId 4 -RunAttempt 1 -RetentionCount 1 -RunStatusResolver { param($id) 'completed' }
    if (Test-Path (Join-Path $handoff '3-1')) { throw 'Completed queued deploy handoff was not reconciled for retention' }
    if (Test-Path (Join-Path $ready '.deploying')) { throw 'Completed active deploy marker was not reconciled' }
    & (Join-Path $repo 'tools\ci\Publish-Handoff.ps1') -SourceDir $source -HandoffRoot $handoff -RunId 5 -RunAttempt 1 -RetentionCount 10 -ExpectDeploy
    & (Join-Path $repo 'tools\ci\Publish-Handoff.ps1') -SourceDir $source -HandoffRoot $handoff -RunId 6 -RunAttempt 1 -RetentionCount 10 -RunStatusResolver { param($id) throw 'API unavailable' }
    if (-not (Test-Path (Join-Path $handoff '5-1'))) { throw 'API lookup failure did not retain pending handoff' }
    New-Item -ItemType File -Path (Join-Path $handoff '5-1\.deploying') -Force | Out-Null
    Remove-Item -LiteralPath (Join-Path $handoff '5-1\.pending-deploy') -Force
    & (Join-Path $repo 'tools\ci\Publish-Handoff.ps1') -SourceDir $source -HandoffRoot $handoff -RunId 7 -RunAttempt 1 -RetentionCount 10 -RunStatusResolver { param($id) 'completed' }
    if (Test-Path (Join-Path $handoff '5-1\.deploying')) { throw 'Completed deploying-only handoff was not reclaimed' }
    $wrongSha = $false
    try { & (Join-Path $repo 'tools\ci\Use-Handoff.ps1') -HandoffRoot $handoff -RunId 6 -RunAttempt 1 -Destination (Join-Path $temp 'wrong-sha') -WorkspaceRoot $temp -ExpectedSha test-sha } catch { $wrongSha = $true }
    if (-not $wrongSha) { throw 'Exact handoff SHA mismatch was accepted' }
    $handoffOverlap = $false
    try { & (Join-Path $repo 'tools\ci\Use-Handoff.ps1') -HandoffRoot $handoff -RunId 6 -RunAttempt 1 -Destination (Join-Path $handoff 'anotherhandoff') -WorkspaceRoot $temp -ExpectedSha test-sha } catch { $handoffOverlap = $true }
    if (-not $handoffOverlap) { throw 'Destination under handoff root was accepted' }

    $zipSource = Join-Path $temp 'zip-source\vcpkg_installed'
    New-Item -ItemType Directory -Path $zipSource -Force | Out-Null
    'cached' | Set-Content -LiteralPath (Join-Path $zipSource 'marker.txt')
    $archive = Join-Path $temp 'vcpkg.zip'
    Compress-Archive -Path (Join-Path $temp 'zip-source\vcpkg_installed') -DestinationPath $archive
    $cache = Join-Path $temp 'cache'
    $first = Join-Path $temp 'first\vcpkg_installed'
    $second = Join-Path $temp 'second\vcpkg_installed'
    $key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    & (Join-Path $repo 'tools\ci\Restore-VcpkgCache.ps1') -CacheRoot $cache -Key $key -Destination $first -WorkspaceRoot $temp -ArchiveUrl 'test://vcpkg' -ArchivePath $archive
    & (Join-Path $repo 'tools\ci\Restore-VcpkgCache.ps1') -CacheRoot $cache -Key $key -Destination $second -WorkspaceRoot $temp -ArchiveUrl 'test://vcpkg' -ArchivePath $archive
    if ((Get-Content (Join-Path $second 'marker.txt')) -ne 'cached') { throw 'Cache hit did not restore payload' }
    'not-json' | Set-Content -LiteralPath (Join-Path $cache "$key\cache-info.json")
    $recovered = Join-Path $temp 'recovered\vcpkg_installed'
    & (Join-Path $repo 'tools\ci\Restore-VcpkgCache.ps1') -CacheRoot $cache -Key $key -Destination $recovered -WorkspaceRoot $temp -ArchiveUrl 'test://vcpkg' -ArchivePath $archive
    if ((Get-Content (Join-Path $recovered 'marker.txt')) -ne 'cached') { throw 'Corrupt cache metadata did not recover' }
    $badKeyRejected = $false
    try { & (Join-Path $repo 'tools\ci\Restore-VcpkgCache.ps1') -CacheRoot $cache -Key '..\escape' -Destination $recovered -WorkspaceRoot $temp -ArchiveUrl 'test://vcpkg' -ArchivePath $archive } catch { $badKeyRejected = $true }
    if (-not $badKeyRejected) { throw 'Traversal cache key was accepted' }
    foreach ($badDestination in @($cache, (Join-Path $cache 'destanotherhandoff'))) {
        $overlapRejected = $false
        try { & (Join-Path $repo 'tools\ci\Restore-VcpkgCache.ps1') -CacheRoot $cache -Key $key -Destination $badDestination -WorkspaceRoot $temp -ArchiveUrl 'test://vcpkg' -ArchivePath $archive } catch { $overlapRejected = $true }
        if (-not $overlapRejected) { throw "Overlapping cache destination was accepted: $badDestination" }
    }

    $parallelCache = Join-Path $temp 'parallel-cache'
    $restoreScript = Join-Path $repo 'tools\ci\Restore-VcpkgCache.ps1'
    $jobs = 1..2 | ForEach-Object {
        Start-Job -ScriptBlock {
            param($script, $root, $destination, $zip)
            & $script -CacheRoot $root -Key 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd' -Destination $destination -WorkspaceRoot (Split-Path -Parent $root) -ArchiveUrl 'test://vcpkg' -ArchivePath $zip
        } -ArgumentList $restoreScript, $parallelCache, (Join-Path $temp "parallel-$_\vcpkg_installed"), $archive
    }
    $completed = Wait-Job -Job $jobs -Timeout 30
    if ($completed.Count -ne 2) { throw 'Concurrent cache population timed out' }
    $jobs | Receive-Job | Write-Host
    if (@($jobs | Where-Object State -eq 'Failed').Count) { throw 'Concurrent cache restore job failed' }
    $jobs | Remove-Job
    if (-not (Test-Path (Join-Path $parallelCache 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd\payload\vcpkg_installed\marker.txt'))) { throw 'Concurrent cache population did not publish payload' }
    Remove-Item -LiteralPath $archive -Force
    Write-Host 'PASS ci handoff and vcpkg cache tests'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
