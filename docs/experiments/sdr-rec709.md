# Experiment: SDR colorspace, Rec.601 against Rec.709

Branch `experiment/sdr-rec709`. Base `main` at `7edf373`. Plan reference: `docs/PLAN.md` section 9 (governs), section 3.4 (the stream configuration), hypothesis H5 in section 4.

## Hypothesis

The client asks the host for Rec.601 on every stream, and the host honours that request, so every SDR stream is encoded with the Rec.601 YUV to RGB matrix instead of the Rec.709 matrix that SDR desktop content actually uses. Requesting Rec.709 instead changes what the host encodes and removes a colour shift (greens and reds move, skin tones shift, saturation changes) that is easy to blame on display calibration.

Two sub-claims, tested separately by the measurement below:

1. The host honours the client's `colorSpace` request (host encode side).
2. The client's renderer follows the change without further code (client decode side).

## The finding

| Receipt | Line | What it says |
|---|---|---|
| `State/MoonlightClient.cpp:262` | `config.colorSpace = COLORSPACE_REC_601;` | Literal, no condition. Sent for SDR and HDR, every resolution. |
| `State/MoonlightClient.cpp:261` | `config.colorRange = this->IsRGBFull() ? COLOR_RANGE_FULL : COLOR_RANGE_LIMITED;` | Range is derived; only the colorspace is a constant. |
| `third_party/moonlight-common-c/src/Limelight.h:24-26` | `COLORSPACE_REC_601 0`, `COLORSPACE_REC_709 1`, `COLORSPACE_REC_2020 2` | The three legal values. |
| `third_party/moonlight-common-c/src/Limelight.h:82-83` | "If specified, sets the encoder colorspace to the provided COLORSPACE_* option. If not set, the encoder will default to Rec 601." | The field is documented as an encoder-side request. |

## How the value reaches the host

- `third_party/moonlight-common-c/src/SdpGenerator.c:546-547` packs it into the RTSP SDP attribute `x-nv-video[0].encoderCscMode` as `(colorSpace << 1) | colorRange`, sent only when the host reports app version 7 or later (`:545`).
- Wire values, so a host-side log or packet capture can be read without the headers:

| Request | `colorRange` limited | `colorRange` full |
|---|---|---|
| `COLORSPACE_REC_601` (unmodified build) | `0` | `1` |
| `COLORSPACE_REC_709` (this branch) | `2` | `3` |
| `COLORSPACE_REC_2020` (not requested by any build) | `4` | `5` |

- Host side (from the plan, section 3.16, not verified in this tree because the host source is not part of it): Foundation's `video_colorspace.cpp` carries `colorspace_e {rec601, rec709, bt2020sdr}`, so the host has a real decision path fed by this attribute. The literal log line it prints for the negotiated colorspace is UNCONFIRMED; the measurement records whatever it actually prints.

## Exact code change

One line, `State/MoonlightClient.cpp:262`, plus a pointer comment to this note:

```diff
-	config.colorSpace = COLORSPACE_REC_601;
+	// experiment/sdr-rec709: request Rec.709 instead of the Rec.601 literal, see docs/experiments/sdr-rec709.md
+	config.colorSpace = COLORSPACE_REC_709;
```

The choice is a hardcoded swap, exactly as section 9 step 3 prescribes. No rule by resolution or HDR state is introduced here: deriving the value (Rec.709 for SDR, Rec.2020 when `VIDEO_FORMAT_H265_MAIN10` is requested) is the follow-up in section 9 and lands only after this experiment shows what the host does with each value.

Nothing else changes. No submodule is touched. `COLORSPACE_REC_709` is defined at `third_party/moonlight-common-c/src/Limelight.h:25`, which `State/MoonlightClient.cpp:5` already includes inside `extern "C"`, so the change carries no compile risk.

## Does the client render path honour the change?

Short answer: only through the bitstream, never through the negotiated value itself.

| Path | Lines | What happens |
|---|---|---|
| moonlight-common-c stamps the negotiated value onto each decode unit | `third_party/moonlight-common-c/src/VideoDepacketizer.c:497-498` | `decodeUnit.colorspace = hdrActive ? COLORSPACE_REC_2020 : StreamConfig.colorSpace` |
| Client reads `decodeUnit.colorspace` or `decodeUnit.hdrActive` | none | Grep over `State/`, `Streaming/`, `Pages/`, `Utils.cpp`, `Utils.hpp` for `.colorspace`, `->colorspace`, `hdrActive` finds only the `frame->colorspace` uses in `Streaming/VideoRenderer.cpp` listed below. The negotiated value is never consumed on the client. |
| Renderer picks the CSC matrix from the decoded frame | `Streaming/VideoRenderer.cpp:455-471` `getFrameColorspace()` | Reads `frame->colorspace`, which FFmpeg fills from the bitstream VUI `matrix_coefficients`. `AVCOL_SPC_BT709` maps to `COLORSPACE_REC_709` (`:461-462`); `SMPTE170M` and `BT470BG` to Rec.601 (`:458-460`); `BT2020_NCL` and `BT2020_CL` to Rec.2020 (`:463-465`). |
| Fallback when the VUI is absent | `Streaming/VideoRenderer.cpp:466-469` | Returns the constant `COLORSPACE_REC_601`. The comment says "assume the encoder is sending the colorspace that we requested", but the code returns 601, not the requested value. |
| Matrix selection and the log line | `Streaming/VideoRenderer.cpp:528-540`, `:550-557` | `k_CscMatrix_Bt709` (`:501-505`) is selected at `:534-535`. The `Shader config:` log prints the chosen matrix name and the raw `frame->colorspace` integer. It runs once per frame-format change (`:125`, `:144-146`), so it is already a one-line receipt without the phase 1 logger. |

Consequences for the experiment:

- If the host honours the request AND writes `matrix_coefficients = 1` (BT.709) into the H.264 or HEVC VUI, the renderer switches to the Rec.709 matrix on its own. Both sides agree and the chart should look right.
- If the host honours the request but leaves the VUI unspecified, `frame->colorspace` is `AVCOL_SPC_UNSPECIFIED` (2), `:469` picks the Rec.601 matrix, and this branch makes the mismatch WORSE than the unmodified build (host encodes 709, client decodes 601). That is the case section 9 reserves for the fallback fix at `:460` and `:469`, and it is the first next run if the measurement lands there.
- If the host ignores the request, nothing changes on either side, the chart matches the baseline, and the constant is harmless on this host (but still wrong for a host that honours it).
- HDR streams are outside this experiment: `VideoDepacketizer.c:498` and the host both force Rec.2020 when HDR is active, and the client's renderer takes Rec.2020 from the VUI at `:463-465`.

## Expected results

| Outcome | Host log | Client `Shader config:` / `LogFrameColorState` | Colour chart | Verdict |
|---|---|---|---|---|
| Hypothesis holds, both sub-claims | Negotiated colorspace changes from the 601 value to the 709 value between the two runs | `frame->colorspace` changes from 6 (SMPTE170M) or 5 (BT470BG) to 1 (BT709); matrix name changes from `Rec. 601` to `Rec. 709` | Side-by-side of the same chart differs; the Rec.709 run matches the host desktop | The constant was driving the host and the client followed. Real bug. Fix permanently (derive the value), then the `:460`/`:469` fallbacks. |
| Host honours, client does not follow | Changes as above | `frame->colorspace` stays 2 (UNSPECIFIED), matrix stays `Rec. 601` | Rec.709 run looks worse than baseline (shifted the other way) | Sub-claim 1 holds, sub-claim 2 fails. Next run: change the `:469` fallback to Rec.709 on this branch and rerun. |
| Host ignores the request | Same line in both runs | Same values in both runs | Charts identical | The constant is harmless on this host. Still fix it for hosts that honour it, but with a lower priority than the HDR work. |
| Baseline already reports BT709 | Says 709 or equivalent on the unmodified build | `frame->colorspace` is already 1 on the unmodified build | Charts identical | The host was ignoring the request and encoding 709 already; the VUI was doing the client's work. Same verdict as the row above, plus a note that `:469` never fired here. |

## Measurement (section 9, steps 1 to 5)

Record every line verbatim in `docs/TEST-RESULTS.md`, with the console's resource mode (App or Game) and the Dev Home VRR toggle state, as phases 2c and 2d require.

1. Baseline. On an unmodified `main` build, start an SDR stream and capture the client's frame colour line. With the phase 1 logger merged in, that is the `LogFrameColorState` line (`colorspace`, `color_primaries`, `color_trc`, `color_range`). Without it, the existing `Shader config:` line from `Streaming/VideoRenderer.cpp:550-557` carries the matrix name and `frame->colorspace`; it lands in the `LOG_LINES` ring (70 lines, `Utils.cpp:12`) shown by the in-app log overlay, and in `OutputDebugString`.
2. Read the host's own log for the negotiated colorspace on that same session and copy the literal line. Do not assume the wording; the plan's guessed string was searched for and not found.
3. Build and deploy this branch, rerun the same stream, capture the same two lines. The SDP value should move from `0` or `1` to `2` or `3` (table above) if a packet capture or host debug log exposes `encoderCscMode`.
4. Photograph a fixed colour chart on the host desktop from the same position with the same camera settings in both runs. The side-by-side is the evidence; an impression is not.
5. Decide with the expected-results table. The line that separates the outcomes is the host's negotiated colorspace: if it changes with the client's request, the client was driving it.

`frame->colorspace` values (ITU-T H.273 / FFmpeg `AVColorSpace`), so the log reads without the headers: 1 BT709, 2 UNSPECIFIED, 5 BT470BG, 6 SMPTE170M, 9 BT2020_NCL, 10 BT2020_CL.

## Next runs, in order

1. If the host honours the request but the client does not follow: change the fallbacks at `Streaming/VideoRenderer.cpp:460` and `:469` to `COLORSPACE_REC_709` for anything that is not standard definition, rerun on this branch.
2. If the host honours the request: replace the constant with a derived value, Rec.709 for SDR, Rec.2020 when `VIDEO_FORMAT_H265_MAIN10` is in `supportedVideoFormats` (`State/MoonlightClient.cpp:266-272`). Separate branch, after this experiment closes.
3. Full-range variant (`encoderCscMode` 3) needs no new build: it follows the existing `IsRGBFull()` setting at `:261`.

## Assumptions and open points

- The phase 1 instrumentation branch (`experiment/hdr-instrumentation`) is not merged into this branch. Section 9 step 1 names its logger, but the existing `Shader config:` line is an equivalent receipt for the fields this experiment needs (`frame->colorspace`, range, bit depth), so the experiment can run before that merge.
- The host's handling of `encoderCscMode` is described from the plan (section 3.16) and not verified against host source in this tree.
- No compiler was available while writing this branch; the change is a one-line constant swap using a macro already in scope, and CI builds the branch after push.
