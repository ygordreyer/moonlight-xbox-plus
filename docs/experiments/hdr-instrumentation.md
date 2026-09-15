# HDR instrumentation rescue

Telemetry-only restoration from the recovered predecessor patch and partial pacing trace.

| Area | Scope |
|---|---|
| File log | `LocalState\\logs`, UTF-8 append by a bounded background queue, ten files retained |
| HDR log | Frame tuple, lifecycle, display transition, resize, device-loss HRESULTs |
| Color helper | Support-gated unless a future isolated experiment passes `force=true` |
| Pacing trace | One summary per second and one final partial window |

The render thread only enqueues file-log records. File I/O and flushing run on the log writer thread; a full queue drops records and emits a later drop count. The writer disables itself on thread-start or background failures instead of allowing an exception to terminate the process. Pacing trace windows close after a present, so a trace flush cannot sit between deadline calculation and the frame wait. Deadline telemetry uses the timestamp taken immediately before the locked `Present` call.

## Preserved rendering semantics

- SDR `DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709` remains suppressed by the zero-value gate.
- `m_LastColorTrc` remains updated when the support check or set does not succeed.
- No PQ forcing, reapply, HDR heuristic, pacing policy, setting, or runtime toggle is included.

## Provenance

- Recovery predecessor `hdr-instrumentation.patch`
- Recovery predecessor `applycolorspace-canonical.md`
- Recovery artifact `16-vplus-pacer/files/Streaming/PacingTrace.*`
