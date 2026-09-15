#pragma once
#include "pch.h"
#include "Utils.hpp"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cwchar>
#include <deque>
#include <filesystem>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

using namespace std::chrono;
constexpr auto LOG_LINES = 70;
constexpr size_t LOG_FILES_KEPT = 10;

namespace moonlight_xbox_dx {
	namespace Utils {
		std::vector<std::wstring> logLines;
		bool showLogs = false;
		bool showStats = false;
		std::mutex logMutex;
		constexpr size_t FILE_LOG_QUEUE_MAX = 2048;
		class FileLogWriter {
		public:
			~FileLogWriter() { stop(); }
			void init(FILE* file) {
				std::lock_guard<std::mutex> lock(m_Mutex);
				if (m_File || !file) return;
				m_File = file;
				try {
					m_Thread = std::thread(&FileLogWriter::consume, this);
				}
				catch (...) {
					fclose(m_File);
					m_File = nullptr;
					m_Stopping = true;
				}
			}
			void enqueue(const std::wstring& line) {
				std::lock_guard<std::mutex> lock(m_Mutex);
				if (!m_File || m_Stopping) return;
				if (m_Queue.size() == FILE_LOG_QUEUE_MAX) { ++m_Dropped; return; }
				m_Queue.push_back(line);
				m_Wake.notify_one();
			}
		private:
			void stop() {
				{ std::lock_guard<std::mutex> lock(m_Mutex); m_Stopping = true; }
				m_Wake.notify_one();
				if (m_Thread.joinable()) m_Thread.join();
				if (m_File) { fclose(m_File); m_File = nullptr; }
			}
			void consume() noexcept {
				try {
					for (;;) {
					std::deque<std::wstring> batch;
					uint32_t dropped = 0;
					{
						std::unique_lock<std::mutex> lock(m_Mutex);
						m_Wake.wait(lock, [this] { return m_Stopping || !m_Queue.empty(); });
						batch.swap(m_Queue); dropped = m_Dropped; m_Dropped = 0;
						if (batch.empty() && m_Stopping) break;
					}
					if (dropped) batch.emplace_front(L"File log queue dropped " + std::to_wstring(dropped) + L" line(s)\n");
					for (const auto& line : batch) {
						std::string utf8 = WideToNarrowString(line);
						if (utf8.empty() || utf8.back() != '\n') utf8.push_back('\n');
						fwrite(utf8.data(), 1, utf8.size(), m_File);
					}
					if (!batch.empty()) fflush(m_File);
					}
				}
				catch (...) {
					FILE* file = nullptr;
					{
						std::lock_guard<std::mutex> lock(m_Mutex);
						m_Stopping = true;
						m_Queue.clear();
						file = m_File;
						m_File = nullptr;
					}
					if (file) fclose(file);
					OutputDebugString(L"File log writer disabled after an internal failure.\n");
				}
			}
			std::mutex m_Mutex;
			std::condition_variable m_Wake;
			std::deque<std::wstring> m_Queue;
			std::thread m_Thread;
			FILE* m_File = nullptr;
			uint32_t m_Dropped = 0;
			bool m_Stopping = false;
		};
		static FileLogWriter fileLogWriter;

		void InitFileLog() {
			try {
				static std::once_flag once;
				bool first = false;
				std::call_once(once, [&] { first = true; });
				if (!first) return;
				namespace fs = std::filesystem;
				auto localFolder = Windows::Storage::ApplicationData::Current->LocalFolder;
				if (localFolder == nullptr || localFolder->Path == nullptr) return;
				const fs::path logDir = fs::path(localFolder->Path->Data()) / L"logs";
				std::error_code ec;
				fs::create_directories(logDir, ec);
				if (ec) return;

				const std::time_t tt = system_clock::to_time_t(system_clock::now());
				std::tm localTm{};
				localtime_s(&localTm, &tt);
				wchar_t name[64]{};
				swprintf(name, sizeof(name) / sizeof(name[0]), L"moonlight-%04d%02d%02d-%02d%02d%02d.log",
					localTm.tm_year + 1900, localTm.tm_mon + 1, localTm.tm_mday,
					localTm.tm_hour, localTm.tm_min, localTm.tm_sec);
				const fs::path logPath = logDir / name;
				FILE* file = nullptr;
				if (_wfopen_s(&file, logPath.c_str(), L"a") != 0 || file == nullptr) {
					return;
				}
				fileLogWriter.init(file);

				std::vector<fs::path> files;
				for (const auto& entry : fs::directory_iterator(logDir, ec)) {
					if (ec) break;
					const auto fileName = entry.path().filename().wstring();
					if (entry.is_regular_file(ec) && !ec && fileName.rfind(L"moonlight-", 0) == 0 &&
						entry.path().extension() == L".log") files.push_back(entry.path());
				}
				std::sort(files.begin(), files.end(), [](const fs::path& a, const fs::path& b) {
					return a.filename().wstring() > b.filename().wstring();
				});
				for (size_t i = LOG_FILES_KEPT; i < files.size(); ++i) fs::remove(files[i], ec);
			}
			catch (...) {
			}
		}

		static void WriteFileLogLine(const std::wstring& line) { fileLogWriter.enqueue(line); }

		Platform::String^ StringPrintf(const char* fmt, ...) {
			va_list args;
			va_start(args, fmt);

			va_list args_copy;
			va_copy(args_copy, args);
			auto size = vsnprintf(nullptr, 0, fmt, args_copy);
			va_end(args_copy);

			if (size < 0) {
				va_end(args);
				return nullptr;
			}

			// Needs space for NUL char
			std::vector<char> message(size + 1, 0);
			vsnprintf_s(message.data(), message.size(), message.size(), fmt, args);
			va_end(args);

			return ref new Platform::String(NarrowToWideString(std::string_view(message.data())).c_str());
		}

		std::wstring GetCurrentTimestamp() {
			auto now = system_clock::now();
			auto ms = duration_cast<milliseconds>(now.time_since_epoch()) % 1000;
			std::time_t tt = system_clock::to_time_t(now);
			std::tm local_tm{};
			localtime_s(&local_tm, &tt);

			wchar_t buffer[32];
			swprintf(buffer, 32, L"[%02d:%02d:%02d.%03d] ",
			         local_tm.tm_hour,
			         local_tm.tm_min,
			         local_tm.tm_sec,
			         static_cast<int>(ms.count()));
			return std::wstring(buffer);
		}

		void Log(const std::string_view& msg) {
			try {
				std::wstring string = GetCurrentTimestamp() + NarrowToWideString(msg);
				OutputDebugString(string.c_str());
				WriteFileLogLine(string);
				{
					std::unique_lock<std::mutex> lk(logMutex);
					if (logLines.size() == LOG_LINES) {
						logLines.erase(logLines.begin());
					}
					for (auto& ch : string) {
						// ModeSeven renders [ ] as left and right arrows, so we replace them
						// with { } which render as brackets
						if (ch == L'[') {
							ch = L'{';
						}
						else if (ch == L']') {
							ch = L'}';
						}
					}
					logLines.push_back(string);
				}
			}
			catch (...) {

			}
		}

		void Log(const char* msg) {
			if (msg) {
				Log(std::string_view(msg));
			}
		}

		void Logf(const char* format, ...) {
			va_list args;
			va_start(args, format);

			char buf[1024];
			std::vsnprintf(buf, sizeof(buf) - 1, format, args);
			va_end(args);

			Log(std::string_view(buf));
		}

		std::vector<std::wstring> GetLogLines() {
			std::lock_guard<std::mutex> lock(logMutex);
			return logLines;
		}

		Platform::String^ StringFromChars(const char* chars)
		{
			if (chars == nullptr) {
				return nullptr;
			}
			return ref new Platform::String(NarrowToWideString(std::string_view(chars)).c_str());
		}

		Platform::String^ StringFromStdString(std::string input) {
			return ref new Platform::String(NarrowToWideString(input).c_str());
		}

		std::string PlatformStringToStdString(Platform::String ^input) {
			return WideToNarrowString(std::wstring(input->Begin()));
		}

		std::string WideToNarrowString(const std::wstring_view& str) {
			auto bufferSize = WideCharToMultiByte(CP_UTF8,
				0,
				str.data(),
				str.length(),
				nullptr,
				0, nullptr, nullptr);

			std::string result;
			result.resize(bufferSize);
			WideCharToMultiByte(CP_UTF8,
				0,
				str.data(),
				str.length(),
				result.data(),
				result.size(), nullptr, nullptr);

			return result;
		}

		std::wstring NarrowToWideString(const std::string_view& str) {
			auto bufferSize = MultiByteToWideChar(CP_UTF8,
				0,
				str.data(),
				str.length(),
				nullptr,
				0);

			std::wstring result;
			result.resize(bufferSize);
			MultiByteToWideChar(CP_UTF8,
				0,
				str.data(),
				str.length(),
				result.data(),
				result.size());

			return result;
		}

		bool ShowDevTools() {
			// Allow Frame Capture with Andy's build
			if (Windows::ApplicationModel::Package::Current->DisplayName == "Moonlight UWP (AndyG)") {
				return true;
			}

			// I think this check for Dev Mode only works when the app is deployed from Visual Studio
			if (Windows::ApplicationModel::Package::Current->IsDevelopmentMode) {
				return true;
			}

			return false;
		}
	}
}
