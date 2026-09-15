# Experiment: hdr-force-pq

- Branch: `experiment/hdr-force-pq`, from `main` at `09d1b71`.
- Plan item: `docs/PLAN.md` section 8, phase 3, item 3A ("Force PQ on every HDR frame").
- Hypothesis under test: H1 (`docs/PLAN.md` section 4).
- Every `file:line` below is against `main` at `09d1b71`, read before the change was made.
- Nothing in this file is a measured result. Results go in `docs/TEST-RESULTS.md`, one block per console run.

## Hypothesis

H1: the swap chain is never actually put into PQ. PQ pixels are then presented as sRGB, which matches the grayish, washed-out picture that only Moonlight Xbox shows.

The code path on `main` that H1 accuses:

- `Streaming/VideoRenderer.cpp:170` opens `if (frame->color_trc != m_LastColorTrc) {`. The color space decision runs only when the transfer characteristic changes.
- `:173-179` pick `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020` when `frame->color_trc == AVCOL_TRC_SMPTE2084`, else `DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709`.
- `:181-182` gate the apply on three conditions in one `if`: `colorspace` is non-zero, `CheckColorSpaceSupport` returns a success HRESULT, and the returned bitmask carries `DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT`.
- `:183` calls `SetColorSpace1` inside `DX::ThrowIfFailed`, which throws on any failing HRESULT (`Common/DirectXHelper.h:8-14`).
- `:184-187` log the color space name on success. No HRESULT and no bitmask is ever logged, and the skipped branch logs nothing.
- `:190` writes `m_LastColorTrc = frame->color_trc;` inside the outer `if` but outside the success branch. A skipped or failed apply still updates the cache, so the block does not run again until the transfer characteristic changes.
- `m_LastColorTrc` starts as `AVCOL_TRC_UNSPECIFIED` (`Streaming/VideoRenderer.cpp:57`, `Streaming/VideoRenderer.h:95`). The only two writes to it in the file are `:57` and `:190`; `hasFrameFormatChanged` (`:609-639`) leaves it alone on purpose (`:621`).
- The swap chain is `IDXGISwapChain4*` (`Common/DeviceResources.h:55`), created by `CreateSwapChainForComposition` (`Common/DeviceResources.cpp:280`) with a `DXGI_FORMAT_R10G10B10A2_UNORM` back buffer (`Common/DeviceResources.cpp:59`). The format is PQ-capable, so a rejected PQ request would not be a format problem.

Three ways the `:182` gate skips the apply silently, all of them ending with the cache written at `:190`:

1. `CheckColorSpaceSupport` returns a failing HRESULT.
2. It succeeds but the bitmask lacks `DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT` (the case H1 names explicitly).
3. The `colorspace &&` test is false. `DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709` is enumerator value 0 and `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020` is 12 in `dxgicommon.h` (documented values; UNCONFIRMED by header read, because no Windows SDK is installed on the authoring machine). If that holds, the sRGB branch never reaches `SetColorSpace1`, so an HDR to SDR switch inside one session leaves the swap chain in PQ. This is a sibling bug of H1, not H1 itself; the change below removes it as a side effect and the SDR run in the sweep will show whether it mattered.

## The exact code change

Two files, one site, no new helper, no new logger.

`Streaming/VideoRenderer.cpp`, the block at `:181-190`:

- Delete the `CheckColorSpaceSupport` gate (`:181-182`) and the `DX::ThrowIfFailed` wrapper (`:183`).
- Call `m_deviceResources->GetSwapChain()->SetColorSpace1(colorspace)` directly and keep its `HRESULT`.
- Log one line through the existing `Utils::Logf` (`Utils.hpp:15`): `SetColorSpace1(<space name>) returned 0x%08X`. The `0x%08X` form is the file's existing HRESULT convention (`Streaming/VideoRenderer.cpp:378`). The text matches acceptance criterion 2 in `docs/PLAN.md` section 14.3 (line 747) so the criterion can be checked by grep.
- Write `m_LastColorTrc = frame->color_trc;` only when `SUCCEEDED(hr)`. A failed apply is retried on the next frame instead of being cached.
- The log line is keyed on the pair (requested color space, HRESULT): it prints when the apply succeeds, or when either half of the pair differs from the previous attempt. A failure that repeats every frame prints once. A change of request, a change of HRESULT, and every success each print once.

`Streaming/VideoRenderer.h`, after `m_LastChromaLocation` (`:97`):

- `DXGI_COLOR_SPACE_TYPE m_LastColorSpaceRequested = DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;`
- `HRESULT m_LastColorSpaceHr = S_OK;`

These two members exist only to keep the retry path from logging per frame. Their initial values match a freshly created swap chain, so the first HDR frame always logs.

Behavior differences against `main`, on purpose:

- A failing `SetColorSpace1` no longer throws out of `Render`; it is logged and retried.
- The sRGB restore branch is now applied like the PQ branch (case 3 above).
- The `CheckColorSpaceSupport` result is not consulted at all. This is the single variable the branch isolates. The instrumentation branch is the one that records what the check would have said.

Unchanged: `SetHDR` (`:682-699`), `Stop()` (`:701-703`), `DeviceResources`, the transfer characteristic heuristic from PR #281 (that is 3B on `experiment/hdr-pr281`), reapply after `ResizeBuffers` (3C) and after device loss (3D).

## Expected result if H1 holds

Stated as expectations, not results.

- The client log carries exactly one `SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020) returned 0x00000000` line on the first HDR frame of the session, and the `main` baseline log carries no `Colorspace changed to DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020` line for the same stream.
- The grayish cast is gone on the 4K60 HDR run.
- Highlight clipping onset moves from about 1600 nits toward the host's configured maximum (`hdrBrightnessMode` manual 1000 per `docs/PLAN.md` line 673, or 1690 if the host was changed for the diagnostic run named at line 675; record which).
- Sub-case, still H1 confirmed but 3A not the fix: the line prints with a non-zero HRESULT (for example `0x887A0001`, `DXGI_ERROR_INVALID_CALL`) and the picture is unchanged. The swap chain cannot be put into PQ from this path at all; the next suspects are swap chain creation and the composition path (H3, phase 2a). The HRESULT value is the receipt.

## Expected result if H1 does not hold

- The line prints with `0x00000000` and the picture is unchanged: the gate on `main` was already passing, the swap chain was already in PQ, and the cause is elsewhere. Next: phase 2a (H3) and phases 3C and 3D (H4).
- The line names `DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709` on a stream the host reports as PQ: the frame's `color_trc` is not `AVCOL_TRC_SMPTE2084`, which is H2's signature. This branch cannot fix that by design (it keeps the `:173` test). Next: `experiment/hdr-pr281` (3B).
- The clipping onset still differs with the quick menu open versus closed: that gap is H3's evidence and is untouched by this change, whatever the color space line says.

## The measurement that separates them

- Standard sweep from `docs/PLAN.md` section 14.1: 4K60 HDR, Game mode, quick menu closed; the same with the menu open; 1080p60 SDR, Game mode. One block per run in `docs/TEST-RESULTS.md` using the 14.2 template, Game mode and the Dev Home VRR setting recorded in every block.
- From the client log (`LocalState\logs\<file>`): every line containing `SetColorSpace1(`, verbatim, with its count. One line per session is the pass shape; many identical lines mean the dedupe failed and is itself a bug.
- From the `main` baseline block: presence or absence of `Colorspace changed to`.
- Visual: the grayish cast (present or gone) and the clipping onset in nits with the menu closed and open, measured the same way as the 1600 and 2200 baseline numbers.

| Log line on the HDR run | Picture | Reading |
|---|---|---|
| PQ request, `0x00000000` | fixed | H1 confirmed, 3A is the fix. 3B's heuristic is unnecessary and is not merged. |
| PQ request, `0x00000000` | unchanged | H1 refuted for this path. Go to phase 2a, then 3C and 3D. |
| PQ request, failing HRESULT | unchanged | H1 mechanism confirmed, fix is not at this site. Record the HRESULT; suspect swap chain creation and composition. |
| sRGB request | unchanged | H2 signature. Run `experiment/hdr-pr281`. |

## Untested by the author

- Not compiled on the authoring machine: no MSBuild and no Windows SDK there. CI builds the branch after push. Compile risks: `DXGI_COLOR_SPACE_TYPE` and `S_OK` in `VideoRenderer.h` rely on the DXGI and Windows headers already reaching that header through `pch.h`, the same way `DXGI_HDR_METADATA_HDR10` at `VideoRenderer.h:77` does; `Utils::Logf` with `0x%08X` and an `HRESULT` argument follows the existing call at `VideoRenderer.cpp:378`.
- The enumerator values in case 3 above (0 and 12) come from documentation, not from a header read on this machine.
- No console run has happened on this branch. `docs/TEST-RESULTS.md` is empty until one does.
