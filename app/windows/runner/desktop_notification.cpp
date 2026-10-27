#include "desktop_notification.h"
#include "startup_registration.h"
#include <windows.h>
#include <shlobj.h>
#include <propkey.h>
#include <propvarutil.h>
#include <wrl/client.h>
#include <filesystem>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>

namespace {

constexpr wchar_t kAppId[] = L"ClassNotesAssistant.Desktop";

// A matching name alone does not make a user's shortcut ours to replace.
bool IsShortcutForExecutable(const std::filesystem::path& shortcut,
                             const std::wstring& executable) {
  Microsoft::WRL::ComPtr<IShellLinkW> link;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                             IID_PPV_ARGS(&link)))) return false;
  Microsoft::WRL::ComPtr<IPersistFile> file;
  if (FAILED(link.As(&file)) ||
      FAILED(file->Load(shortcut.c_str(), STGM_READ))) return false;
  wchar_t target[32768] = {};
  if (FAILED(link->GetPath(target, 32768, nullptr, SLGP_RAWPATH))) return false;
  std::error_code error;
  return std::filesystem::equivalent(target, executable, error) && !error;
}

bool EnsureNotificationShortcut(const std::filesystem::path& programs_path,
                                const std::wstring& executable) {
  const auto link_path = programs_path / L"remember.lnk";
  if (std::filesystem::exists(link_path) &&
      !IsShortcutForExecutable(link_path, executable)) return false;
  Microsoft::WRL::ComPtr<IShellLinkW> link;
  winrt::check_hresult(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                       IID_PPV_ARGS(&link)));
  winrt::check_hresult(link->SetPath(executable.c_str()));
  winrt::check_hresult(link->SetWorkingDirectory(std::filesystem::path(executable).parent_path().c_str()));
  winrt::check_hresult(link->SetDescription(L"remember"));
  winrt::check_hresult(link->SetIconLocation(executable.c_str(), 0));
  Microsoft::WRL::ComPtr<IPropertyStore> properties;
  winrt::check_hresult(link.As(&properties));
  PROPVARIANT value;
  winrt::check_hresult(InitPropVariantFromString(kAppId, &value));
  const auto property_result = properties->SetValue(PKEY_AppUserModel_ID, value);
  PropVariantClear(&value);
  winrt::check_hresult(property_result);
  winrt::check_hresult(properties->Commit());
  Microsoft::WRL::ComPtr<IPersistFile> file;
  winrt::check_hresult(link.As(&file));
  winrt::check_hresult(file->Save(link_path.c_str(), TRUE));
  const auto legacy_link = programs_path /
      L"\u8bfe\u5802\u5b66\u4e60\u52a9\u624b.lnk";
  if (IsShortcutForExecutable(legacy_link, executable)) {
    std::error_code error;
    std::filesystem::remove(legacy_link, error);
  }
  return true;
}

}  // namespace

int ShowDesktopNotification(const std::string& title, const std::string& message) {
  try {
    winrt::init_apartment(winrt::apartment_type::single_threaded);
    winrt::check_hresult(SetCurrentProcessExplicitAppUserModelID(kAppId));
    PWSTR programs = nullptr;
    winrt::check_hresult(SHGetKnownFolderPath(FOLDERID_Programs, 0, nullptr, &programs));
    const auto programs_path = std::filesystem::path(programs);
    CoTaskMemFree(programs);
    const auto executable = startup::Executable();
    if (!EnsureNotificationShortcut(programs_path, executable)) return 1;
    using namespace winrt::Windows::UI::Notifications;
    const auto notifier = ToastNotificationManager::CreateToastNotifier(kAppId);
    if (notifier.Setting() != NotificationSetting::Enabled) return 2;
    auto xml = ToastNotificationManager::GetTemplateContent(ToastTemplateType::ToastText02);
    auto text = xml.GetElementsByTagName(L"text");
    text.Item(0).AppendChild(xml.CreateTextNode(winrt::to_hstring(title)));
    text.Item(1).AppendChild(xml.CreateTextNode(winrt::to_hstring(message)));
    notifier.Show(ToastNotification(xml));
    return 0;
  } catch (...) {
    return 1; // Notification failure must never fail transcription.
  }
}
