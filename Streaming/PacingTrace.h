#pragma once

#include <array>
#include <cstdint>
#include <mutex>

class PacingTrace {
public:
	static PacingTrace& instance();
	void reset(int64_t nowQpc);
	void observePresent(int64_t presentQpc, bool newFrame, bool hitDeadline);
	void observeEnqueue(int queueDepth, int dropped);
	void observeRender(int queueDepth, int dropped);
	void observeVblankWait(int64_t intervalQpc);
	bool windowElapsed(int64_t nowQpc) const;
	void flush(int64_t nowQpc, const char* pacingMode, double streamFps, int64_t statsVblankQpc, bool final);

private:
	PacingTrace();
	PacingTrace(const PacingTrace&) = delete;
	PacingTrace& operator=(const PacingTrace&) = delete;
	static constexpr int MAX_SAMPLES = 1024;
	struct Window {
		int64_t startQpc = 0;
		uint32_t presents = 0, newFrames = 0, missedDeadlines = 0, enqueues = 0;
		uint64_t enqueueDepthSum = 0;
		int enqueueDepthMax = 0;
		uint32_t renders = 0;
		uint64_t renderDepthSum = 0;
		int renderDepthMax = 0;
		uint32_t enqueueDrops = 0, renderDrops = 0, vblanks = 0;
		int64_t vblankSum = 0, vblankMin = 0, vblankMax = 0;
		int sampleCount = 0;
		uint32_t sampleOverflow = 0;
		std::array<int64_t, MAX_SAMPLES> samples{};
	};
	mutable std::mutex m_Mutex;
	Window m_Window;
	int64_t m_LastNewPresentQpc = 0;
	int64_t m_WindowQpc = 0;
};
