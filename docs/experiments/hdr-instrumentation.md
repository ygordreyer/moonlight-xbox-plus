# HDR instrumentation rescue

Telemetry-only restoration from the recovered predecessor patch and partial pacing trace.

| Area | Scope |
|---|---|
| File log | `LocalState\\logs`, UTF-8 append by a bounded background queue, ten files retained |
| HDR log | Frame tuple, lifecycle, display transition, resize, device-loss HRESULTs |
| Color helper | Support-gated unless a future isolated experiment passes `force=true` |
| Pacing trace | Approximately one-second windows and one final partial window |

- The render thread enqueues file-log records; the writer thread performs file I/O and flushing.
- A full queue drops records and emits a later drop count. The writer disables itself on thread-start or background failures.
- Pacing windows close after a Present or a no-frame iteration, plus the final window. A trace flush cannot sit between deadline calculation and the frame wait.
- New-frame intervals measure Present-call starts, not scanout or Present duration. Deadline telemetry uses the timestamp immediately before Present, after acquiring the decoder lock.
- Each window reports its own nearest-rank p99. Preserve `n`, `win_ms` and maximum intervals; averaging window p99 values cannot produce a whole-run percentile.

## Preserved rendering semantics

- SDR `DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709` remains suppressed by the zero-value gate.
- `m_LastColorTrc` remains updated when the support check or set does not succeed.
- No PQ forcing, reapply, HDR heuristic, pacing policy, setting, or runtime toggle is included.

## Provenance

- Recovery predecessor `hdr-instrumentation.patch`
- Recovery predecessor `applycolorspace-canonical.md`
- Recovery artifact `16-vplus-pacer/files/Streaming/PacingTrace.*`
