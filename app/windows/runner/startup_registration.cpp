#include "startup_registration.h"

#include <stdexcept>
#include <vector>

namespace startup {
namespace {
std::wstring Command(const std::wstring& executable) {
  if (executable.empty() || executable.find(L'"') != std::wstring::npos ||
      executable.size() + 2 > 260) {
    throw std::runtime_error("Startup executable path is invalid or too long");
  }
  return L"\"" + executable + L"\"";
}
void Check(LSTATUS code) {
  if (code != ERROR_SUCCESS) {
    throw std::runtime_error("Windows startup registration failed (" +
                             std::to_string(code) + ")");
  }
}
}  // namespace

std::wstring Executable() {
  std::vector<wchar_t> path(32768);
  const auto length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!length || length >= path.size()) throw std::runtime_error("Cannot read executable path");
  return std::wstring(path.data(), length);
}

bool Read(const std::wstring& executable, const wchar_t* key) {
  DWORD bytes = 0;
  auto code = RegGetValueW(HKEY_CURRENT_USER, key, kValue,
                          RRF_RT_REG_SZ, nullptr, nullptr, &bytes);
  if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND) return false;
  Check(code);
  if (bytes < sizeof(wchar_t) || bytes > 65536) throw std::runtime_error("Invalid startup value");
  std::vector<wchar_t> value(bytes / sizeof(wchar_t) + 1, L'\0');
  Check(RegGetValueW(HKEY_CURRENT_USER, key, kValue, RRF_RT_REG_SZ,
                    nullptr, value.data(), &bytes));
  return _wcsicmp(value.data(), Command(executable).c_str()) == 0;
}

void Set(bool enabled, const std::wstring& executable, const wchar_t* key) {
  const auto command = Command(executable);
  HKEY opened = nullptr;
  if (enabled) {
    Check(RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, nullptr, 0,
                         KEY_SET_VALUE, nullptr, &opened, nullptr));
    const auto code = RegSetValueExW(opened, kValue, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(opened);
    Check(code);
  } else {
    const auto code = RegOpenKeyExW(HKEY_CURRENT_USER, key, 0, KEY_SET_VALUE, &opened);
    if (code != ERROR_FILE_NOT_FOUND && code != ERROR_PATH_NOT_FOUND) {
      Check(code);
      const auto removed = RegDeleteValueW(opened, kValue);
      RegCloseKey(opened);
      if (removed != ERROR_FILE_NOT_FOUND) Check(removed);
    }
  }
  if (Read(executable, key) != enabled) throw std::runtime_error("Startup setting verification failed");
}
}  // namespace startup
