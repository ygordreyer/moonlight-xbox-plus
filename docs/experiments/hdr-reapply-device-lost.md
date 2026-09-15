# Experiment: hdr-reapply-device-lost

Branch: `experiment/hdr-reapply-device-lost`, from `main` at `09d1b71`.
Plan reference: `docs/PLAN.md` section 8, phase 3, item 3D; sections 3.2 and 3.3; hypothesis H4 in section 4.
Builds on no earlier experiment.

## Hypothesis

H4, the device-loss half: after `DX::DeviceResources::HandleDeviceLost()` recreates the device and the swap chain, the new swap chain comes up in the DXGI default color space while the renderer still believes the last applied space is in effect, so an HDR stream that survives a device loss is presented as sRGB for the rest of the session.

## What the code does today (read on `main` at `09d1b71`)

- `Common/DeviceResources.cpp:486-506` `HandleDeviceLost()`: `ImGui_Deinit()` (`:488`), `m_swapChain = nullptr` (`:490`), a log line (`:492`), `m_deviceNotify->OnDeviceLost()` (`:496`), `CreateDeviceResources()` (`:499`), `CreateWindowSizeDependentResources()` (`:500`), `m_deviceNotify->OnDeviceRestored()` (`:504`).
- `CreateWindowSizeDependentResources()` takes its create branch because `m_swapChain` is null: `CreateSwapChainForComposition` at `:280`. A swap chain created this way starts in the DXGI default color space. No `SetColorSpace1` call follows anywhere in the recreate path.
- Call sites of `HandleDeviceLost()`: `:228` (`ResizeBuffers` returned `DXGI_ERROR_DEVICE_REMOVED` or `DXGI_ERROR_DEVICE_RESET`), `:481` (`ValidateDevice()` found an adapter change or a removed device), `:539` (`Present` returned removed or reset), `:544` (`Present` returned `DXGI_ERROR_INVALID_CALL`).
- The only `SetColorSpace1` call in the tree is `Streaming/VideoRenderer.cpp:183`, gated by `:170` `if (frame->color_trc != m_LastColorTrc)` and by the `CheckColorSpaceSupport` PRESENT flag at `:182`. `:190` writes `m_LastColorTrc` whether or not the apply ran.
- `IDeviceNotify` (`Common/DeviceResources.h:9-13`) is implemented by `moonlight_xbox_dxMain` (`Streaming/moonlight_xbox_dxMain.h:16`, registered at `Streaming/moonlight_xbox_dxMain.cpp:113`, deregistered at `:206`). `VideoRenderer` is not an `IDeviceNotify`; it is reached through `m_sceneRenderer`.
- `moonlight_xbox_dxMain::OnDeviceLost()` (`Streaming/moonlight_xbox_dxMain.cpp:843-847`) calls `VideoRenderer::ReleaseDeviceDependentResources()` (`Streaming/VideoRenderer.cpp:316-331`), which resets the shaders, the buffers, the sampler, the SRV cache and the two loading flags. It does not touch `m_LastColorTrc`.
- `moonlight_xbox_dxMain::OnDeviceRestored()` (`Streaming/moonlight_xbox_dxMain.cpp:850-857`) calls `VideoRenderer::CreateDeviceDependentResources()` (`Streaming/VideoRenderer.cpp:207-314`), which rebuilds the shaders, reads the HDMI mode, and restarts streaming on the thread pool (`:300-313`). It does not touch the swap chain color space.
- Net effect on `main`: after a device loss the renderer's `m_LastColorTrc` still equals the stream's `color_trc`, so `:170` is false on every later frame and the recreated swap chain stays in the default space until the transfer characteristic changes.
- There is no existing `DXGI_COLOR_SPACE_TYPE` cache to reuse. `m_LastColorTrc` (`Streaming/VideoRenderer.h:95`) is an `AVColorTransferCharacteristic`, and it is written even when nothing was applied, so it cannot serve as "last known good".

## Exact code change

1. `Common/DeviceResources.h`: new private member `DXGI_COLOR_SPACE_TYPE m_lastColorSpace`, and a public inline setter `SetLastColorSpace(DXGI_COLOR_SPACE_TYPE)` next to `SetRefreshRate` and `SetFrameRate`.
2. `Common/DeviceResources.cpp` constructor: initialize `m_lastColorSpace` to `DXGI_COLOR_SPACE_CUSTOM`, the sentinel for "nothing applied yet".
3. `Common/DeviceResources.cpp` `HandleDeviceLost()`: after `CreateWindowSizeDependentResources()` and before `OnDeviceRestored()`, when `m_lastColorSpace` is not the sentinel, call `m_swapChain->SetColorSpace1(m_lastColorSpace)` and log the requested space and the HRESULT through `Utils::Logf`, one line per device loss, never per frame. When the sentinel is still set, log one line saying there was nothing to re-apply.
4. `Streaming/VideoRenderer.cpp`: after the `SetColorSpace1` at `:183` returns success (the `DX::ThrowIfFailed` around it did not throw), call `m_deviceResources->SetLastColorSpace(colorspace)`.

Not changed, on purpose:

- `m_LastColorTrc` is not reset on device loss. With the re-apply in place the renderer's belief matches the swap chain again; a reset would only add a second apply, gated by `CheckColorSpaceSupport`, on the first frame after restore. If the re-apply fails, the renderer will not retry until `color_trc` changes; that is the same failure mode `main` already has at `:190` and phase 3A owns it.
- The renderer's `CheckColorSpaceSupport` gate, the `:190` cache-on-failure, `SetHDR`, `Stop`, and the `ResizeBuffers` path (item 3C, branch `experiment/hdr-reapply-resize`).

When `experiment/hdr-instrumentation` merges, the raw `SetColorSpace1` call in `HandleDeviceLost()` moves to `DeviceResources::ApplyColorSpace` (plan phase 1c), which logs the check HRESULT, the support bitmask and the set HRESULT on one line. The `m_lastColorSpace` cache and the setter stay as they are.

## Expected result if the hypothesis holds

- An HDR session that goes through a device loss shows the same picture before and after: no switch to a washed-out image, no change in the clipping onset.
- The client log carries, in order: `HandleDeviceLost()`, then `HandleDeviceLost(): SetColorSpace1(12) returned 0x00000000` (12 is `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020`), then `Loading Complete!` from the restarted stream.
- On `main`, the same trigger shows `HandleDeviceLost()` and then the picture goes washed out and stays so, with no `Colorspace changed to` line afterwards.

## Expected result if it does not hold

- The device loss never happens on the console during a normal session, so the branch changes nothing observable. The hypothesis is then untestable by this route, not refuted.
- Or the log shows a failing HRESULT on the re-apply: the recreated swap chain refuses the space. The failure code is the finding and the fix moves to the swap chain description.
- Or the re-apply succeeds and the picture is still wrong after the device loss: the device-loss path is not where the drift comes from, and H4's other half (`ResizeBuffers`, branch `experiment/hdr-reapply-resize`) or H1 and H3 carry the explanation.

## The measurement that separates them

1. Build this branch through CI, deploy to the console, start a 4K60 HDR stream (standard sweep run 1, plan section 14.1), and confirm the log has `Colorspace changed to DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020`.
2. Provoke a device loss. UNCONFIRMED which of these does it on a Series X: suspend the app from the guide and resume it after a minute (the app calls `Trim()` on suspend; whether the device is reset on resume is not verified); switch the TV input away and back; or hit the `DXGI_ERROR_INVALID_CALL` path at `DeviceResources.cpp:541-545`, which has a dedicated recovery branch and a log line of its own, so it has probably been seen in practice, but that is not verified either. Record which trigger produced a `HandleDeviceLost()` log line and which did not.
3. Read the log lines that follow `HandleDeviceLost()`. The presence and the HRESULT of the `SetColorSpace1(...) returned` line is the primary measurement; the picture and the clipping onset before and after are the secondary one.
4. Run the same trigger on the `main` build for the control.

A run in which no `HandleDeviceLost()` line appears goes into `docs/TEST-RESULTS.md` under "Untested in this run" and proves nothing about H4.

## Compile notes

- `DXGI_COLOR_SPACE_TYPE` and `DXGI_COLOR_SPACE_CUSTOM` come from `dxgicommon.h`, reached through `pch.h` (`dxgi1_6.h` at `pch.h:8`), the same way the header already names `IDXGISwapChain4` without its own include.
- `Utils::Logf` is already used in `DeviceResources.cpp` (`:222`, `:288`, `:543`), so no include changes.
- The setter is an inline member in the header. No new source files, no project file change.
- No compiler was available when the branch was written. CI is the first build.
