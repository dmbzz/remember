#ifndef RUNNER_STARTUP_REGISTRATION_H_
#define RUNNER_STARTUP_REGISTRATION_H_

#include <windows.h>
#include <string>

namespace startup {
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kValue[] = L"ClassNotesAssistant";

// The optional key exists solely for exercising persistence in an isolated test key.
bool Read(const std::wstring& executable, const wchar_t* key = kRunKey);
void Set(bool enabled, const std::wstring& executable, const wchar_t* key = kRunKey);
std::wstring Executable();
}  // namespace startup
#endif
