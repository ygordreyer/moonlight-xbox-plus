#include "pch.h"
#include "PacingTrace.h"

#include <algorithm>
#include <cmath>

#include "Utils.hpp"

using namespace moonlight_xbox_dx;

PacingTrace& PacingTrace::instance() {
	static PacingTrace trace;
	return trace;
}

PacingTrace::PacingTrace() : m_WindowQpc(MsToQpc(1000.0)) {
}

void PacingTrace::reset(int64_t nowQpc) {
	std::lock_guard<std::mutex> lock(m_Mutex);
	m_Window = Window{};
	m_Window.startQpc = nowQpc;
	m_LastNewPresentQpc = 0;
}

void PacingTrace::observePresent(int64_t presentQpc, bool newFrame, bool hitDeadline) {
	std::lock_guard<std::mutex> lock(m_Mutex);
	++m_Window.presents;
	if (!hitDeadline) ++m_Window.missedDeadlines;
	if (!newFrame) return;
	++m_Window.newFrames;
	if (m_LastNewPresentQpc != 0) {
		const int64_t interval = presentQpc - m_LastNewPresentQpc;
		if (m_Window.sampleCount < MAX_SAMPLES) m_Window.samples[m_Window.sampleCount++] = interval;
		else ++m_Window.sampleOverflow;
	}
	m_LastNewPresentQpc = presentQpc;
}

void PacingTrace::observeEnqueue(int queueDepth, int dropped) {
	std::lock_guard<std::mutex> lock(m_Mutex);
	++m_Window.enqueues;
	m_Window.enqueueDepthSum += static_cast<uint64_t>(std::max(queueDepth, 0));
	m_Window.enqueueDepthMax = std::max(m_Window.enqueueDepthMax, queueDepth);
	m_Window.enqueueDrops += static_cast<uint32_t>(std::max(dropped, 0));
}

void PacingTrace::observeRender(int queueDepth, int dropped) {
	std::lock_guard<std::mutex> lock(m_Mutex);
	++m_Window.renders;
	m_Window.renderDepthSum += static_cast<uint64_t>(std::max(queueDepth, 0));
	m_Window.renderDepthMax = std::max(m_Window.renderDepthMax, queueDepth);
	m_Window.renderDrops += static_cast<uint32_t>(std::max(dropped, 0));
}

void PacingTrace::observeVblankWait(int64_t intervalQpc) {
	if (intervalQpc <= 0) return;
	std::lock_guard<std::mutex> lock(m_Mutex);
	if (m_Window.vblanks == 0) m_Window.vblankMin = m_Window.vblankMax = intervalQpc;
	else {
		m_Window.vblankMin = std::min(m_Window.vblankMin, intervalQpc);
		m_Window.vblankMax = std::max(m_Window.vblankMax, intervalQpc);
	}
	++m_Window.vblanks;
	m_Window.vblankSum += intervalQpc;
}

bool PacingTrace::windowElapsed(int64_t nowQpc) const {
	std::lock_guard<std::mutex> lock(m_Mutex);
	return m_Window.startQpc != 0 && nowQpc - m_Window.startQpc >= m_WindowQpc;
}

void PacingTrace::flush(int64_t nowQpc, const char* pacingMode, double streamFps, int64_t statsVblankQpc, bool final) {
	Window window;
	{
		std::lock_guard<std::mutex> lock(m_Mutex);
		window = m_Window;
		m_Window = Window{};
		m_Window.startQpc = nowQpc;
	}
	if (final && window.presents == 0 && window.enqueues == 0) return;

	const int count = window.sampleCount;
	double meanMs = 0.0, p99Ms = 0.0, maxMs = 0.0;
	if (count > 0) {
		int64_t sum = 0;
		int64_t maxQpc = 0;
		for (int i = 0; i < count; ++i) {
			sum += window.samples[i];
			maxQpc = std::max(maxQpc, window.samples[i]);
		}
		const int rank = std::clamp(static_cast<int>(std::ceil(0.99 * count)), 1, count);
		std::nth_element(window.samples.begin(), window.samples.begin() + rank - 1, window.samples.begin() + count);
		meanMs = QpcToMs(sum) / count;
		p99Ms = QpcToMs(window.samples[rank - 1]);
		maxMs = QpcToMs(maxQpc);
	}
	const double enqMean = window.enqueues ? static_cast<double>(window.enqueueDepthSum) / window.enqueues : 0.0;
	const double rndMean = window.renders ? static_cast<double>(window.renderDepthSum) / window.renders : 0.0;
	const double vblankMean = window.vblanks ? QpcToMs(window.vblankSum) / window.vblanks : 0.0;
	Utils::Logf("PacingTrace:%s pacing=%s win_ms=%.1f present=%u new=%u repeat=%u miss=%u"
		" | new_interval_ms mean=%.2f p99=%.2f max=%.2f n=%d%s"
		" | queue enq_mean=%.2f enq_max=%d rnd_mean=%.2f rnd_max=%d"
		" | drops enq=%u rnd=%u | vblank_ms wait=%.3f min=%.3f max=%.3f n=%u stats=%.3f fps=%.2f\n",
		final ? " final" : "", pacingMode ? pacingMode : "?", QpcToMs(nowQpc - window.startQpc),
		window.presents, window.newFrames, window.presents - window.newFrames, window.missedDeadlines,
		meanMs, p99Ms, maxMs, count, window.sampleOverflow ? " (overflow)" : "", enqMean, window.enqueueDepthMax,
		rndMean, window.renderDepthMax, window.enqueueDrops, window.renderDrops, vblankMean,
		QpcToMs(window.vblankMin), QpcToMs(window.vblankMax), window.vblanks,
		statsVblankQpc > 0 ? QpcToMs(statsVblankQpc) : 0.0, streamFps);
}
