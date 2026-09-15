# Moonlight Xbox+ engineering plan

## 0. Status and how to read this plan

- Revision 2, 2026-09-14. v1 (this same file) was folded after an adversarial review the same day; every finding was fixed or explicitly adapted to the as-built workflow and script, none waived.
- v0's intent, goals, observations, phases, branch names, acceptance criteria, and its 15 AI instructions are preserved. This revision corrects facts, adds receipts, and adds the build and deploy lanes that v0 left implicit.
- Executed by autonomous agents on the model-delegation ladder: haiku for mechanical fully specified steps, sonnet for ordinary bounded work, opus only for senior judgment, fable only for adversarial review. Never spawn opus or fable for fan-out.
- The owner is away for a long stretch. Everything that does not need him runs unattended. Everything that does need him is named once, in section 17, as a copy-ready action.

### Where things stand, 2026-09-14

- The fork (`ygordreyer/moonlight-xbox-plus`) and its working clone at `F:\GitHub\moonlight-xbox-plus` exist. A throwaway probe clone at `F:\GitHub\moonlight-xbox-plus-build` holds a proven green local build and is never pushed.
- `main` is the fork's default and integration branch, created from `ci/fork-workflow`. `master` mirrors `upstream/master` untouched. `baseline/upstream` is a pushed, pristine reference. Two commits carry the fork's CI and build fixes: `41a54ec` ("ci: fork workflow with signing secret and Xbox deploy job") and a second commit, subject "build: fix ffmpeg avio callback const and fork cert thumbprint" (the FFmpegDecoder version guard, the vcxproj certificate thumbprint, and the workflow changes in section 6.1).
- The self-hosted runner `ygor-desktop-xbox-lan` is online.
- Repository secrets `SIGNING_PFX_BASE64` and `SIGNING_PFX_PASSWORD` are SET (Gate 2, section 17, is CLOSED).
- The local build is GREEN (Gate 4, section 17, is CLOSED). Cause of the earlier failure and the fix are in 6.3.
- The upstream CI cause is known and the fix is landed (Gate 5, section 17, is CLOSED). See 6.5.
- Deploy soft-skips cleanly until `C:\Users\ygordreyer\.xbox-deploy\credentials.json` exists (Gate 1, section 17, is OPEN, the one owner action).
- GitHub Actions billing lock refuses hosted jobs on this account; the `build` job runs on the self-hosted lane (`ygor-desktop-xbox-lan`) until the owner clears it at https://github.com/settings/billing (Gate 6, section 17; mechanism in 6.6).
- Next steps: watch the self-hosted build lane run green on `main` (section 6.6), cut the 14 experiment and feature branches, and the owner creates `credentials.json` after setting Remote Access credentials with an `auto-` username in Dev Home (Gate 1).

### The central question, kept from v0

Can correct HDR plus true VRR be had on the XAML `SwapChainPanel` path that this app uses today? Answer it experimentally before any rewrite. Every phase below is ordered so the cheap experiments that discriminate between hypotheses run before any architectural change is committed.

### How to read this plan

- Section 1 is the diff against v0. Read it first if you already read v0.
- Section 3 is the fact base. Every claim carries a receipt: a `file:line`, a command, or a URL. A claim with no receipt is written UNCONFIRMED and stays UNCONFIRMED until the experiment that settles it runs. Do not promote an UNCONFIRMED claim by reasoning about it.
- Sections 6 and 7 are the machinery (build, sign, deploy). They must work before any experiment produces data, so they are phase 0.
- Sections 8 to 13 are the work, one experiment per branch. Section 14 is how a run is recorded. Section 16 is the rulebook for the agents doing the work.
- Nothing here reports a test that was not run. Where a result is predicted rather than measured, the sentence says so.

### Vocabulary

- "Foundation" is the Sunshine fork running as the host. On this network the host is the same Windows PC the agents run on.
- "the fork" is `github.com/ygordreyer/moonlight-xbox-plus`. "upstream" is `github.com/TheElixZammuto/moonlight-xbox`.
- "the console" is the Xbox Series X|S in Dev Mode at 192.168.18.20. "WDP" is the Windows Device Portal REST API on that console, port 11443.

---

## 1. Changes from v0

| Item | v0 said | Now | Evidence |
| --- | --- | --- | --- |
| Deploy transport | WinAppDeployCmd over the network | Device Portal REST on port 11443 from the self-hosted runner | `tools/xbox-deploy.ps1` (section 7.3); WDP endpoint list at learn.microsoft.com device-portal-api-core |
| Baseline build | Compare against the app already on the console | Console dev partition is empty, so the baseline is our own build of upstream master | Dev Home reads "There are no installed apps or games" |
| Windows SDK | Install SDK 10.0.19041 | No SDK override needed | vcxproj pins unversioned `WindowsTargetPlatformVersion=10.0`; `F:\Windows Kits\10` has 10.0.22621.0 and 10.0.26100.0 |
| Visual Studio | VS 2022 assumed for convenience | VS 17 2022 is mandatory | `generate-thirdparty-projects.bat:2` and `:4` hardcode `-G "Visual Studio 17 2022"` |
| vcpkg cost | Prebuilt `vcpkg_installed.zip` is reused | The generator never passes `VCPKG_INSTALLED_DIR`, so every fresh build pays a from-source vcpkg build | Same two lines have no `-DVCPKG_INSTALLED_DIR`; local probe about 20 min, upstream CI step 27 min |
| Upstream CI | Assumed green | Upstream master CI is RED at the Build step. Cause known: C2664 at `Streaming/FFmpegDecoder.cpp(628,21)`, libavformat 59 write-callback signature. Fix in 6.5, CLOSED. | Run 34136005241: C2664 at `Streaming/FFmpegDecoder.cpp(628,21)`, libavformat 59 write-callback signature; fix in 6.5 |
| Code signing on the fork | Not addressed | Fixed: `.github/workflows/msbuild.yml` decodes `SIGNING_PFX_BASE64` to `cert.pfx` on `push` and `workflow_dispatch`; the inherited ephemeral-cert step fires only when that secret is absent (in practice, a pull request from an external fork). Both signing secrets are SET. | `.github/workflows/msbuild.yml:196-208` (repo-secret cert) and `:210-240` (ephemeral fallback); note [1] |
| vcpkg zip source | Not addressed | The prebuilt zip URL is owned by upstream; mirror it or accept the dependency | `msbuild.yml:130-134` ("Restore VCPKG packages") fetches from `TheElixZammuto/moonlight-xbox` release 1.10.0 |
| Logging | Read logs from the on-screen overlay | No file logging exists at all | `Utils.cpp:16` ring vector, `:62` `OutputDebugString`, `:65-66` eviction at `LOG_LINES` |
| PR #281 | Cherry-pick it | It does not apply on HEAD; port it by hand | `git apply --check` fails at `VideoRenderer.cpp:159` and `VideoRenderer.h:97` |
| Tearing history | The tearing code was removed and should be restored | The only historical tearing code is a 12 ms `usleep` gated to Xbox One | Commit `3993f9a`, gated on `IsXboxOne()` and `LiGetPendingVideoFrames() < 2` |
| VRR API surface | Query the display for VRR | UWP `HdmiDisplayMode` and `HdmiDisplayInformation` expose zero VRR members | Full member enumeration, research memo section 2, restated in 3.20 |
| SDR colorspace | Not addressed | The client hardcodes Rec.601 for every stream | `State/MoonlightClient.cpp:262` `config.colorSpace = COLORSPACE_REC_601;` |
| HDMI mode switching | Not addressed | `SetDisplayHDR` is the only HDMI switch site and nothing resets SDR on stream end | `State/MoonlightClient.cpp:61`; `VideoRenderer::Stop()` at `:701-703` is a no-op |
| Resource mode | Not addressed | App versus Game resource mode is a free zero-code lever (Game gets about 5 GB and 4 exclusive cores) | Dev Home "Treat UWP apps as games by default"; research memo section 2 |
| Host location | Host unspecified | The Foundation Sunshine host is this same PC, service from `C:\Program Files\Sunshine` | `Get-Service Sunshine`; install path `C:\Program Files\Sunshine` |
| CI runner | To be set up | Self-hosted runner already online: id 2, `ygor-desktop-xbox-lan`, labels `self-hosted, Windows, X64, xbox-lan` | `gh api repos/ygordreyer/moonlight-xbox-plus/actions/runners --jq '.runners[] | select(.name=="ygor-desktop-xbox-lan")'` |
| Fork visibility | Not addressed | Fork is public; fork-PR approval policy `all_external_contributors` keeps fork PRs off the runner | `gh api repos/ygordreyer/moonlight-xbox-plus --jq .private` (false); `gh api repos/ygordreyer/moonlight-xbox-plus/actions/permissions/workflow` |
| Local build | Assumed to work | GREEN as of 2026-09-14 once a harness environment variable is cleared (6.3); no longer a diagnosis in progress | Local MSBuild is green once `NoDefaultCurrentDirectoryInExePath` is cleared in the launching shell (harness-set variable; not a code or CI problem) |
| Manifest target | Assumed `Windows.Xbox` | It is `Windows.Universal` | `Package.appxmanifest:24` |

[1] The fork cert gap, CLOSED. This described the inherited upstream workflow, which had exactly two certificate steps, neither of which fired for a push or a `workflow_dispatch` on the fork. The fork's own workflow (`.github/workflows/msbuild.yml`, section 6.1) replaces both: "Load signing certificate (repo secret)" at `:196-208` fires whenever `secrets.SIGNING_PFX_BASE64` is set, and "Generate ephemeral self-signed certificate" at `:210-240` fires only when that step was skipped (in practice, a pull request from an external fork, which cannot see the repo's secrets). Both secrets are SET, so the repo-secret path runs on every push and `workflow_dispatch`.

---

## 2. Goals and non-goals

### Goals, carried from v0 section 1

1. Correct HDR output on Xbox Series X|S: PQ pixels presented as PQ, no washed-out or grayish image, no premature highlight clipping.
2. True VRR, meaning the TV's refresh rate tracks the stream's frame rate, or a documented receipted finding that a sideloaded UWP app cannot get it.
3. Frame pacing at parity with Moonlight V+ and moonlight-qt: no periodic hitch, no persistent one-frame queue growth.
4. Dynamic bitrate adaptation driven by measured network conditions.
5. A DirectX-first streaming mode that removes the XAML overlay from the present path when it is not needed.
6. Client-side HDR capability negotiation with Foundation Sunshine so the host tone-maps to the real display, not to a default.

### Non-goals for this revision

- No rewrite of the renderer, the decoder, or the composition model until the discriminating experiments in section 4 have run. A rewrite is an outcome of evidence, not a starting position.
- No change to moonlight-common-c or any submodule. If a fix belongs there, it is recorded and deferred.
- No upstream pull request until an experiment branch has a measured result recorded in `TEST-RESULTS.md`.
- No Xbox One support work. The console under test is Series X|S. Xbox One code paths are read but not modified.
- No attempt to make the TV or the host compensate. A fix that requires changing a TV picture mode or a host calibration is not a fix, it is a workaround, and it is recorded as such.

---

## 3. Verified facts and receipts

### 3.1 The repository

- Fork clone at `F:\GitHub\moonlight-xbox-plus`. `main` is the fork's default and integration branch (`git rev-parse --short main` at fix time); `master` mirrors `upstream/master` at `50c02fd`, subject "fix(h264): limit h264 to 1080p60, the limit of the Xbox hardware decoder", and is never edited.
- Submodules: `third_party/DirectXTK`, `third_party/imgui`, `third_party/moonlight-common-c` (which carries enet and nanors), and `vcpkg`.
- Vendored, not submodules: `third_party/imgui-uwp`, `third_party/h264bitstream`.
- `third_party/implot` appears in an include path but the directory is dead. Do not add an implot dependency without restoring it first.
- Local branches: `main` (default, integration), `master` (upstream mirror), `baseline/upstream` (pushed), `ci/fork-workflow` (the branch the fixes-only commits were authored on; `main` was created from it), `pr-281` at `9704eb041129d5acd8a9a8a4c6fdf933096de52e` (a local reference branch, read-only, never cherry-picked; see 3.14 and h3 in the fold record).
- Remote `upstream` carries branches this plan has not read: `hdr2`, `better-diagnostics`, `intra-refresh`, `tracy`, `feature/onboarding`, `andyg.xbox-fix-combo-input`, `privacy-policy`. The content of `hdr2` is UNCONFIRMED and is worth one read before phase 3 starts.

### 3.2 The HDR path as it exists today

- `Streaming/VideoRenderer.cpp:170` opens `if (frame->color_trc != m_LastColorTrc) {`. The whole color space decision is gated on the transfer characteristic changing.
- `:173` selects `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020` only when `frame->color_trc == AVCOL_TRC_SMPTE2084`, otherwise the sRGB space.
- `:182` calls `CheckColorSpaceSupport` and requires `DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT` before `:183` calls `SetColorSpace1`. If the check fails or returns without the flag, nothing is applied and nothing is logged.
- `:190` sets `m_LastColorTrc = frame->color_trc;` inside the `if` but outside the success branch. A failed apply still updates the cache, so the code will not retry until the transfer characteristic changes again.
- `m_LastColorTrc` is initialized at `:57` to `AVCOL_TRC_UNSPECIFIED`.
- `:460` and `:469` return `COLORSPACE_REC_601` as a fallback in the frame-to-colorspace mapping; `:531` and `:551` handle `COLORSPACE_REC_601` in the CSC matrix selection and the log string.
- `VideoRenderer::SetHDR(bool)` is at `:682`. It calls `client->SetDisplayHDR(true, ...)` at `:693` and `client->SetDisplayHDR(false, SS_HDR_METADATA{})` at `:697`. It does not touch the swap chain.
- `VideoRenderer::Stop()` at `:701-703` is literally `// nothing to do`. Nothing restores SDR on the HDMI link when a stream ends.
- `Streaming/VideoRenderer.cpp` is 704 lines.

### 3.3 The swap chain

- `Common/DeviceResources.cpp:242` `DXGI_SWAP_CHAIN_DESC1 swapChainDesc = {0};` with `:244-250` setting Width, Height, Format from `m_backBufferFormat`, `Stereo = false`, `SampleDesc {1,0}`, `BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT`.
- `:252` `BufferCount = 5;`, `:253` `SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;`, `:254` `Flags = 0;` (no `DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING`), `:255` `Scaling = DXGI_SCALING_STRETCH`, `:256` `AlphaMode = DXGI_ALPHA_MODE_IGNORE`.
- `:280` `dxgiFactory->CreateSwapChainForComposition(` is the creation call. This is the composition path, not `CreateSwapChainForCoreWindow` and not `CreateSwapChainForHwnd`.
- `:306` `panelNative->SetSwapChain(m_swapChain.Get())` binds it to the XAML `SwapChainPanel`. `:364` is `SetSwapChainPanel(SwapChainPanel^ panel)`.
- `:214` `m_swapChain->ResizeBuffers(`, `:222` its log, `:228` `HandleDeviceLost()` on failure.
- `:486` `void DX::DeviceResources::HandleDeviceLost()`; call sites at `:481`, `:539`, `:544`.
- `:525` `void DX::DeviceResources::Present()`, `:527` `HRESULT hr = m_swapChain->Present(0, 0);` Sync interval 0, present flags 0.
- `:93` `UINT creationFlags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;`, `:125` `CreateDXGIFactory2`. The file is 652 lines.
- There is no call to `IDXGIFactory5::CheckFeatureSupport` with `DXGI_FEATURE_PRESENT_ALLOW_TEARING` anywhere in the tree, and no use of `DXGI_PRESENT_ALLOW_TEARING`. Grep for `ALLOW_TEARING` outside `third_party` returns only the comment at `State/Stats.h:19`.

### 3.4 The stream configuration sent to the host

- `State/MoonlightClient.cpp:261` `config.colorRange = this->IsRGBFull() ? COLOR_RANGE_FULL : COLOR_RANGE_LIMITED;`
- `:262` `config.colorSpace = COLORSPACE_REC_601;` This is hardcoded. It is never Rec.709 and never Rec.2020, whatever the stream actually is.
- `:263` `config.encryptionFlags = ENCFLG_AUDIO;`, `:264` `config.packetSize = 1024;`, `:266` `config.supportedVideoFormats = VIDEO_FORMAT_H264;`
- `:267-272` add `VIDEO_FORMAT_H265` when the codec setting is HEVC and the console is not an Xbox One VCR, and add `VIDEO_FORMAT_H265_MAIN10` on top when `sConfig->enableHDR`. AV1 is never requested anywhere.
- `:258-259` log `clientRefreshRateX100` with the target FPS and the measured display refresh, so a refresh-rate hint already reaches the host.
- `SetDisplayHDR(bool enabled, const SS_HDR_METADATA &sunshineHdrMetadata)` is at `:61`. Its body reads the current `HdmiDisplayMode` at `:69`, early-returns at `:75` and `:82` when the display is already in the requested state, gives up at `:129` when no suitable mode exists, switches at `:140` and `:145`, confirms at `:158`, and logs an error at `:168`.
- `connection_set_hdr(bool enable)` at `:390-394` forwards to the instance's `SetHDR` callback.
- `connection_terminated(int status)` at `:396-402` logs and sets `g_connectionTerminated`. It does not reset the display to SDR. The file is 606 lines.

### 3.5 The decoder

- `Streaming/FFmpegDecoder.cpp:216` selects between P010 and NV12; `:652` handles `YUV420P10LE`.
- Frames therefore reach the renderer as 10-bit when HDR is negotiated, which is a precondition for any PQ path and is already satisfied.
- `Streaming/FFmpegDecoder.cpp:628` column 21 is where upstream CI fails (C2664): `CaptureAvioWrite` is declared with `const uint8_t*` but libavformat 59, the FFmpeg the prebuilt `vcpkg_installed.zip` actually supplies to the main build, types the `avio_alloc_context` write callback as `int (*)(void*, uint8_t*, int)` (non-const buffer). The const form starts at libavformat 61. Fix in 6.5.

### 3.6 Pacing

- `Streaming/Pacer.cpp` is 434 lines. `:134` `m_DeviceResources->GetDXGIOutput()->WaitForVBlank();` runs on a dedicated thread.
- `:200` `if (vsyncRR >= 120.0)` selects the half-vblank cadence for 120 Hz displays.
- `:224-225` `const int queueHas = 1; FrameQueue::instance().waitForEnqueue(queueHas, timeoutMs);`
- `:242-271` is the immediate render path, which dequeues and renders at once, with `:253-255` draining an extra frame when `queueDepth > FRAME_QUEUE_LOW`.
- `:293-330` is the display-locked path, same extra-drain rule at `:299-305`, per-frame log at `:328`.
- The header comment at `:20-30` documents the design: frames are dropped at enqueue time in an alternating manner past a high water mark of 2 plus 1, and `waitBeforePresent()` aligns to the next vblank or half-vblank.

### 3.7 The overlay and the quick menu

- `Pages/StreamPage.xaml:19` `<SwapChainPanel x:Name="swapChainPanel" ...>`.
- `:28` `<MenuFlyout x:Name="ActionsFlyout" Closed="ActionsFlyout_Closed" ...>` with items from `:29`. The quick menu is a XAML `MenuFlyout` drawn locally over the swap chain panel. It cannot change the host's frames.
- Stats overlay is ImGui in `StatsRenderer.cpp`; the log overlay is `LogRenderer.cpp`.

### 3.8 Logging

- `Utils.cpp` is 177 lines. `:16` `std::vector<std::wstring> logLines;` is the whole log store. `:62` `OutputDebugString(string.c_str());`. `:65-66` evict the oldest line once `logLines.size() == LOG_LINES`. `:78` push, `:104` return the vector for the overlay.
- There is no file sink. Nothing survives an app restart and nothing can be pulled off the console after a test. This is the single biggest obstacle to unattended experiments, and phase 1 fixes it.

### 3.9 Dead VRR scaffolding

- `State/Stats.h:15-20`: `VSYNC_ON = 1`, `VSYNC_OFF = (1 << 1)`, `VRR_SUPPORTED = (1 << 2)` commented "console is in VRR mode but it's not being used", `VRR_ON = (1 << 3)` commented "we're using ALLOW_TEARING Present mode in fullscreen mode (not yet possible)".
- Nothing sets `VRR_SUPPORTED` or `VRR_ON`. The enum is dead code recording a previous author's intent and their conclusion that it was not possible.

### 3.10 Build configuration

- `.github/workflows/msbuild.yml` is 405 lines (`wc -l`), `name: MSBuild` at `:45`. This is the fork's own rewrite (commit `41a54ec` plus the fixes-only commit named in section 0), not the inherited upstream file; the full step-by-step contract is section 6.1. Line count grew from 351 while the billing lock is active: one comment line above `runs-on` and a three-line `Set up NuGet` step, both described below and in 6.6. It grew again from 365 to 405 when the build job gained a runner-local package handoff step and the deploy job gained a runner-local fallback step, both added so the deploy job keeps working while artifact storage is locked too (6.1, 7.2).
- Triggers at `:47-67`: `push` on branches `main`, `baseline/**`, `experiment/**`, `feature/**`, `ci/**`; `pull_request` on `[main]` with types `[opened, synchronize, reopened]`; `workflow_dispatch` with inputs `deploy` (boolean, default `true`) and `ref_note` (free text). `concurrency` group is `${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress: true` (`:73-75`).
- `env` at `:77-79`: `SOLUTION_FILE_PATH: .`, `BUILD_CONFIGURATION: Release`. Job `build` at `:82` now `runs-on: [self-hosted, xbox-lan]` (`:84`), TEMPORARY while the billing lock is active (6.6); the revert target is `runs-on: windows-2022`, what this line read before the lock.
- Steps: `actions/checkout@v4` at `:90-93` (fetch-depth 0, submodules recursive); "Add MSBuild to PATH" (`microsoft/setup-msbuild@v2`) at `:95-98`; "Stamp package version" at `:100-128` (rewrites `Package.appxmanifest`'s `Identity/Version` to `<major>.<minor>.<run_number>.0`, exports `PACKAGE_VERSION` via `GITHUB_ENV`); "Restore VCPKG packages" at `:130-134` (downloads `vcpkg_installed.zip` from `TheElixZammuto/moonlight-xbox` release `1.10.0`); "Extract VCPKG packages" at `:136-137`; "List VCPKG packages" at `:139-140`; "Install VCPKG packages" at `:142-143` running `.\vcpkg\bootstrap-vcpkg.bat`; "Cache vcpkg from-source builds" at `:145-160` (keyed on `hashFiles('vcpkg.json', 'generate-thirdparty-projects.bat')`); "Build third party tools" at `:162-163` running `.\generate-thirdparty-projects.bat`; "Set up NuGet" (`nuget/setup-nuget@v2`) at `:165-166`, added while the build job runs on the self-hosted lane (6.6) because that machine does not ship `nuget.exe` on PATH (18.9); "Restore NuGet" at `:168-169` (`nuget restore`); "Add Windows SDK bin directory to PATH (fxc.exe)" at `:171-194`; "Load signing certificate (repo secret)" at `:196-208` (id `cert`, fires when `secrets.SIGNING_PFX_BASE64 != ''`); "Generate ephemeral self-signed certificate" at `:210-240` (id `certtmp`, fires only when the previous step was skipped); "Build" at `:242-284`; "Write build metadata" at `:286-302`; "Clean Certificate" at `:304-309` (`if: always()`); "Upload artifacts" at `:330-339` (`actions/upload-artifact@v4`, name `moonlight-uwp`, path `output`, `if-no-files-found: error`, `retention-days: 30`).
- The Build step (`:242-284`) reads `SIGNING_PFX_PASSWORD` from its own `env:`, coalesces `$certPassword` from `$env:EPHEMERAL_PFX_PASSWORD` (set by the ephemeral step through `GITHUB_ENV`, because the runner drops a step output whose value contains a masked secret) or `$env:SIGNING_PFX_PASSWORD`, coerces it to `[string]`, computes `$thumb` from `(Resolve-Path 'cert.pfx').Path` via `X509Certificate2`, and passes `/p:PackageCertificateThumbprint=$thumb` alongside `/p:Configuration=Release /p:AppxBundle=Always /p:AppxPackageDir=output /p:PackageCertificateKeyFile=cert.pfx /p:UapAppxPackageBuildMode=SideLoadOnly`. The `$thumb` override exists because `moonlight-xbox-dx.vcxproj:139` hardcodes `PackageCertificateThumbprint`; without the override msbuild fails at `Microsoft.AppXPackage.Targets(922,5)` with "Certificate does not match supplied signing thumbprint" whenever the loaded pfx is not the certificate that value names.
- `moonlight-xbox-dx.vcxproj:139` `<PackageCertificateThumbprint>` is now `2FE3549ACE299557AACC02A3D36C996B544EF901` (the stable fork cert; upstream's value was `609C6A553DA6A00199D49BF8231E048743D5DD80`), landed in the fixes-only commit so plain VS and local builds also sign without a command-line override.
- A `deploy` job at `:341-405` runs on `[self-hosted, xbox-lan]`, `needs: build`, `timeout-minutes: 30`, gated (`:351-354`) on `github.repository == 'ygordreyer/moonlight-xbox-plus' && github.event_name != 'pull_request' && (github.event_name != 'workflow_dispatch' || inputs.deploy == true)`, concurrency group `xbox-deploy` with `cancel-in-progress: false`. It checks out the repo, downloads artifact `moonlight-uwp`, runs `tools/xbox-deploy.ps1 -ArtifactDir artifact -OutputDir deploy-out -Launch -Screenshot` (no `-Require`), and uploads `deploy-out` with `if: always()` so a summary always lands even when the deploy soft-skips.
- `generate-thirdparty-projects.bat` is 5 lines: cd into `third_party\moonlight-common-c`, one cmake configure, cd into `libgamestream`, a second cmake configure, cd back. Both cmake lines pass `-G "Visual Studio 17 2022" -DCMAKE_SYSTEM_NAME=WindowsStore -DCMAKE_SYSTEM_VERSION="10.0" -DVCPKG_TARGET_TRIPLET=x64-uwp -DTARGET_UWP=ON -DVCPKG_MANIFEST_MODE=on -DBUILD_SHARED_LIBS=off` and a `-DVCPKG_MANIFEST_DIR`. Neither passes `-DVCPKG_INSTALLED_DIR`.
- `vcpkg.json` declares `builtin-baseline` `9e593bb18ea69cc5095e012465dcd675a822ed0d`, depends on ffmpeg (features avcodec, avformat, swscale, default features off), curl, openssl, expat, zlib, nlohmann-json, bzip2, freetype, opus, mdns, and overrides ffmpeg to `8.1.2#3`. That override is real but INERT for the main build: "Restore VCPKG packages" downloads a prebuilt `vcpkg_installed.zip` (upstream release `1.10.0`) whose headers and libs are what `FFmpegDecoder.cpp` actually compiles against, and that tree reports `LIBAVFORMAT_VERSION_MAJOR` 59, not the 62 the `8.1.2#3` override produces. Verified: `vcpkg_installed\x64-uwp\include\libavformat\version_major.h` in the prebuilt tree says `LIBAVFORMAT_VERSION_MAJOR 59`; the manifest-built tree under `vcpkg\packages\ffmpeg_x64-uwp` (used only by the two from-source sub-builds, moonlight-common-c and libgamestream) says `62`. This is why the C2664 fix in 6.5 is a version guard, not a manifest pin change.
- `Package.appxmanifest:10-14` `Identity Name="50497EliaZammuto.MoonlightUWP" Publisher="CN=CE07B73A-712E-4E05-932B-D08CE2C8A87C" Version="1.18.1.0"`.
- `:24` `<TargetDeviceFamily Name="Windows.Universal" MinVersion="10.0.0.0" MaxVersionTested="10.0.0.0" />`. `:32` `<Application Id="App" ...>`, so the PRAID is `<PackageFamilyName>!App`.
- `:48-50` capabilities `internetClient`, `privateNetworkClientServer`, and the restricted `hevcPlayback`.
- Release 1.18.1 ships `Microsoft.UI.Xaml.2.7.appx`, `Microsoft.VCLibs.x64.14.00.appx`, the `.msixbundle`, and the `.cer`.

### 3.11 The environment

- VS2022 Community at `F:\Program Files\Microsoft Visual Studio\2022\Community`. Windows SDK root `F:\Windows Kits\10` with 10.0.22621.0 and 10.0.26100.0 only. `nuget` is not on PATH for a local build, and the same is true of the self-hosted runner machine: `Get-Command nuget.exe` and `where.exe nuget.exe` both come back empty (18.9). The build job's "Restore NuGet" step (`msbuild.yml:168-169`) now runs a "Set up NuGet" step (`msbuild.yml:165-166`, `nuget/setup-nuget@v2`) immediately before it for that reason, added while the build job runs on the self-hosted lane (6.6). `msbuild.exe` needs no equivalent step: `microsoft/setup-msbuild@v2` (`:95-98`) adds it to PATH on any runner, hosted or self-hosted. The local lane still needs a durable `nuget.exe` path on this machine, not a copy in a session scratchpad, since a scratchpad is deleted at session end; record the chosen path here once it is set up.
- This PC is 192.168.18.171/24. The console is 192.168.18.20.
- Foundation Sunshine runs as a service from `C:\Program Files\Sunshine`, config `config\sunshine.conf`, capture `vdd`, `output_name ZakoHDR`, fps list `[59.94, 60, 90, 120, 144]`, paired client "XBOX" uuid `C70DDA76-6F39-DF02-5D14-F085420AC711`, `hdrBrightnessMode` manual at 1000 nits.
- Console: name XBOX, sandbox XDKS.1, OS 10.0.26100.9426, Remote Access `https://192.168.18.20:11443`, dev partition empty.

### 3.12 Device Portal endpoints that are confirmed

Source: https://learn.microsoft.com/en-us/windows/uwp/debug-test-perf/device-portal-api-core

- `POST /api/app/packagemanager/package?package=<name>` with the appx or appxbundle plus dependencies as the multipart body. The `package` query parameter repeats; a dependency file is marked with a `.opt` suffix. A certificate is only required on IoT and Desktop, not Xbox. HTTP 200 means accepted, not finished.
- `GET /api/app/packagemanager/state`: 200 with the last result, 204 while still running, 404 when no install has been attempted.
- `DELETE /api/app/packagemanager/package?package=<PackageFullName>`.
- `GET /api/app/packagemanager/packages` returns `InstalledPackages[]` with `Name`, `PackageFamilyName`, `PackageFullName`, `PackageOrigin`, `PackageRelativeId`, `Publisher`, `Version{Major,Minor,Build,Revision}`, `RegisteredUsers`.
- `POST /api/taskmanager/app?appid=<hex64 PRAID>&package=<hex64 PackageFullName>` launches. `DELETE /api/taskmanager/app?package=<hex64>` stops, optional `forcestop=yes`. `DELETE /api/taskmanager/process?pid=<pid>`.
- `GET /api/resourcemanager/processes`, upgradeable to a WebSocket at 1 Hz.
- `GET /api/filesystem/apps/files?knownfolderid=LocalAppData&packagefullname=<pfn>[&path=<sub>]` returns `Items[]` with `CurrentDir`, `DateCreated`, `FileSize`, `Id`, `Name`, `SubPath`, `Type`.
- `GET /api/filesystem/apps/file?knownfolderid=<id>&filename=<name>&packagefullname=<pfn>[&path=]` returns the bytes, or 404.
- `POST /api/filesystem/apps/file` uploads, `POST /api/filesystem/apps/rename` renames, `DELETE /api/filesystem/apps/file` deletes, `GET /api/filesystem/apps/knownfolders` lists ids.
- Use the `/api/app/packagemanager/*` family. The legacy `/api/appx/packagemanager/*` family is the older generation and is not the one to target.

### 3.13 Device Portal facts that are NOT confirmed

- `-SkipCertificateCheck` on PowerShell 7 is a general PowerShell fact applied to WDP here. UNCONFIRMED as a WDP-specific instruction. Expect it to work; verify on first contact.
- Whether authentication can be fully disabled on Xbox Dev Mode WDP: UNCONFIRMED.
- The `/ext/` family exists (`/ext/app/sshpins`, `/ext/app/deployinfo`, `/ext/fiddler`, `/ext/httpmonitor/sessions`, `/ext/networkcredential`, `/ext/remoteinput`, `/ext/remoteinput/controllers`, `/ext/screenshot`, `/ext/settings`, `/ext/smb/developerfolder`, `/ext/user`, `/ext/xbox/info`, `/ext/xboxlive/sandbox`) per https://learn.microsoft.com/en-us/previous-versions/windows/uwp/xbox-apps/reference, but the HTTP verb for each is UNCONFIRMED. `GET /ext/screenshot` is near-certain but unverified.
- The GDK "Enabling WDP on Xbox" page is NDA-gated and could not be read. `microsoft/WindowsDevicePortalWrapper` call shapes are UNCONFIRMED; a raw fetch returned 404.
- CSRF: the portal sets a `CSRF-Token` cookie that must be echoed as an `X-CSRF-Token` header on state-changing requests, and a username beginning `auto-` is exempt from that requirement. CSRF applies on HTTPS only. Cross-site WebSocket hijacking protection compares Origin against Host.

### 3.14 PR #281

- Branch `fix-hdr` by ArturKorop, commit `9704eb041129d5acd8a9a8a4c6fdf933096de52e`, closed without merge.
- The diff touches exactly two files. In `Streaming/VideoRenderer.cpp` it replaces the inline `color_trc` block at line 159 with a call to a new `applySwapChainColorSpace(frame)` and adds two functions. In `Streaming/VideoRenderer.h` it declares them after `hasFrameFormatChanged` and adds `bool m_SwapChainHdrColorSpace = false;` after `m_LastChromaLocation`.
- `frameUsesHdrColorSpace()` returns true for `AVCOL_TRC_SMPTE2084`, false when neither `configuration->enableHDR` nor `client->IsHDR()` holds, and otherwise true for `AVCOL_TRC_UNSPECIFIED` and `AVCOL_TRC_BT709`. That last clause is the substance: it treats a missing or misreported transfer characteristic as PQ when the session is an HDR session.
- `applySwapChainColorSpace()` drops `CheckColorSpaceSupport` entirely, calls `SetColorSpace1` directly, logs the HRESULT on failure, and updates the two cached members only on success.
- A second hunk appends a direct `SetColorSpace1` to `SetHDR(bool)` after the existing `SetDisplayHDR` call, resetting `m_LastColorTrc` to `AVCOL_TRC_UNSPECIFIED` and `m_SwapChainHdrColorSpace` to `!enabled` first so the next frame re-applies if this fails.
- The PR body's own theory, quoted: "Swap chain color space never set to PQ (highest probability). The swap chain defaults to sRGB/gamma 2.2 for R10G10B10A2." It also notes that moonlight-qt does not use `CheckColorSpaceSupport` and logs the HRESULT instead.
- The author states they do not write C++, relied on an AI assistant, and tested on their own Xbox in Dev Mode where "HDR works fine". Treat that as a report, not a measurement.
- `git apply --check` fails on HEAD at `VideoRenderer.cpp:159` and `VideoRenderer.h:97`. The port is manual.

### 3.15 Corroborating upstream issues

- Issue #234 "HDR is too bright": LG G5, host Apollo. The reporter says opening the guide or home system overlay temporarily fixes the brightness. That is the single most informative observation in the whole issue set, because a system overlay changes composition, not stream content.
- Issue #276: intermittent HDR handshake failure against CachyOS Sunshine, while Apple TV 4K and iPad Pro clients work against the same host.
- Issue #271: Series S at 4K120 with HDR gives a black screen and signal loss at stream start, host "Vibeshine".
- Issue #181: title and body disagree; the body describes muted colors, "almost like a white or gray overlay", and is Xbox UWP only.

### 3.16 Foundation Sunshine, host side

- Launch query parameters on the wire: `hdrMode`, `maxBrightness`, `minBrightness`, `maxAverageBrightness`, `sdrBrightness`. Source file `nvhttp.cpp`.
- `client_display_capabilities.h` carries the client-reported capability structure.
- `session_target.h` and `session_target.cpp` carry `target_source_e {client_report, manual_override, windows_hdr_calibration, safe_defaults}`, `effective_target_t`, `resolve_effective_target()`, `resolve_session_target()`, `adopt_vdd_calibration_if_needed()`.
- `video_colorspace.cpp` carries `colorspace_e {rec601, rec709, bt2020sdr}` with the `AVCOL_RANGE_JPEG` and `AVCOL_RANGE_MPEG` mapping. `bt2020sdr` requires 10-bit and otherwise falls back to `rec709` with a `BOOST_LOG(error)`.
- The exact string "H.264 SDR Rec.601 8-bit JPEG" was searched for and NOT found verbatim. It is UNCONFIRMED as a literal log line, though the underlying negotiation mechanism is real.
- Per-client override keyed by a certificate-derived UUID is carried forward from earlier notes and was not re-verified byte for byte. Treat as UNCONFIRMED.

### 3.17 Moonlight V+ pacing, Android

- `FramePacingController.kt` implements a two-stage cadence snap: `computeHostCadenceSnapTime()` estimates the host's frame cadence, then the release time is snapped onto it.
- `doFrame(frameTimeNanos)` runs on Choreographer; refresh is measured from the delivered `frameTimeNanos` rather than from a queried display mode. Output is released with a timed `releaseOutputBuffer(index, presentationTimeNs)`.
- Early frames are held, late frames are released or dropped, and queue depth feeds back into the decision.
- Four named pacing modes and their companion tunables exist but were NOT re-quoted verbatim. Pull them from the source before citing or implementing any of them.
- The implementation is Kotlin and MediaCodec-specific. Only the algorithm ports, not the code. V+'s HDR metadata handling and any custom protocol fields are UNCONFIRMED.

### 3.18 moonlight-common-c

- `STREAM_CONFIGURATION` carries `colorSpace` and `colorRange` only. There is no HDR field on it. HDR metadata travels separately through `LiGetHdrMetadata()` and `SS_HDR_METADATA`.
- Constants: `COLORSPACE_REC_601`, `COLORSPACE_REC_709`, `COLORSPACE_REC_2020`, `COLOR_RANGE_FULL`, `COLOR_RANGE_LIMITED`.
- RTSP carries `x-ss-general.featureFlags`, `x-ss-general.encryptionSupported`, `x-ss-general.encryptionRequested`, `X-SS-Ping-Payload`, `X-SS-Connect-Data`. None is HDR-specific.

### 3.19 Xbox Dev Mode resource model

- Dev Home has a "Treat UWP apps as games by default" toggle and a per-title App versus Game resource mode.
- Game mode: about 5 GB of RAM, 4 exclusive cores plus 2 shared, full GPU. App mode: about 1 GB foreground and 128 MB background, 2 to 4 shared cores, about 45 percent of the GPU.
- Dev Home Settings, Display Settings has a device-wide "Allow Variable Refresh Rate (VRR)" toggle. Whether it has any effect on a sideloaded Dev Mode UWP app is UNCONFIRMED.
- x64 is required for Xbox. The DirectX feature-level table was not re-verified for this revision.

### 3.20 Negative findings, confirmed

- `HdmiDisplayMode` members are exactly: `BitsPerPixel`, `ColorSpace`, `Is2086MetadataSupported`, `IsDolbyVisionLowLatencySupported`, `IsSdrLuminanceSupported`, `IsSmpte2084Supported`, `PixelEncoding`, `RefreshRate` (a single scalar), `ResolutionHeightInRawPixels`, `ResolutionWidthInRawPixels`, `StereoEnabled`, plus `IsEqual()`.
- `HdmiDisplayInformation` members are exactly: `GetCurrentDisplayMode()`, static `GetForCurrentView()`, `GetSupportedDisplayModes()`, three `RequestSetCurrentDisplayModeAsync` overloads, `SetDefaultDisplayModeAsync()`, and the `DisplayModesChanged` event.
- There is no VRR member, no refresh-rate range, no adaptive-sync flag anywhere in either type. A UWP app cannot ask the display whether VRR is active and cannot turn it on.
- `.msixbundle` sideloading on Xbox Dev Mode is confirmed by the project README plus the `AppxBundle=Always` and `UapAppxPackageBuildMode=SideLoadOnly` build properties.
- `SimpleHDR_UWP` exists (DX11, C++/CX) but its guidance is deferred to a Word document that could not be read. `SimpleHDR_UWP12`'s existence rests on a web search snippet only and is UNCONFIRMED.

---

## 4. Observations and hypotheses

### The observations that constrain everything

From v0 section 2, preserved:

- HDR looks grayish and washed out in Moonlight Xbox and only in Moonlight Xbox. Same host, same TV, other clients are correct.
- Highlights clip at about 1600 nits with the quick menu CLOSED, and at about 2200 nits with the quick menu OPEN. The quick menu is a local XAML `MenuFlyout` (`Pages/StreamPage.xaml:28`) drawn over the swap chain panel. It cannot change what the host encodes, so the difference is produced on the console, in composition or in the presented color space, not in the stream.
- The Foundation HDR stream is structurally correct: `hevc_nvenc`, Rec.2020 primaries, SMPTE 2084 PQ transfer, 10-bit, MPEG range, captured display color space `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020`, luminance 0 / 1690 / 1690.

The quick-menu observation and issue #234's system-overlay observation are the same class of evidence from two independent reporters: making the compositor do more work changes the HDR result. That is the strongest signal in the corpus and it points away from a pure stream-decode bug.

### Hypotheses

**H1. The swap chain is never actually put into PQ.** `CheckColorSpaceSupport` at `VideoRenderer.cpp:182` can return success without the PRESENT support flag, so the `SetColorSpace1` at `:183` is skipped silently and `:190` caches the transfer characteristic anyway, so it is never retried. PQ pixels are then presented as sRGB. *Discriminating experiment*: phase 1 instrumentation logs, per frame-format change, `color_trc`, the `CheckColorSpaceSupport` HRESULT, the returned support bitmask, and the `SetColorSpace1` HRESULT. If the flag is absent or the HRESULT fails, H1 is confirmed and phase 3A is the fix. Branches `experiment/hdr-instrumentation` then `experiment/hdr-force-pq`.

**H2. The stream reports a transfer characteristic that is not SMPTE 2084.** HEVC Main10 encoders sometimes omit VUI transfer characteristics or emit BT.709 with PQ content. If `color_trc` is `AVCOL_TRC_UNSPECIFIED` or `AVCOL_TRC_BT709`, the code at `:173` picks the sRGB branch and the swap chain is deliberately put in the wrong space. *Discriminating experiment*: the same phase 1 log answers this on the first HDR frame. If `color_trc` is not 2084 on a stream the host says is PQ, H2 is confirmed and PR #281's `frameUsesHdrColorSpace()` heuristic is the fix. Branch `experiment/hdr-pr281`.

**H3. XAML and DWM composition is a second, architecturally distinct cause.** A composition swap chain is composited by DWM together with the XAML tree. If that composition path tone-maps, clamps, or converts, the app cannot fix it from inside the swap chain, and both the quick-menu and the system-overlay observations are explained directly. *Discriminating experiment*: the cheap compositor test in phase 2a. Toggle a tiny XAML element on and off without opening the menu and watch whether the clipping point moves. If it moves, H3 is confirmed independent of H1 and H2 and the DirectX streaming mode becomes load bearing rather than a nice-to-have. Branch `experiment/vrr-direct-render` carries the composition alternatives.

**H4. The HDMI display mode and the swap chain color space drift out of sync.** `SetDisplayHDR` at `MoonlightClient.cpp:61` switches the HDMI link; the swap chain color space is set elsewhere, from the frame. On a resize, a device-lost recovery, or a mid-session HDR toggle, one can change without the other. *Discriminating experiment*: phases 3B and 3C. Reapply the color space after every `ResizeBuffers` (`DeviceResources.cpp:214`) and after every `HandleDeviceLost` (`:486`), logging both the HDMI mode and the swap chain space at each. Branches `experiment/hdr-reapply-resize` and `experiment/hdr-reapply-device-lost`.

**H5. The hardcoded Rec.601 corrupts SDR and possibly HDR.** `MoonlightClient.cpp:262` tells the host the client wants Rec.601 for every stream. For SDR content the correct answer is Rec.709; for HDR content it is Rec.2020. *Discriminating experiment*: section 9. Change the constant to `COLORSPACE_REC_709` on `experiment/sdr-rec709`, read the host's own negotiated-colorspace log line, and compare a color chart. The renderer's CSC path at `VideoRenderer.cpp:495-558` already handles all three, so the renderer is not the limitation.

**H6. Nothing resets the display to SDR when a stream ends.** `VideoRenderer::Stop()` at `:701-703` is a no-op and `connection_terminated` at `MoonlightClient.cpp:396-402` does not touch the display. A console left in HDR mode after an SDR session renders the dashboard and the next SDR stream through an HDR pipeline. *Discriminating experiment*: mechanical. End a stream, read the current `HdmiDisplayMode` through the phase 1 logger, and see whether it is still the HDR mode. This is a bug regardless of whether it explains the main symptom.

**H7. VRR is not reachable from a sideloaded UWP app.** See section 10. The composition swap chain structurally cannot carry `ALLOW_TEARING`, the UWP display API exposes no VRR surface, and the only historical "tearing" code in this repo is an Xbox One sleep. *Discriminating experiment*: the five-step probe in section 10, designed to produce a receipted negative as its most likely outcome.

**H8. Pacing, not color, explains part of the perceived quality gap.** The current pacer drops frames in an alternating pattern past a fixed high water mark (`Pacer.cpp:20-21`) rather than snapping to a measured host cadence. *Discriminating experiment*: section 11, measured against frame-time traces, not against impressions.

H1 and H2 are cheap and are tested first, in one instrumentation pass. H3 is the expensive one and is the reason the central question exists. Do not start H3's rewrite before H1, H2 and H4 have been measured, because if H1 is the whole story the rewrite is wasted.

---

## 5. Repository layout and branch model

### Clones

- `F:\GitHub\moonlight-xbox-plus` is the working clone. Origin is the fork; `upstream` is TheElixZammuto.
- `F:\GitHub\moonlight-xbox-plus-build` is a throwaway build-lane probe clone. It is never pushed and never carries work. Delete it when the build lane is settled.
- Never commit to `master` directly. `master` mirrors `upstream/master` and nothing else.

### Branches

1. `main`, the fork's default and integration branch, created from `ci/fork-workflow`. Every experiment and feature branch below branches from `main`, not from `baseline/upstream`.
2. `master`, an untouched mirror of `upstream/master` (currently `50c02fd`). Never committed to directly; never branched from.
3. `baseline/upstream`, a pushed, pristine reference matching upstream at the point the fork was cut. Kept for comparison only, not built or branched from.
4. `ci/fork-workflow`, the branch the fixes-only commits (`41a54ec` and the FFmpeg/certificate commit) were authored on. `main` was created from it; new work does not target it directly once `main` exists.
5. `pr-281`, a local reference branch at `9704eb041129d5acd8a9a8a4c6fdf933096de52e`, read-only, never cherry-picked (3.14, h3 below).
6. `experiment/hdr-instrumentation`
7. `experiment/hdr-pr281`
8. `experiment/hdr-force-pq`
9. `experiment/hdr-reapply-resize`
10. `experiment/hdr-reapply-device-lost`
11. `experiment/vrr-allow-tearing`
12. `experiment/vrr-direct-render`
13. `experiment/sdr-rec709`
14. `experiment/compositor-probe` (phase 2a, H3's cheap compositor test)
15. `experiment/present-sync1` (phase 2b)
16. `feature/directx-streaming-mode`
17. `feature/foundation-hdr-capabilities`
18. `feature/vplus-pacer`
19. `feature/dynamic-bitrate`

Fourteen of these (items 6 through 19) are the experiment and feature branches an agent creates; the console baseline build is `main` at the fixes-only commit, recorded in `docs/TEST-RESULTS.md` as "baseline".

### Branch rules

- One experiment per branch. A branch that carries two changes cannot produce a clean result.
- Every experiment or feature branch branches from `main` unless it explicitly builds on a proven earlier experiment, and then it says so in its own notes file. `baseline/upstream` stays a comparison reference only; nothing branches from it.
- Every branch carries `docs/experiments/<branch-leaf>.md` written before the first commit on it: the hypothesis it tests, the exact code change, the expected result if the hypothesis holds, the expected result if it does not, and the measurement that separates them.
- Every branch must build. A branch that does not build is not an experiment, it is a work in progress, and it does not get deployed.
- `docs/PLAN.md` (this file) lives on `main` and is the only file this planning pass writes.
- The control for pacing and drop-count comparisons is the `main` fixes-only build (untouched by any experiment), not `baseline/upstream`, because `main` is what the CI and deploy lanes actually produce and what every experiment branches from; `baseline/upstream` stays the pre-fork reference (rule 10, section 16).

### Layout additions this plan introduces

- `docs/PLAN.md` (this file); `docs/experiments/<name>.md`, one per experiment branch; `docs/TEST-RESULTS.md` on each experiment branch, appended after every console run.
- `tools/xbox-deploy.ps1`, the deploy script (section 7), already landed and read as ground truth in section 6.1 and 7.3.
- `.github/workflows/msbuild.yml`, the fork's own rewrite of the inherited workflow (section 3.10, section 6.1), carrying both the `build` job and the `deploy` job. There is no separate `build.yml`/`deploy.yml` split; both jobs live in the one file so the `needs: build` dependency and the shared `artifact` handoff stay in one place. Because both jobs run on the same self-hosted runner, the build job also keeps a runner-local copy of the package under `<runner _work>\_handoff\<run_id>` (`:311-328`, newest five kept), the upload step is best effort (`:330-339`), and the deploy job falls back to that copy (`:374-385`) when the artifact download fails.

---

## 6. Build lane

### 6.1 Primary lane: GitHub-hosted windows-2022, already built

The fork's own workflow, `.github/workflows/msbuild.yml`, replaces the inherited one in place (it is the fork's own rewrite, not a second file alongside it), so both the build job and the deploy job live together and share the artifact handoff through `needs: build`. Full line-numbered receipts are in 3.10; this section states the contract an agent can rely on. The build job also keeps a runner-local copy of the package (`:311-328`) since the two jobs share one runner, the upload is best effort (`:330-339`), and the deploy job falls back to that copy (`:374-385`) when the artifact download fails.

Triggers: `push` on `main`, `baseline/**`, `experiment/**`, `feature/**`, `ci/**`; `pull_request` on `[main]`; `workflow_dispatch` with `deploy` (boolean, default `true`) and `ref_note` (free text) inputs, so an agent can build, and choose whether to also deploy, any branch on demand.

Steps, as built:

1. Checkout, `fetch-depth 0`, submodules recursive.
2. `microsoft/setup-msbuild@v2`.
3. Stamp package version: rewrites `Package.appxmanifest`'s `Identity/Version` to `<major>.<minor>.<run_number>.0` and exports `PACKAGE_VERSION` via `GITHUB_ENV`, so every artifact is distinguishable on the console and `GET /api/app/packagemanager/packages` can tell which build is installed. The stamped manifest ships in the artifact as-is; AppX versioning requires the manifest and the installed package to agree, so this is correct rather than a cleanup omission.
4. Restore, extract, list, and bootstrap vcpkg packages from the prebuilt `vcpkg_installed.zip` (upstream release `1.10.0`).
5. Cache vcpkg from-source builds, keyed on `hashFiles('vcpkg.json', 'generate-thirdparty-projects.bat')`.
6. Build third party tools: `.\generate-thirdparty-projects.bat`. The expensive step (6.2).
7. Restore NuGet.
8. Add the Windows SDK bin directory to PATH so `fxc.exe` resolves.
9. **Certificate.** Two mutually exclusive steps. "Load signing certificate (repo secret)" decodes `SIGNING_PFX_BASE64` into `cert.pfx` and fires whenever that secret is set; it does not export the password as a step output, because the Actions runner drops a step output whose value contains a masked secret, so the password reaches the Build step through that step's own `env:` instead. "Generate ephemeral self-signed certificate" fires only when the repo-secret step was skipped (in practice, a pull request from an external fork, which cannot see repo secrets) and exports `EPHEMERAL_PFX_PASSWORD` via `GITHUB_ENV`. Both signing secrets are SET on this fork, so the repo-secret path runs on every push and `workflow_dispatch`; the ephemeral path is dormant machinery on this fork, exercised only by an external-fork PR.
10. **Build.** `msbuild` with `/p:Configuration=Release /p:AppxBundle=Always /p:AppxPackageDir=output /p:PackageCertificateKeyFile=cert.pfx /p:UapAppxPackageBuildMode=SideLoadOnly`, plus `/p:PackageCertificateThumbprint=$thumb` where `$thumb` is computed at runtime from the loaded `cert.pfx` via `X509Certificate2`. This override exists because `moonlight-xbox-dx.vcxproj:139` hardcodes a thumbprint; a loaded pfx that is not that exact certificate fails at `Microsoft.AppXPackage.Targets(922,5)`, "Certificate does not match supplied signing thumbprint", without it. The vcxproj now hardcodes the fork's own stable cert thumbprint (3.10), so on this fork the override is redundant with the loaded pfx today, and is kept because it keeps the build correct through any future cert rotation.
11. Write build metadata: `output/build-info.json` with `version`, `runId`, `runNumber`, `sha`, `ref`, `eventName`, `refNote`, `builtAt`, `configuration`, written directly as structured JSON by the workflow itself. Recovering any of these never requires parsing a log.
12. Clean certificate, `if: always()`. `cert.pfx` never survives past this step, on a hosted runner or the self-hosted one.
13. Upload artifact `moonlight-uwp`, the whole `output` directory, `if-no-files-found: error`.

A `deploy` job runs after `build` on `[self-hosted, xbox-lan]`, gated so it only fires on pushes and dispatches to this repository and never on `pull_request` (7.2), and runs `tools/xbox-deploy.ps1` (7.3) against the downloaded artifact.

### 6.2 The vcpkg cost, and two mitigations that must be verified, not assumed

Measured: the local probe ran `generate-thirdparty-projects.bat` to completion in about 20 minutes and produced about 281 MB. On the hosted runner the same step took 27 minutes in upstream run 34136005241 (15:01:39 to 15:28:32). That is the dominant cost of every build.

Cause, with the receipt: `generate-thirdparty-projects.bat:2` and `:4` both run cmake in manifest mode with `-DVCPKG_MANIFEST_MODE=on` and a `-DVCPKG_MANIFEST_DIR`, but neither passes `-DVCPKG_INSTALLED_DIR`. Without it, each cmake project installs its dependencies into its own `<build>/vcpkg_installed`, so the `vcpkg_installed` directory the workflow downloaded and extracted at the repository root is never consulted.

Two candidate mitigations. Both are plausible. Neither is proven. Verify each by exactly one CI run and record the wall-clock time in `docs/experiments/build-lane.md` before adopting it.

- **Mitigation A.** Add `-DVCPKG_INSTALLED_DIR=<repo root>\vcpkg_installed` to both cmake invocations so the prebuilt tree is reused. Confirmed risk, not a guess: the prebuilt tree (release `1.10.0`) reports `LIBAVFORMAT_VERSION_MAJOR` 59, while the vcpkg-manifest-built tree these two sub-builds currently link (`vcpkg\packages\ffmpeg_x64-uwp`) reports 62, because `vcpkg.json`'s `8.1.2#3` ffmpeg override only reaches a from-source manifest build, never the prebuilt zip (3.10, h1 in the review fold record). Pointing `moonlight-common-c` and `libgamestream` at the prebuilt tree would change the libavformat major version they build against from 62 to 59; whether their code tolerates that swing the way the main app now does (6.5's version guard) is unverified. Verify by one run and check specifically for a libavformat-59-versus-61 symptom in these two sub-builds, not just a successful link.
- **Mitigation B.** Set `VCPKG_BINARY_SOURCES=clear;x-gha,readwrite` in the job environment along with the `ACTIONS_CACHE_URL` and `ACTIONS_RUNTIME_TOKEN` the GitHub Actions binary cache backend needs. The first run still pays full cost and populates the cache; later runs pull binaries. Verify by two runs, not one, because the benefit only appears on the second.

Until one is verified, budget 30 minutes per CI build and do not treat a slow build as a failure.

### 6.3 Secondary lane: local VS2022

Status: GREEN as of 2026-09-14. This is the current state, not a prediction.

- Probe clone `F:\GitHub\moonlight-xbox-plus-build`. Generator completed, about 20 minutes, about 281 MB.
- The signing certificate for local builds is the stable fork cert: subject `CN=CE07B73A-712E-4E05-932B-D08CE2C8A87C`, thumbprint `2FE3549ACE299557AACC02A3D36C996B544EF901`, `NotAfter` 2031-09-14, kept under `C:\Users\ygordreyer\.xbox-deploy\`. It is the same certificate `moonlight-xbox-dx.vcxproj:139` now hardcodes (3.10), so a plain local or Visual Studio build signs correctly with no command-line override.
- The earlier failure ("216 Warning(s) 3 Error(s)", all three from `third_party\DirectXTK\DirectXTK_Windows10_2022.vcxproj(450,5)`, target `ATGEnsureShaders`, error MSB3073, `'CompileShaders' is not recognized as an internal or external command, operable program or batch file`, exit code 9009) is diagnosed and fixed. Cause: the Claude Code harness that launches local builds sets `NoDefaultCurrentDirectoryInExePath=1` in the shell environment. `ATGEnsureShaders` invokes a `CompileShaders.cmd` script from the DirectXTK submodule by a lookup that relies on the current directory being searched; with that variable set, `cmd.exe` drops the current directory from the search and the lookup fails with exit 9009, "command not found". Fix: clear `NoDefaultCurrentDirectoryInExePath` in the launching shell before invoking msbuild for a local build. This is a harness artifact of how the agent launches builds on this machine, not a code or CI problem: the hosted lane (windows-2022, section 6.1) never sets this variable and was never affected by it.
- The local lane is a convenience for fast iteration, not on the critical path. It is green now, so both lanes are usable; by design the hosted lane is meant to remain sufficient on its own for every phase in this plan if the local lane ever regresses, but today the hosted lane itself does not run at all (billing lock, 6.6), and the self-hosted build lane (6.6) is what actually stands in for it. A local-lane regression right now would leave only the self-hosted CI lane, not a hosted fallback, until the lock clears.

### 6.4 Upstream CI is red, cause known and fixed on this fork

Upstream master's own CI run 34136005241 (2026-09-07) shows "Build third party tools" 15:01:39 to 15:28:32 succeeded, "Restore NuGet" 12 seconds succeeded, "Load Certificate (local)" succeeded, and "Build" FAILED after 1 minute 24 seconds. Cause known: C2664 at `Streaming/FFmpegDecoder.cpp(628,21)`, `CaptureAvioWrite` declared with a `const uint8_t*` buffer against libavformat 59's non-const write-callback signature (3.5, 3.10). Fix in 6.5, already landing on `main` as part of the fixes-only commit named in section 0. This is the first thing to check when a fresh build fails on this fork: confirm the 6.5 guard is present before assuming a new regression, rather than re-diagnosing upstream's failure from scratch.

### 6.5 Required source fix before any build

`Streaming/FFmpegDecoder.h` and `Streaming/FFmpegDecoder.cpp` wrap the `CaptureAvioWrite` declaration and definition with `#if LIBAVFORMAT_VERSION_MAJOR >= 61` (const `uint8_t*` buffer, matching libavformat 61 and newer, the signature PR review tooling and any future manifest-driven build would expect) `#else` (non-const `uint8_t*` buffer, matching libavformat 59, what the prebuilt `vcpkg_installed.zip` actually supplies to the main build today) `#endif`. This guard is already applied: it is currently present as uncommitted working-tree changes (`git status --short` shows `M Streaming/FFmpegDecoder.cpp` and `M Streaming/FFmpegDecoder.h`) and lands on `main` as part of the fixes-only commit named in section 0. It is required for every green build of the fork, hosted or local, and does not depend on upstream ever fixing its own CI; do not wait on upstream for this.

### 6.6 Self-hosted build lane while GitHub billing is locked

- Symptom: a GitHub-hosted job (`runs-on: windows-2022`) on this fork shows `completed / failure` within seconds, `steps: []`, `runner: null`; the job log itself returns HTTP 404. The only evidence is a check-run annotation.
- How to read it: `gh api repos/ygordreyer/moonlight-xbox-plus/check-runs/<jobId>/annotations`. The annotation text is "The job was not started because your account is locked due to a billing issue."
- Refused runs, all GitHub-hosted: 34918888396 (branch `main`), 34918896056 (branch `ci/fork-workflow`), 34919419091 and 34920673835 (branch `ci/runner-probe`).
- Only the account owner can clear the lock, at https://github.com/settings/billing.
- Self-hosted jobs run fine under the same lock. Proof: workflow `Runner probe` (`.github/workflows/runner-probe.yml`, exists only on branch `ci/runner-probe`, commit `2f76261`, triggers `workflow_dispatch` plus `push: branches: ['ci/runner-probe']`) ran as run 34920673895, job 104227886473, `completed / success`, 3 steps, log line `probe ok on DESKTOP`, on self-hosted runner `ygor-desktop-xbox-lan` (labels `self-hosted, Windows, X64, xbox-lan`).
- Rule learned along the way: a `workflow_dispatch`-only workflow that exists only on a non-default branch cannot be dispatched; `gh workflow run <file> --ref <branch>` returns HTTP 404. Trigger it with a `push:` filter on its own branch instead, or merge the workflow to the default branch first.
- Decision: the `build` job in `.github/workflows/msbuild.yml` moves from `runs-on: windows-2022` to `runs-on: [self-hosted, xbox-lan]` as a TEMPORARY lane (`:82-84`).
- Revert condition: return the `build` job to `windows-2022` once https://github.com/settings/billing is unlocked and one hosted run is green.
- Two ledger actions once the lock clears: revert the `build` job's `runs-on`, and delete the `ci/runner-probe` branch and its workflow file.
- Security note: the runner already executes the `deploy` job from the same checkout (7.1), and fork pull requests need approval before any job runs (`all_external_contributors`, section 16 rule 22, `:819`), so building on the runner too adds no new exposure.
- The runner runs one job at a time, so pushes to several branches queue rather than run in parallel.
- Unverified until the first runner build, because none of this was exercised on the self-hosted runner before: MSBuild discovery via `microsoft/setup-msbuild@v2`'s vswhere lookup (VS 2022 is installed on the runner machine); the vcpkg zip restore path; and `NoDefaultCurrentDirectoryInExePath` (set in the Claude Code harness's own shells and known to break MSBuild's `CompileShaders` step with exit 9009, section 6.3, but the runner is launched by a scheduled task rather than a harness shell, so it should not carry that variable).
- `nuget.exe` availability is RESOLVED for this runner machine: `Get-Command nuget.exe` and `where.exe nuget.exe` both come back empty, so a `Set up NuGet` step (`nuget/setup-nuget@v2`, `msbuild.yml:165-166`) now runs immediately before `Restore NuGet` (`:168-169`). `msbuild.exe` needs no equivalent step: `microsoft/setup-msbuild@v2` (`:95-98`) adds it to PATH on any runner, hosted or self-hosted.

---

## 7. Deploy lane

### 7.1 The runner

Already live, verified: runner id 2, name `ygor-desktop-xbox-lan`, status online, labels `self-hosted, Windows, X64, xbox-lan`, install directory `C:\actions-runner\moonlight-xbox-plus`, registered as scheduled task `\AI Hub\MoonlightXboxRunner`, state Running, trigger AtLogOn, runner version 2.337.0.0.

Two things are NOT verified: whether the AtLogOn trigger actually starts it on a real logon (it has only been observed already running), and whether any deploy job has ever run on it. The first deploy job to run is therefore also the test of both.

### 7.2 Job gating, a security control and not a convenience

The deploy job is gated, as built (`msbuild.yml:351-354`), on `github.repository == 'ygordreyer/moonlight-xbox-plus' && github.event_name != 'pull_request' && (github.event_name != 'workflow_dispatch' || inputs.deploy == true)`, runs on `[self-hosted, xbox-lan]`, and carries `needs: build` so it consumes the uploaded artifact rather than rebuilding. Its own concurrency group `xbox-deploy` (`cancel-in-progress: false`) serializes deploys so two pushes in quick succession queue rather than race the console. When the artifact download fails (`:364-372`, best effort via `continue-on-error`), the deploy job falls back to the runner-local package copy the build job kept at `<runner _work>\_handoff\<run_id>` (`:374-385`), so the artifact-storage lock does not also block the deploy.

Never `pull_request`. The fork is public. The fork-PR approval policy is `all_external_contributors`, which needs approval before workflows run, and that policy protects the build job. A deploy job triggerable by a PR would put arbitrary contributed code on a console on the owner's LAN with portal credentials in scope. The `inputs.deploy` clause gives a `workflow_dispatch` caller an explicit off switch (`deploy: false`) for a build-only run. A dispatch-only deploy (never automatic on push) was considered and not taken as the default: the owner's explicit ask was automatic deploy on every push, and rule 33 (section 16) covers the one real risk that leaves, a push landing mid manual-console-test-sweep, while the `xbox-deploy` concurrency group already serializes competing runs.

Before relying on a dispatched run reaching the deploy job, confirm the runner is actually online: `gh api repos/ygordreyer/moonlight-xbox-plus/actions/runners --jq '.runners[] | select(.name=="ygor-desktop-xbox-lan") | .status'` should read `online`. If it does not, the task `\AI Hub\MoonlightXboxRunner` most likely stopped; recover it with `Start-ScheduledTask -TaskPath '\AI Hub\' -TaskName 'MoonlightXboxRunner'` and re-check status before assuming the deploy job itself is broken.

### 7.3 `tools/xbox-deploy.ps1` contract, as built

PowerShell 7, 664 lines, already written and read as ground truth for this section. Actual parameters: `-ArtifactDir <path>` (mandatory); `-ConsoleAddress`, `-Username`, `-Password`, `-CredentialsPath` (default `$HOME/.xbox-deploy/credentials.json`); switches `-Require`, `-DryRun`, `-Launch`, `-AppUserModelId`, `-PullLocalState`, `-Screenshot`, `-RequireValidCertificate`; `-OutputDir`; timing `-InstallPollIntervalSec` (default 3), `-InstallPollTimeoutSec` (default 300), `-RequestTimeoutSec` (default 60).

Behavior, in order:

1. **Credential gate.** `Resolve-DeployCredential` reads `-CredentialsPath` (or the individual parameters). Without `-Require`, a missing or incomplete credential source is a soft skip: the script logs the exact text `"No Xbox Device Portal credentials configured (checked parameters and $CredentialsPath). Skipping deploy. Pass -Require to make this a hard failure."`, writes `deploy-summary.json` into `-OutputDir` with `skipped=true, reason='no credentials configured'`, and **exits 0**. This is the one output file on this path; there is no separate `deploy-skipped.json`. With `-Require`, the same missing-credential condition is a hard failure instead, which is why the workflow's deploy step (6.1) deliberately omits `-Require`: a missing credential must not turn the whole pipeline red while the owner is away.
2. When a credentials file is supplied, `Resolve-DeployCredential` requires ALL THREE of `consoleAddress`, `username`, and `password`; missing any one throws `"Credentials file ... is missing consoleAddress, username, or password."` The workflow's deploy step never passes `-ConsoleAddress` on the command line, so the credentials file is the only source for it, which is why Gate 1's example JSON (section 17) includes `consoleAddress`.
3. `Resolve-DeployArtifact` finds the bundle directly under `-ArtifactDir`'s root, not recursively: `*.msixbundle`, falling back to `*.msix`. It then searches an `ArtifactDir\Dependencies` subfolder recursively for `*.appx` and `*.msix` dependency files.
4. Establish a session against the console, `-SkipCertificateCheck` unless `-RequireValidCertificate` is passed (the console's certificate is self-signed). Capture the `CSRF-Token` cookie.
5. CSRF handling: a username beginning `auto-` is exempt from the header requirement (3.13); otherwise the cookie value is echoed as `X-CSRF-Token` on every non-GET request.
6. `Install-DevicePortalPackage` does the install: a multipart `POST /api/app/packagemanager/package?package=<bundle filename>` carrying the bundle and every dependency file found in step 3. It adds a `.opt` suffix to dependency filenames before upload, keeping the bundle's own filename unchanged (G7, fixed on main). No certificate is uploaded: certificates are only required on IoT and Desktop, not Xbox.
7. `Wait-DevicePortalInstall` polls `GET /api/app/packagemanager/state` every `-InstallPollIntervalSec` (default 3s) up to `-InstallPollTimeoutSec` (default 300s). This poll is genuinely bounded: on timeout it throws `"Timed out after $PollTimeoutSec seconds waiting for install to complete. Last observed state: $lastObservedState."` rather than hanging. The timeout message now reports the last observed state, fixed on main.
8. Re-query `GET /api/app/packagemanager/packages` to confirm the installed package and record its `PackageFamilyName` and `PackageFullName`.
9. With `-Launch`: `Start-DevicePortalApp` base64-encodes (never hex; G1 below) the appid (PackageFamilyName plus AppId) and the **PackageFullName**, then calls `POST /api/taskmanager/app?appid=<b64 appid>&package=<b64 PackageFullName>`. Device Portal's documentation (3.12) describes the `package` launch parameter as the PackageFullName. G8 is fixed on main: the script now passes PackageFullName instead of PackageFamilyName, verified against Microsoft's live Device Portal API documentation.
10. With `-PullLocalState`: pulls the app's LocalState files off the console.
11. With `-Screenshot`: captures a Device Portal screenshot into `-OutputDir`.
12. Writes `deploy-summary.json` into `-OutputDir` on both the success path and the soft-skip path (step 1), which is why `deploy-out`'s `if: always()` upload (6.1) always has something to show, whether or not credentials were configured.

With `-DryRun`, the script validates its inputs and exits 0 before making any network call.

### 7.4 Fallback transports

- Visual Studio pairing with a PIN from Dev Home. The PIN is short-lived and needs a human at the console. This is the manual fallback only, never the automated path.
- `WinAppDeployCmd` is not used. It targets a different generation of the deployment stack and was v0's assumption; the portal REST path is the one with confirmed endpoints.

### 7.5 Security rules for this lane, non-negotiable

- **Never expose the Device Portal publicly.** No port forward, no reverse proxy, no tunnel, no UPnP. It is LAN only, reachable only from this PC and the runner on the same subnet.
- **Never log credentials.** Not the username, not the password, not the Basic header, not the CSRF token, not a redacted-looking prefix of any of them. Scripts must not echo the credential file's contents and must not print the request headers they send.
- **Never commit credentials.** The credentials file path `C:\Users\ygordreyer\.xbox-deploy\credentials.json` may be named in code and documentation. Its contents may not be read into a commit, a log, an issue, a PR body, or an agent transcript. Signing certificate material also lives under `C:\Users\ygordreyer\.xbox-deploy\` and is subject to the same rule. No agent working on this plan ever reads anything under that directory.
- Secrets reach CI only as repository secrets (`SIGNING_PFX_BASE64`, `SIGNING_PFX_PASSWORD`). They are never echoed and the certificate file is always removed in an `if: always()` step.
- **Never run fork PRs on the self-hosted runner.** The runner sits on the owner's LAN with portal access. Keep the fork-PR approval policy at `all_external_contributors` and keep the build job on GitHub-hosted runners.
- **Never stage a commit with a blanket add.** `git add -A`, `git add .`, and `git commit -a` are banned on this repository; they can sweep up `cert.pfx`, a stray `credentials.json`, or other local-only files that a targeted `git add <path>` would not. Stage named paths only.
- **Never turn on verbose msbuild logging while a certificate password is on the command line.** `/v:diag`, `/v:detailed`, and `/fl` (file logger) can all write the resolved command line, environment, or property values to a log file; combined with the password reaching msbuild through a property or environment variable, that log becomes a credential leak. Keep verbosity at the workflow's default or `/v:minimal` for any build that touches the signing certificate.
- If a credential is ever printed anywhere, treat it as exposed, stop, and record it in section 17 as a rotation item. Do not attempt to rotate the owner's credentials autonomously.

---

## 8. Phases

### Phase 0. Machinery

Goal: a commit on any branch produces a signed, versioned artifact and lands on the console with no human involved. This machinery is now built, not proposed; the bullets below record what exists and what is still owed.

- `.github/workflows/msbuild.yml` exists, one file carrying both the `build` job (section 6.1) and the `deploy` job (section 7.2), not the separate `build.yml`/`deploy.yml` pair an earlier draft of this plan assumed. `SIGNING_PFX_BASE64` and `SIGNING_PFX_PASSWORD` are set as repository secrets (Gate 2, section 17, is closed; provenance commands are in section 18.1, marked done and never to be rerun).
- `moonlight-xbox-dx.vcxproj:139` `PackageCertificateThumbprint` was changed from upstream's `609C6A553DA6A00199D49BF8231E048743D5DD80` to the fork's stable self-signed thumbprint `2FE3549ACE299557AACC02A3D36C996B544EF901`, as part of the fixes-only commit named in section 0.
- `tools/xbox-deploy.ps1` exists (section 7.3), including the exit-0 credential gate so the pipeline stays green while the portal credentials are missing.
- The 14 experiment and feature branches (section 5) are created from `main` (pending; section 0 next steps), not from `baseline/upstream`: each carries its `docs/experiments/<name>.md` stub and an empty `docs/TEST-RESULTS.md`.
- `main` at the fixes-only commit is the build point that has already run green locally (section 6.3); once pushed, GitHub-hosted runs are refused by the billing lock, and the self-hosted lane (section 6.6) is what actually runs green in CI today, not the hosted lane that section 6.1 describes as the primary design. It is what section 16 rule 10 names as the pacing and drop-count control build, not `baseline/upstream`, which is comparison-only and nothing branches from it.
- The local `ATGEnsureShaders` failure is resolved: clearing `NoDefaultCurrentDirectoryInExePath` fixed it (section 6.3). No further action here.
- Exit criterion: a push or `workflow_dispatch` on `main` produces an artifact, the deploy job installs it (or cleanly skips on the credential gate), and `deploy-summary.json` is attached to the run as a job artifact. This has already happened locally. `main` already carries the fork workflow as of commit `020a440`, so no further push is needed for that; GitHub-hosted runs are refused by the account billing lock (section 6.6), and the `build` job runs on the self-hosted lane (`[self-hosted, xbox-lan]`) until the lock clears.

### Phase 1. Instrumentation

This is the phase that makes every later phase measurable. Do not skip it and do not shorten it.

**1a. A file logger.** There is none today (`Utils.cpp:16,62,65-66`). Add one.

- Sink: `ApplicationData::Current->LocalFolder`, subdirectory `logs`, file `moonlight-<yyyyMMdd-HHmmss>.log`, created at app start.
- It is pulled off the console with `GET /api/filesystem/apps/file?knownfolderid=LocalAppData&packagefullname=<pfn>&path=\logs&filename=<name>`, which is why `LocalState` and not a temp folder.
- Write-through on every line, or flush at least once per second. A crash must not lose the lines that explain it.
- Keep the existing `LOG_LINES` ring and `OutputDebugString` behavior intact. The file is additive. Rotate: keep the newest 10 files, delete older ones at start.
- **One line per state change, never per frame.** A per-frame log at 120 FPS produces 432000 lines an hour, fills the console's storage, and changes the timing it is supposed to measure. The whole point of the two helpers below is that they only speak when something changes.

**1b. `VideoRenderer::LogFrameColorState(const AVFrame* frame)`** (name from v0, kept). Called from the render path. It holds the last-logged tuple and emits nothing unless the tuple changes. The tuple is `color_trc`, `color_primaries`, `colorspace`, `color_range`, `format` (pix_fmt), width, height. One line, all seven fields, with both the numeric enum value and its name so a log is readable without the FFmpeg headers to hand.

**1c. `DeviceResources::ApplyColorSpace(DXGI_COLOR_SPACE_TYPE space)`** (name from v0, kept). The single place the swap chain color space is set. It calls `CheckColorSpaceSupport` and captures both the HRESULT and the returned support bitmask; calls `SetColorSpace1` regardless of what the check said and captures that HRESULT; logs one line with the requested space, the check HRESULT, the bitmask in hex, and the set HRESULT; returns success or failure to the caller; and does NOT update any cached state itself. The caller decides whether to cache. That is the exact bug at `VideoRenderer.cpp:190`, where the cache is updated even when nothing was applied.

**1d. Also log, once per occurrence:** every `SetDisplayHDR` transition with the before and after `HdmiDisplayMode` (resolution, refresh, bits per pixel, `IsSmpte2084Supported`, `ColorSpace`); every `ResizeBuffers` with the new dimensions and the HRESULT; every `HandleDeviceLost`; every stream start and stop with the negotiated `colorSpace` and `colorRange`; and the app's resource mode if it can be read.

Branch `experiment/hdr-instrumentation`. This branch is special: its change is additive and safe, so once it is proven it is merged into every later experiment branch rather than kept separate.

### Phase 2. Cheap discriminating tests, zero or near-zero code

Run these before writing any fix. Each is minutes of work and each can eliminate a hypothesis.

**2a. The compositor test.** Add a 1 by 1 pixel XAML element over the swap chain panel whose visibility toggles on a gamepad chord (View plus Menu held for one second, chosen because it has no existing binding in this app), with no menu, no flyout, no focus change. Watch the clipping point (about 1600 nits closed versus about 2200 nits open). If toggling a trivial XAML element moves the clipping point, H3 is confirmed and the cause is composition, not the swap chain color space. If it does not move, the quick menu's effect comes from something heavier than mere XAML presence and H3 needs a different probe.

**2b. The present-mode test.** `DeviceResources.cpp:527` currently calls `Present(0, 0)`. Build one variant with `Present(1, 0)` and compare. Sync interval 0 on a composition swap chain has different DWM behavior from sync interval 1, and the difference may show up in both the HDR result and the pacing. One-character change, cheap discrimination.

**2c. The Game-mode toggle.** Zero code. In Dev Home, switch the title's resource mode from App to Game (or flip "Treat UWP apps as games by default") and rerun the same build. Game mode gives about 5 GB of RAM, 4 exclusive cores plus 2 shared, and the full GPU, against App mode's roughly 1 GB foreground, 2 to 4 shared cores, and about 45 percent of the GPU. If the HDR or pacing result changes, resource starvation was part of the picture and the whole test matrix needs rerunning in Game mode. Record the mode in every `TEST-RESULTS.md` entry from here on, because a result recorded without the mode is not reproducible.

**2d. The VRR toggle.** Zero code. Flip Dev Home Settings, Display Settings, "Allow Variable Refresh Rate (VRR)" and rerun. Whether it reaches a sideloaded UWP app is UNCONFIRMED; this settles it for this console. Record the setting in every entry as well.

### Phase 3. HDR fixes, one per branch

**3A. Force PQ on every HDR frame.** Branch `experiment/hdr-force-pq`. Replace the `CheckColorSpaceSupport` gate with a direct `SetColorSpace1`, keep the HRESULT log, and update `m_LastColorTrc` only on success. This is PR #281's core idea reduced to its minimum.

**3B. The PR #281 port.** Branch `experiment/hdr-pr281`. The diff does not apply (`VideoRenderer.cpp:159`, `VideoRenderer.h:97`), so this is a rewrite against the current `main` tree, done by hand, never `git cherry-pick 9704eb0` and never `git apply` of the PR's raw diff:

- Add to `VideoRenderer.h` after `hasFrameFormatChanged`: `bool frameUsesHdrColorSpace(const AVFrame* frame) const;` and `void applySwapChainColorSpace(const AVFrame* frame);`
- Add the member `bool m_SwapChainHdrColorSpace = false;` after `m_LastChromaLocation`.
- Replace the block at `VideoRenderer.cpp:170-191` with a single `applySwapChainColorSpace(frame);`.
- Implement `frameUsesHdrColorSpace()`: true for `AVCOL_TRC_SMPTE2084`; false when neither `configuration->enableHDR` nor `client->IsHDR()`; otherwise true for `AVCOL_TRC_UNSPECIFIED` and `AVCOL_TRC_BT709`.
- Implement `applySwapChainColorSpace()` to early-return when nothing changed, call `SetColorSpace1` directly through `DeviceResources::ApplyColorSpace` from phase 1c, and update both cached members only on success.
- Append the `SetHDR` hunk: reset `m_LastColorTrc` to `AVCOL_TRC_UNSPECIFIED`, set `m_SwapChainHdrColorSpace = !enabled`, then apply the space directly and log both branches.
- Ordering dependency: 3B subsumes 3A. Run 3A first because it is smaller and isolates the `CheckColorSpaceSupport` variable alone; run 3B second to add the transfer-characteristic heuristic on top. If 3A alone fixes it, 3B's heuristic is unnecessary complexity and should not be merged.

**3C. Reapply after `ResizeBuffers`.** Branch `experiment/hdr-reapply-resize`. After the successful resize at `DeviceResources.cpp:214`, call `ApplyColorSpace` with the last known good space.

**3D. Reapply after device recreation.** Branch `experiment/hdr-reapply-device-lost`. Same, after `HandleDeviceLost` at `DeviceResources.cpp:486` completes.

### Phase 4. VRR proof of concept

Five steps, from v0 section 10, rewritten in section 10 of this plan against the memo findings. Branch `experiment/vrr-allow-tearing`. The expected outcome is a receipted negative.

### Phase 5. SDR colorspace

Section 9. Branch `experiment/sdr-rec709`.

### Phase 6. Composition alternatives

Only if phase 2a confirmed H3. Branch `experiment/vrr-direct-render`, then `feature/directx-streaming-mode`. Three candidates, all UNCONFIRMED: `CoreApplication::CreateNewView()` plus `CreateSwapChainForCoreWindow`, giving a swap chain that is not composed with a XAML tree; a bare CoreWindow DirectX-only view with no overlapping XAML at all; `Windows.UI.Composition` with a `SpriteVisual` and a `CompositionSwapChain` configured with HDR-aware flags. Each is a separate spike with its own notes file. None is adopted without a measured improvement over the phase 3 result.

### Phase 7. Pacing

Section 11. Branch `feature/vplus-pacer`.

### Phase 8. Host capabilities and bitrate

Sections 12 and 13. Branches `feature/foundation-hdr-capabilities` and `feature/dynamic-bitrate`.

---

## 9. SDR colorspace: Rec.601 against Rec.709

### The finding

`State/MoonlightClient.cpp:262` reads `config.colorSpace = COLORSPACE_REC_601;`. It is a literal with no condition around it. Every stream this client requests, SDR or HDR, 720p or 4K, asks the host for Rec.601. The adjacent line `:261` does the right thing for range: `config.colorRange = this->IsRGBFull() ? COLOR_RANGE_FULL : COLOR_RANGE_LIMITED;`.

The renderer is not the limitation. `Streaming/VideoRenderer.cpp:495-558` implements the conversion for Rec.601, Rec.709 and Rec.2020, with `:531` handling `COLORSPACE_REC_601` and `:551` producing the log string. `:460` and `:469` return `COLORSPACE_REC_601` as the fallback in the frame-to-space mapping, a second place where 601 is assumed rather than derived.

### Why it matters

Rec.601 and Rec.709 use different YUV to RGB matrices. Decoding Rec.709 content with a Rec.601 matrix produces a visible shift: greens and reds move, skin tones shift, saturation changes. It is subtle enough to be mistaken for a display calibration difference and it is exactly the kind of error that survives for years because everyone assumes the other end is at fault.

Whether the host honors the request matters too. Foundation's `video_colorspace.cpp` carries `colorspace_e {rec601, rec709, bt2020sdr}`, and `bt2020sdr` falls back to `rec709` with an error log when the stream is not 10-bit. So the host has a real decision path here and the client is feeding it a constant.

### The experiment

Branch `experiment/sdr-rec709`.

1. With the phase 1 logger in place, start an SDR stream on an unmodified build and record the client's `LogFrameColorState` line: the frame's actual `colorspace`, `color_primaries`, `color_trc` and `color_range`.
2. Read the host's own log for the negotiated colorspace on the same session and record the literal line. Do not assume it says what section 3.16 predicted; the string "H.264 SDR Rec.601 8-bit JPEG" was searched for and not found, so quote whatever the host actually prints.
3. Change `:262` to `COLORSPACE_REC_709`. Build, deploy, rerun the same stream, capture the same two log lines.
4. Compare with a fixed color chart on the host desktop, photographed from the same position with the same camera settings in both runs. A side-by-side of the same chart is the evidence; an impression is not.
5. If the host's negotiated colorspace changes with the client's request, the client was driving it and the constant is a real bug. If the host ignores it, the constant is harmless on this host and should still be fixed, because another host will honor it.

Follow-up, not part of this experiment: derive the value rather than hardcoding a different constant. Rec.709 for SDR, Rec.2020 when `VIDEO_FORMAT_H265_MAIN10` is requested. That change lands only after the experiment shows what the host does with each value. Also fix in the same branch, if the experiment confirms the host honors the request: the fallbacks at `VideoRenderer.cpp:460` and `:469` should fall back to Rec.709, not Rec.601, for anything that is not standard-definition.

---

## 10. VRR, rewritten against the evidence

### What v0 assumed

v0 section 7 pointed at `State/Stats.h`'s `SyncMode` enum, including `VRR_SUPPORTED = (1 << 2)` and `VRR_ON = (1 << 3)` with its comment "we're using ALLOW_TEARING Present mode in fullscreen mode (not yet possible)", and treated restoring the removed tearing code as the path to VRR.

### What the evidence says

1. **The UWP display API has no VRR surface at all.** `HdmiDisplayMode` exposes `RefreshRate` as a single scalar and nothing else rate-related; `HdmiDisplayInformation` exposes mode enumeration and mode setting and nothing else (full member lists in section 3.20). A sideloaded UWP app cannot query whether VRR is active, cannot request it, and cannot detect the display's supported refresh range.
2. **The swap chain is a composition swap chain.** `DeviceResources.cpp:280` calls `CreateSwapChainForComposition` and `:306` binds it to the XAML panel. `DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING` is documented for flip-model swap chains presenting to a window or fullscreen; a composition swap chain composited by DWM does not present directly to the scanout. Whether `DXGI_FEATURE_PRESENT_ALLOW_TEARING` is even queryable from an Xbox UWP composition process is UNCONFIRMED, and nothing in this codebase has ever asked.
3. **There is no removed tearing code to restore.** The history has `33141c5` adding something and `d4822e7` removing it, but `3993f9a` "Reintroduce Xbox One Tearing hack" is a 12 millisecond `usleep()` inside the FFmpeg decode loop, gated on `IsXboxOne()` AND `LiGetPendingVideoFrames() < 2`. It is a latency hack for a specific old console, it explicitly does not run on Series X|S, and it has nothing to do with `ALLOW_TEARING`.
4. **The device-wide toggle exists but its reach is unknown.** Dev Home Settings, Display Settings has "Allow Variable Refresh Rate (VRR)". Whether it applies to a sideloaded Dev Mode UWP app is UNCONFIRMED.

### The rewritten scope

Scope VRR as: make the app's presentation as VRR-friendly as possible and hope the OS applies it, then measure the TV and record what happened. The app cannot control VRR. It can only avoid fighting it.

### The five-step probe, branch `experiment/vrr-allow-tearing`

1. **Query.** Add an `IDXGIFactory5::CheckFeatureSupport(DXGI_FEATURE_PRESENT_ALLOW_TEARING, ...)` call at factory creation (`DeviceResources.cpp:125` creates the factory) and log the HRESULT and the returned BOOL. This has never been asked on this hardware. Whatever it returns is a new fact and goes straight into section 3.
2. **Flag.** If step 1 reports support, set `DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING` at `DeviceResources.cpp:254` (currently `Flags = 0`) and log whether `CreateSwapChainForComposition` at `:280` still succeeds. A failure here is itself the answer: composition swap chains do not take the flag.
3. **Present.** If step 2 succeeded, change `:527` from `Present(0, 0)` to `Present(0, DXGI_PRESENT_ALLOW_TEARING)` and log the HRESULT. `DXGI_ERROR_INVALID_CALL` here is the expected failure and is a receipt.
4. **Toggle.** With the best build from steps 1 to 3, run once with the Dev Home VRR toggle on and once with it off, and once each in App and Game resource mode. Four runs, same stream, same content.
5. **Measure the TV.** Use the TV's own refresh-rate readout. v0's acceptance criterion is that the TV tracks the stream: at 118, 112, 104, 117 and 119 FPS the readout should follow. Photograph the readout. A claim that VRR works without a photograph of the TV's own rate display is not evidence.

### The likely outcome, stated in advance so a negative result is not read as a failure

The most probable result is that step 2 or step 3 fails and VRR is unreachable on the composition path. That is a valuable, receipted, publishable finding and it feeds the central question directly: if VRR needs a non-composition presentation path and HDR also needs one (H3), the two requirements converge on the same rewrite and the rewrite is justified. If VRR is unreachable and HDR is fixed on the composition path, the rewrite is not justified and VRR is documented as out of reach for a sideloaded Dev Mode app.

Also do, regardless of outcome: wire `SyncMode` to something real or delete it. Dead scaffolding with a comment claiming impossibility misleads every future reader.

---

## 11. Frame pacing

### Current implementation

`Streaming/Pacer.cpp`, 434 lines. A dedicated thread calls `m_DeviceResources->GetDXGIOutput()->WaitForVBlank()` at `:134`. Two render paths exist: immediate (`:242-271`) and display-locked (`:293-330`). Queue depth drives an extra drain in both (`:253-255` and `:299-305`). The 120 Hz case takes a half-vblank cadence at `:200`. The header comment at `:20-30` states the design: drop at enqueue time, alternating, past a high water mark of 2 plus 1; align presentation to the next vblank or half-vblank.

### What to port from Moonlight V+

From `FramePacingController.kt`, the algorithm only. The Kotlin and MediaCodec specifics do not port.

- **Two-stage cadence snap.** Stage one estimates the host's frame cadence from arrival times; stage two snaps the chosen release time onto that cadence rather than onto the local vblank alone. The current pacer only knows the local vblank, so a host at 119.88 FPS against a 120 Hz panel produces a slow beat the current design cannot absorb.
- **Measure refresh from delivered timestamps, not from a queried mode.** V+ derives the real refresh from the `frameTimeNanos` it is handed. The equivalent here is deriving it from `WaitForVBlank` return intervals, not from `HdmiDisplayMode::RefreshRate`.
- **Hold early, release or drop late.** The current code drops on queue depth; V+ decides per frame based on where the frame sits relative to the snapped cadence.
- **Queue-depth adaptation as a feedback term**, not a fixed threshold.
- Named modes and tunables in V+ were NOT re-quoted for this plan and must be pulled from the source before any of them is cited or implemented.

### Cross-check against moonlight-qt

`pacer.cpp` there uses a dual-queue design with a `renderThread` and a `vsyncThread`, `submitFrame()`, `handleVsync()`, and an adaptive `frameDropTarget`. The adaptive drop target is the piece most obviously missing here, where the high water mark is fixed.

### Measurement, which comes before any change

- Add a pacing trace to the phase 1 file logger: one line per second, not per frame, carrying mean and p99 frame interval, queue depth mean and max, frames dropped in the interval, and the measured vblank interval.
- Establish the baseline on `main` at the fixes-only commit, untouched by any pacing experiment, before touching `Pacer.cpp` (section 5's branch rules, section 16 rule 10).
- Test at 60, 90, 120 FPS host settings (the host's configured fps list is `[59.94, 60, 90, 120, 144]`), and in both App and Game resource mode, because phase 2c may show that pacing is partly a resource problem.
- Branch `feature/vplus-pacer`. Accept a change only when the trace shows a measured improvement in p99 frame interval or dropped-frame count. An impression of smoothness is not a result.

---

## 12. Foundation host HDR capability settings

### The three layers that all have to be right

1. **DXGI swap chain color space** on the client. Sections 3.2, 3.3, phases 3A to 3D.
2. **moonlight-common-c stream configuration and HDR metadata.** `STREAM_CONFIGURATION` carries only `colorSpace` and `colorRange`; HDR metadata rides separately through `LiGetHdrMetadata()` and `SS_HDR_METADATA`. Section 3.18.
3. **nvhttp launch parameters.** `hdrMode`, `maxBrightness`, `minBrightness`, `maxAverageBrightness`, `sdrBrightness`. Section 3.16.

A fix in any one layer with the other two wrong produces a partially correct image, which is exactly the reported symptom. Do not test one layer in isolation and conclude anything global from it.

### The host side as configured today

`hdrBrightnessMode` is manual with a maximum of 1000 nits. The captured display reports `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020` with luminance 0 / 1690 / 1690. So the host is currently told 1000 nits by hand while the display it captures reports 1690.

That discrepancy is worth one deliberate experiment on its own, before any client code changes: set `hdrBrightnessMode` to match the captured display's 1690 and rerun. This run is diagnostic, one run only. If the clipping point moves, part of the reported clipping is host tone mapping, not client presentation. Restore `hdrBrightnessMode` to manual 1000 before any other test runs, so every later result is measured against the host's normal configuration. Record both the 1000 and the 1690 values, and which one was active, in `TEST-RESULTS.md`.

### The client-side work, branch `feature/foundation-hdr-capabilities`

Foundation resolves an effective target from `target_source_e {client_report, manual_override, windows_hdr_calibration, safe_defaults}` in `session_target.cpp`. `client_report` is the branch this work targets: have the client send its real display capabilities so the host stops using a manual override or a default.

- Read the console's actual display capability from `HdmiDisplayMode`: `IsSmpte2084Supported`, `Is2086MetadataSupported`, `IsSdrLuminanceSupported`, `BitsPerPixel`, `ColorSpace`.
- Map those to the `hdrMode`, `maxBrightness`, `minBrightness`, `maxAverageBrightness` and `sdrBrightness` launch query parameters.
- Note what is missing: `HdmiDisplayMode` does not expose peak luminance in nits. The UWP API gives boolean capability flags, not the HDR static metadata the host wants, so the client cannot report real nit values from the display alone. Options in order of preference: expose the values as app settings the user sets once, defaulting to the console's own HDR calibration if it can be read (UNCONFIRMED whether it can); send only what is known (`hdrMode` and nothing else) and let the host fall back; or send nothing and leave the host on `manual_override`.
- The per-client override keyed by certificate-derived UUID is UNCONFIRMED. The host already knows this client as uuid `C70DDA76-6F39-DF02-5D14-F085420AC711` under the name "XBOX", so a per-client host-side override is available as a fallback that needs no client change at all.

This work is phase 8 and deliberately late. It cannot be evaluated until the client presents PQ correctly, because until then every change here is judged through a broken display path.

---

## 13. Dynamic bitrate

Short section, deliberately. This is the lowest-priority goal and it must not consume attention that belongs to HDR.

- Branch `feature/dynamic-bitrate`.
- moonlight-common-c already reports what is needed to drive this: pending frame count via `LiGetPendingVideoFrames()`, plus the connection status callbacks the client already wires (`connection_terminated` at `MoonlightClient.cpp:396`, `connection_set_hdr` at `:390`).
- The stream is configured once at `MoonlightClient.cpp:255-275`. Changing the bitrate mid-stream requires either a protocol-level mechanism or a stream restart. Which of these Foundation supports is UNCONFIRMED and must be established before any client code is written.
- Minimum viable version: detect sustained packet loss or decode queue growth, log it, and surface it in the stats overlay. Observation before actuation.
- Do not start this before phases 1 through 5 have results in `TEST-RESULTS.md`.

---

## 14. Test matrix and results

### 14.1 The matrix

Every run varies exactly one axis from the previous run. A run that changes two things measures nothing.

Axes: branch and build number (from `build-info.json`); host codec (HEVC Main10 HDR, HEVC SDR, H.264 SDR); resolution and frame rate (4K60, 4K120, 1080p60, 1080p120); HDR on or off; console resource mode (App, Game); Dev Home VRR toggle (on, off); quick menu (closed, open, per the 1600 against 2200 nit observation); host `hdrBrightnessMode` (manual 1000, manual 1690).

Not every combination runs. The standard sweep per experiment branch is three runs: 4K60 HDR in Game mode with the menu closed, the same with the menu open, and 1080p60 SDR in Game mode. Extra runs only when a result is ambiguous.

### 14.2 `docs/TEST-RESULTS.md` template

Each branch carries its own. Append, never rewrite. One block per console run.

```
## Run <n>: <branch> build <run_number> (<commit sha short>)
- Date (local):
- Hypothesis under test: H<n>
- Host: Foundation Sunshine, capture vdd, output ZakoHDR, hdrBrightnessMode <mode> <nits>
- Stream: <codec> <resolution>@<fps>, HDR <on|off>
- Console: resource mode <App|Game>, Dev Home VRR <on|off>
- Quick menu during measurement: <closed|open>

### Measured
- Client log lines (verbatim, from LocalState\logs\<file>):
- Host log lines (verbatim):
- TV refresh readout: <value> (photo: <filename>)
- Clipping onset: <nits> (measurement method: <how>)
- Frame interval mean / p99: <ms> / <ms>
- Frames dropped in 60 s: <n>

### Verdict
- H<n>: <confirmed|refuted|inconclusive>
- Reason:
- Next run:

### Untested in this run
- <anything the run did not exercise, named explicitly>
```

The "Untested in this run" block is mandatory and must not be empty. A run always leaves something unmeasured, and naming it is what stops a later reader from assuming coverage that does not exist.

### 14.3 HDR acceptance criteria, from v0 section 18

1. An HDR stream presents PQ pixels as PQ: no washed-out or grayish overall cast.
2. The client log shows `SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020)` returning S_OK on the first HDR frame of every session.
3. That line appears again after any `ResizeBuffers` and after any device-lost recovery in the same session.
4. Highlight clipping onset is the same with the quick menu closed as with it open. The 1600 against 2200 nit gap is gone.
5. Clipping onset matches the host's configured maximum luminance, not an arbitrary lower value.
6. The HDMI display mode reported by `SetDisplayHDR` matches the swap chain color space at every point in the session.
7. Ending an HDR stream returns the display to SDR (the H6 fix).
8. An SDR stream after an HDR stream in the same app session renders correctly.
9. Side-by-side with another Moonlight client on the same host and TV, the images match.
10. No new error HRESULTs in the client log across a 30 minute session.

### 14.4 VRR acceptance criteria, from v0 section 19

- The TV's own refresh readout tracks the stream frame rate: at 118, 112, 104, 117 and 119 FPS the readout follows rather than staying pinned at 120.
- Confirmed by a photograph of the TV's readout, per run.
- If unreachable, the acceptance criterion becomes a receipted negative: the exact HRESULT or failure from each of the five probe steps in section 10, recorded in `docs/experiments/vrr-allow-tearing.md`.

### 14.5 Pacing acceptance criteria

- p99 frame interval within 10 percent of the mean across a 5 minute stream.
- No sustained queue depth growth across the same window.
- Dropped-frame count not worse than `main` at the fixes-only commit on the same content.

---

## 15. Priority order

v0 section 28's 11 items, corrected against the evidence. Corrections are marked.

1. Build lane on the fork, including the fork certificate step. *Corrected: v0 assumed the inherited workflow would build on the fork; it cannot, because neither cert step fires.*
2. Deploy lane over the Device Portal, with the credential gate exiting 0. *Corrected: v0 assumed WinAppDeployCmd.*
3. File logging plus the two named helpers. *Raised: v0 had instrumentation inside phase 1 but did not know that no file logging exists at all, which makes every later phase unmeasurable without it.*
4. Build of `main` at the fixes-only commit deployed to the console as the working baseline. *Corrected twice: v0 expected to compare against an existing install, but the dev partition is empty; and the deployed control build is `main`, not `baseline/upstream`, because `main` is what actually builds and what every experiment branches from (section 5).*
5. The cheap phase 2 discriminating tests, including the zero-code Game-mode and VRR toggles. *Added: these did not exist in v0 and each can eliminate a hypothesis for almost nothing.*
6. HDR force-PQ (3A), then the PR #281 port (3B). *Corrected: v0 put the PR #281 cherry-pick first; it does not apply and 3A isolates the variable better.*
7. HDR reapply after resize (3C) and after device loss (3D).
8. SDR Rec.601 against Rec.709. *Raised: v0 had it late; it is a one-line change with a confirmed receipt at `MoonlightClient.cpp:262` and may be a real user-visible bug on every SDR stream.*
9. VRR probe, expecting a receipted negative. *Corrected in scope: see section 10.*
10. Composition alternatives and the DirectX streaming mode, only if phase 2a confirmed H3.
11. Pacing, then Foundation HDR capabilities, then dynamic bitrate.

The central question sits between items 9 and 10 and is answered by the results of items 5 through 9 taken together.

---

## 16. AI execution rules

### v0's 15 instructions, preserved

1. One experiment per branch. Never combine two changes in one branch.
2. Every branch must build before it is deployed.
3. Never claim a result that was not measured on the console.
4. Record every run in `TEST-RESULTS.md` before starting the next one.
5. Read the code before changing it; cite `file:line` for every claim about it.
6. Prefer the smallest change that discriminates between two hypotheses.
7. When a hypothesis is refuted, write down that it was refuted. A refuted hypothesis is a result.
8. Do not fix the symptom by changing the TV, the host calibration, or a picture mode.
9. Log state changes, never every frame.
10. Keep two controls untouched: `main` at the fixes-only commit is what pacing and drop-count comparisons run against, because it is what actually builds and what every experiment branches from; `baseline/upstream` stays the pristine pre-fork reference, comparison only, nothing branches from it (section 5).
11. Do not modify submodules.
12. Do not open an upstream pull request without a measured result.
13. When blocked, name the blocked gate exactly and continue with everything that does not depend on it.
14. Ask the owner for exactly one thing at a time, and only for things no agent can do.
15. Leave the console in a working state at the end of every session.

### Added by this revision

16. **Model tiers.** haiku for mechanical fully specified steps (exact find-and-replace edits, extracting log lines, filling a results template). sonnet for ordinary bounded work (implementing a phase, writing a deploy script, a recon sweep). opus only for genuine judgment (choosing between composition architectures, diagnosing a build failure with no obvious cause). fable only for adversarial review. Never fan out on fable. Never spawn opus or fable from a subagent; escalate to the caller instead.
17. **Verify delegated output with a direct check.** A run, a grep, a diff, an exit code. A cheaper tier means a stricter check, not a looser one.
18. **Fable review gate.** Before any change that persists outside the working clone (a push, a PR, a release), an adversarial review runs first and every finding is either fixed or waived with one line of reasoning.
19. **Receipts over predictions.** A plan, report, or notes file may record only what actually ran. A reasoned expectation goes in a separate sentence that says it is an expectation. A test whose pass condition is "no crash" proves nothing and is not evidence.
20. **Never print or commit credentials.** Not portal credentials, not certificate passwords, not tokens, not a partial or redacted form of any of them. Naming the file path `C:\Users\ygordreyer\.xbox-deploy\credentials.json` is fine; reading its contents into any output is not.
21. **Never expose the Device Portal.** LAN only. No tunnel, no port forward, no proxy, no matter how convenient it would make a remote test.
22. **Never run fork PRs on the self-hosted runner.** Keep the approval policy in place and keep the build job on GitHub-hosted runners.
23. **Keep every branch buildable.** A branch that does not compile cannot be tested and is not an experiment.
24. **Update `TEST-RESULTS.md` after every console run**, in the same working session, before starting the next run.
25. **Blocked-gate handling.** When a gate needs the owner, record it in section 17 with a copy-ready command, queue every remaining task that does not depend on it, and keep working. Do not stop the project on a gate.
26. **Do not re-probe a settled fact.** The Device Portal credential state is known (uninitialized, HTTP 200 with the "Credentials have not been set up" message everywhere). Re-probing wastes time and produces noise. Wait for the gate.
27. **Record the console's resource mode and VRR toggle in every result.** A result without them is not reproducible.
28. **Never edit `docs/PLAN.md` from an experiment branch.** It lives on `main`, not `master` (section 5). Experiment notes go in `docs/experiments/<name>.md`.
29. **No git worktrees.** An agent working on this plan or its code never creates a git worktree. "Worktree" in any instruction to an agent on this project means a new session or task, never `git worktree add`.
30. **Isolated patches, applied serially.** When more than one agent is producing changes to the same file, each works from its own copy or staged patch, and patches are applied one at a time, never concurrently, so a later apply always starts from the result of the one before it.
31. **A main-session review gate before every push.** No push to any branch in this repository happens without the orchestrating session reviewing the diff first, the same gate rule 18 already states for the fable adversarial review; rule 18 and this rule are the same gate, stated twice for emphasis, not two separate approvals.
32. **Ledger writes only through the openitems CLI.** Any open item, decision, or waiver for this project that needs to outlive a session is written through the ledger tooling already in use for the owner's other projects, never by hand-editing a ledger file directly.
33. **No pushes to a deploying branch during a manual console test sweep.** While the owner is at the console running a manual test pass (section 14), nothing pushes to the branch currently deployed there; a push mid-sweep changes what is running under the owner's hands without their knowledge. Every test result recorded in `TEST-RESULTS.md` names the deploying run's `run_number` (from `build-info.json`), so a result can always be tied back to the exact build that produced it.

---

## 17. Blocked gates and open questions

### Gate 1. Device Portal credentials. THE ONE ASK. OPEN.

The console's Device Portal answers HTTP 200 on every endpoint with the body "Windows Device Portal: Uninitialized. Credentials have not been set up...". No REST call can do anything until credentials exist.

What the owner does, once, at the console:

1. Xbox Dev Home, Remote Access Settings.
2. Set a username and a password. **Start the username with `auto-`** (for example `auto-deploy`). The portal exempts usernames beginning `auto-` from the CSRF token requirement, which makes the deploy script simpler and removes a class of failure.
3. Write them into `C:\Users\ygordreyer\.xbox-deploy\credentials.json` on this PC as `{"consoleAddress": "192.168.18.20", "username": "...", "password": "..."}`. All three keys are required: `Resolve-DeployCredential` in `tools/xbox-deploy.ps1` throws if any one of `consoleAddress`, `username`, or `password` is missing (section 7.3).

Until this exists, `tools/xbox-deploy.ps1` exits 0, writes `deploy-summary.json` with `skipped=true, reason='no credentials configured'`, and the build pipeline stays green. Everything in phases 0 and 1 that does not need the console proceeds. Do not re-probe the portal before this is done.

### Gate 2. Repository signing secrets. CLOSED.

`SIGNING_PFX_BASE64` and `SIGNING_PFX_PASSWORD` are set as repository secrets on `ygordreyer/moonlight-xbox-plus` (provenance commands in section 18.1, marked done, never to be rerun). The certificate subject is `CN=CE07B73A-712E-4E05-932B-D08CE2C8A87C`, thumbprint `2FE3549ACE299557AACC02A3D36C996B544EF901`, `NotAfter` 2031-09-14, and `moonlight-xbox-dx.vcxproj:139` now hardcodes this thumbprint. Nothing here waits on the owner.

### Gate 3. The gh token exposure item

An earlier session's git credential helper was configured with a double-quoted form that expanded eagerly and wrote the live gh OAuth token in plaintext into `.git/config` and into a subagent transcript. The helper has been unset and re-added in the lazy single-quoted form, so no further writes occur. Exposure is limited to local files on this machine: the repository config (now fixed) and a session transcript. No remote received it. Rotation requires the owner. No agent rotates the owner's tokens. Recorded here so it is not lost; it blocks nothing in this plan.

### Gate 4. Local build failure. CLOSED.

`third_party\DirectXTK\DirectXTK_Windows10_2022.vcxproj(450,5)`, target `ATGEnsureShaders`, MSB3073, `'CompileShaders' is not recognized`, exit 9009, was caused by the Claude Code harness setting `NoDefaultCurrentDirectoryInExePath=1`, which breaks `CompileShaders.cmd`'s lookup through cmd.exe's current-directory search. Clearing that environment variable fixed it (section 6.3). The local build is GREEN as of 2026-09-14. Nothing here waits on the owner.

### Gate 5. Upstream CI. CLOSED: cause known, fix ready.

Run 34136005241 failed at the Build step after 1m24s on a C2664 error at `FFmpegDecoder.cpp:628`, `CaptureAvioWrite`'s buffer constness mismatched against libavformat 59, the version the prebuilt `vcpkg_installed.zip` actually supplies (section 6.4, section 6.5). The fix is a version guard already applied as uncommitted working-tree changes to `FFmpegDecoder.h` and `.cpp`, landing on `main` in the fixes-only commit named in section 0. Nothing here waits on the owner.

### Gate 6. GitHub Actions billing lock. OPEN, but not blocking CI.

The account owning this fork (`ygordreyer/moonlight-xbox-plus`) has an Actions billing lock (6.6 has the full symptom, receipts, and mechanism). What is blocked: GitHub-hosted jobs only (`runs-on: windows-2022`). What still runs: the `build` job on the self-hosted lane (`[self-hosted, xbox-lan]`, temporary, section 6.6) and the `deploy` job, which was already self-hosted by design (7.1); the CI chain from push to deploy is live end to end today, it just never touches a hosted runner. Unlock: only the account owner, at https://github.com/settings/billing. Post-unlock actions, both ledger items already named in 6.6: revert the `build` job's `runs-on` to `windows-2022` once one hosted run is green, and delete the `ci/runner-probe` branch and its workflow file. Nothing here blocks any phase in this plan; it blocks only the section 6.1 hosted lane returning to primary.

### Open questions, each needing one experiment or one read

- Does `-SkipCertificateCheck` work against the console's portal? (Answered by gate 1's first call.)
- Can WDP authentication be disabled entirely on Xbox Dev Mode? UNCONFIRMED and not needed if gate 1 completes.
- What HTTP verbs do the `/ext/` endpoints take? UNCONFIRMED. Only `/ext/screenshot` is likely useful here, for capturing the console's own view of a test.
- Does `CheckFeatureSupport(DXGI_FEATURE_PRESENT_ALLOW_TEARING)` even return on an Xbox UWP composition process? UNCONFIRMED. Section 10 step 1 answers it.
- Does the Dev Home VRR toggle reach a sideloaded UWP app? UNCONFIRMED. Section 10 step 4 answers it.
- What is on the upstream `hdr2` branch? Unread. One `git log` and one diff answers it, and it may contain work that predates PR #281.
- Does Foundation support a mid-stream bitrate change? UNCONFIRMED. Blocks section 13.
- Does the client's `colorSpace` request actually change what Foundation encodes? UNCONFIRMED. Section 9 answers it.
- Can the console's own HDR calibration values be read from a UWP app? UNCONFIRMED. Affects section 12's options.
- Does `SimpleHDR_UWP12` exist? Only a web search snippet suggests it; UNCONFIRMED. `SimpleHDR_UWP` does exist but its guidance is deferred to a Word document that could not be read.

---

## 18. Appendix

### 18.1 Setting the repository signing secrets

Run on this PC with the `gh` CLI authenticated to the account that owns the fork. The prompt form reads the password without echoing it.

```powershell
# Export the certificate once, from an elevated PowerShell, if it does not exist yet.
# Subject MUST be exactly CN=CE07B73A-712E-4E05-932B-D08CE2C8A87C to match Package.appxmanifest:12
$cert = New-SelfSignedCertificate `
  -Type Custom `
  -Subject "CN=CE07B73A-712E-4E05-932B-D08CE2C8A87C" `
  -KeyUsage DigitalSignature `
  -FriendlyName "MoonlightXboxPlus" `
  -CertStoreLocation "Cert:\LocalMachine\My" `
  -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")

$pw = Read-Host -AsSecureString "PFX password"
Export-PfxCertificate `
  -Cert "Cert:\LocalMachine\My\$($cert.Thumbprint)" `
  -FilePath "C:\Users\ygordreyer\.xbox-deploy\signing.pfx" `
  -Password $pw
```

```powershell
# Upload as repository secrets. The base64 never appears on screen.
$b64 = [Convert]::ToBase64String(
  [IO.File]::ReadAllBytes("C:\Users\ygordreyer\.xbox-deploy\signing.pfx"))
$b64 | gh secret set SIGNING_PFX_BASE64 --repo ygordreyer/moonlight-xbox-plus
gh secret set SIGNING_PFX_PASSWORD --repo ygordreyer/moonlight-xbox-plus
```

The second `gh secret set` prompts for the value on stdin so the password is never an argument.

### 18.2 Base64 encoding for the task manager endpoints

`POST /api/taskmanager/app` takes `appid` and `package` as base64-encoded UTF-8. `tools/xbox-deploy.ps1`'s `Start-DevicePortalApp` function does this with `[Convert]::ToBase64String`, not hex; an earlier draft of this plan called it "hex64" and that was wrong.

```powershell
function ConvertTo-WdpBase64([string]$s) {
  [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s))
}

# Values come from GET /api/app/packagemanager/packages
# The version string below is illustrative only: the deploy script always reads
# PRAID and PackageFamilyName from the live packagemanager response, never from a
# hardcoded version number.
$praid = "50497EliaZammuto.MoonlightUWP_<hash>!App"
$pfn   = "50497EliaZammuto.MoonlightUWP_1.18.1.0_x64__<hash>"
$appidB64   = ConvertTo-WdpBase64 $praid
$packageB64 = ConvertTo-WdpBase64 $pfn
```

### 18.3 Device Portal calls, one per endpoint

Reference only. These lines exist inside `tools/xbox-deploy.ps1`. An agent never pastes them into an interactive shell; the script is the one thing that runs them, and running a fragment by hand risks sending a bare credential to a terminal history or a transcript.

All examples assume `$ip = "192.168.18.20"` and `$port = 11443`. `-SkipCertificateCheck` requires PowerShell 7 and is UNCONFIRMED as a WDP-specific instruction; expect it to work and verify on the first call.

```powershell
$base = "https://$($ip):$($port)"
$creds = Get-Content "C:\Users\ygordreyer\.xbox-deploy\credentials.json" | ConvertFrom-Json
$pair  = "$($creds.username):$($creds.password)"
$auth  = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = $auth }
# Never print $pair, $auth, or $headers.
```

```powershell
# List installed packages
Invoke-RestMethod -Uri "$base/api/app/packagemanager/packages" -Headers $headers -SkipCertificateCheck
```

```powershell
# Install state (200 = last result, 204 = running, 404 = none attempted)
Invoke-WebRequest -Uri "$base/api/app/packagemanager/state" -Headers $headers -SkipCertificateCheck -SkipHttpErrorCheck
```

```powershell
# Uninstall
Invoke-RestMethod -Method Delete `
  -Uri "$base/api/app/packagemanager/package?package=$([uri]::EscapeDataString($pfn))" `
  -Headers $headers -SkipCertificateCheck
```

```powershell
# Launch, then stop
Invoke-RestMethod -Method Post -Uri "$base/api/taskmanager/app?appid=$appidB64&package=$packageB64" -Headers $headers -SkipCertificateCheck
Invoke-RestMethod -Method Delete -Uri "$base/api/taskmanager/app?package=$packageB64&forcestop=yes" -Headers $headers -SkipCertificateCheck
```

```powershell
# List the app's LocalState log directory
Invoke-RestMethod -Uri ("$base/api/filesystem/apps/files" +
    "?knownfolderid=LocalAppData" +
    "&packagefullname=$([uri]::EscapeDataString($pfn))" +
    "&path=" + [uri]::EscapeDataString("\logs")) `
  -Headers $headers -SkipCertificateCheck
```

```powershell
# Pull one log file
Invoke-WebRequest -Uri ("$base/api/filesystem/apps/file" +
    "?knownfolderid=LocalAppData" +
    "&packagefullname=$([uri]::EscapeDataString($pfn))" +
    "&path=" + [uri]::EscapeDataString("\logs") +
    "&filename=$([uri]::EscapeDataString($name))") `
  -Headers $headers -SkipCertificateCheck -OutFile $localPath
```

```powershell
# Live process list (also upgradeable to a WebSocket at 1 Hz)
Invoke-RestMethod -Uri "$base/api/resourcemanager/processes" -Headers $headers -SkipCertificateCheck
```

The install call is a multipart POST and is not a one-liner; its shape is specified in section 7.3 step 6 (`Install-DevicePortalPackage`) and belongs in `tools/xbox-deploy.ps1`, not in an ad hoc command.

### 18.4 CSRF handling, if the username does not start with `auto-`

Reference only. These lines exist inside `tools/xbox-deploy.ps1`. An agent never pastes them into an interactive shell.

```powershell
$session = $null
Invoke-WebRequest -Uri "$base/api/app/packagemanager/packages" `
  -Headers $headers -SkipCertificateCheck -SessionVariable session | Out-Null
$csrf = ($session.Cookies.GetCookies($base) | Where-Object { $_.Name -eq 'CSRF-Token' }).Value
$headers['X-CSRF-Token'] = $csrf
# Never log $csrf.
```

If the username begins with `auto-`, skip this entirely. The portal exempts it.

### 18.5 Branch creation

```powershell
cd F:\GitHub\moonlight-xbox-plus
$branches = @(
  'experiment/hdr-instrumentation',
  'experiment/hdr-pr281',
  'experiment/hdr-force-pq',
  'experiment/hdr-reapply-resize',
  'experiment/hdr-reapply-device-lost',
  'experiment/vrr-allow-tearing',
  'experiment/vrr-direct-render',
  'experiment/sdr-rec709',
  'experiment/compositor-probe',
  'experiment/present-sync1',
  'feature/directx-streaming-mode',
  'feature/foundation-hdr-capabilities',
  'feature/vplus-pacer',
  'feature/dynamic-bitrate'
)
foreach ($b in $branches) { git branch $b main }
```

### 18.6 Useful local commands

```powershell
# Confirm PR #281 still does not apply
cd F:\GitHub\moonlight-xbox-plus
git apply --check <path-to>\pr281.diff   # expect failure at VideoRenderer.cpp:159, .h:97

# Already done 2026-09-14; kept for provenance. This is how the section 6.4/6.5 cause
# (the C2664 CaptureAvioWrite mismatch) was originally found. Rerun only to re-verify,
# never as a precondition for starting work: the fix is already in the fixes-only commit.
gh run view 34136005241 --repo TheElixZammuto/moonlight-xbox --log-failed

# Inspect the unread upstream branch
git log --oneline upstream/master..upstream/hdr2
git diff upstream/master...upstream/hdr2 --stat
```

### 18.7 Sources

- Device Portal core API reference: https://learn.microsoft.com/en-us/windows/uwp/debug-test-perf/device-portal-api-core
- Xbox Device Portal `/ext/` endpoint index: https://learn.microsoft.com/en-us/previous-versions/windows/uwp/xbox-apps/reference
- Upstream repository: https://github.com/TheElixZammuto/moonlight-xbox
- Fork: https://github.com/ygordreyer/moonlight-xbox-plus
- PR #281 (`fix-hdr`, ArturKorop, commit `9704eb041129d5acd8a9a8a4c6fdf933096de52e`, closed without merge): https://github.com/TheElixZammuto/moonlight-xbox/pull/281
- Issue #234 "HDR is too bright": https://github.com/TheElixZammuto/moonlight-xbox/issues/234
- Issue #276 (HDR handshake, CachyOS Sunshine): https://github.com/TheElixZammuto/moonlight-xbox/issues/276
- Issue #271 (Series S 4K120 HDR black screen): https://github.com/TheElixZammuto/moonlight-xbox/issues/271
- Issue #181 (muted colors, Xbox UWP only): https://github.com/TheElixZammuto/moonlight-xbox/issues/181
- Upstream CI run 34136005241 (red at Build, 2026-09-07): https://github.com/TheElixZammuto/moonlight-xbox/actions/runs/34136005241
- The GDK "Enabling WDP on Xbox" page is NDA-gated and could not be fetched.

### 18.8 What this plan could not verify

Named once, here, so no reader mistakes any of it for measured fact:

- Every item marked UNCONFIRMED in sections 3.13, 3.16, 3.17, 3.19, 3.20 and 17.
- The contents of upstream branches `hdr2`, `better-diagnostics`, `intra-refresh`, `tracy`.
- Whether the self-hosted runner starts on a real logon, and whether any deploy job has ever run on it.
- PR #281's author's claim that HDR works on their console. That is a report, not a measurement.
- The literal Foundation log string for a negotiated colorspace.
- Moonlight V+'s four named pacing modes and their tunables, which must be pulled from source before being cited.

### 18.9 The `secrets` context is rejected inside `if:`

GitHub Actions validates workflow `if:` expressions before any job runs, and the `secrets` context is not permitted there: a condition written as `if: secrets.SIGNING_PFX_BASE64 != ''` fails validation with "Unrecognized named-value: 'secrets'". This failed the first two fork CI runs (34918888396, 34918896056) at validation, before a single job started, `steps: []` on both.

Fix, landed in commit `020a440`: surface the presence check once, as a job-level `env:` string, and test `env.*` in the `if:` instead of `secrets.*` directly.

```yaml
  build:
    # TEMPORARY: the account billing lock refuses hosted jobs; revert to windows-2022 once https://github.com/settings/billing is unlocked and one hosted run is green (docs/PLAN.md section 6.6)
    runs-on: [self-hosted, xbox-lan]
    env:
      # secrets is not a valid context inside if:; surface the presence of
      # the signing secret as a job env string and test that instead.
      HAS_SIGNING_PFX: ${{ secrets.SIGNING_PFX_BASE64 != '' }}
```
`msbuild.yml:82-88`.

```yaml
    - name: Load signing certificate (repo secret)
      id: cert
      if: env.HAS_SIGNING_PFX == 'true'
```
`msbuild.yml:196-198`.

`secrets.SIGNING_PFX_BASE64 != ''` still runs fine inside the `env:` value itself (`:88`), because an `env:` block is not an `if:` expression and does allow the `secrets` context; only the later `if:` (`:198`) has to read it back off `env.HAS_SIGNING_PFX` rather than off `secrets` directly.
