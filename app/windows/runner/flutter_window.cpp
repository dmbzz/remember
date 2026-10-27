#include "flutter_window.h"

#include <optional>
#include <commdlg.h>
#include <shlobj.h>
#include <filesystem>
#include <fstream>
#include <vector>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "startup_registration.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  startup_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "class_notes/windows_startup",
      &flutter::StandardMethodCodec::GetInstance());
  startup_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    try {
      if (call.method_name() == "getEnabled") {
        result->Success(flutter::EncodableValue(startup::Read(startup::Executable())));
      } else if (call.method_name() == "setEnabled") {
        const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
        if (!enabled) { result->Error("INVALID_ARGUMENT", "Expected a boolean"); return; }
        startup::Set(*enabled, startup::Executable());
        result->Success(flutter::EncodableValue(*enabled));
      } else {
        result->NotImplemented();
      }
    } catch (const std::exception& error) {
      result->Error("STARTUP_FAILED", error.what());
    }
  });
  import_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "class_notes/schedule_import",
      &flutter::StandardMethodCodec::GetInstance());
  import_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "pickDirectory") {
      BROWSEINFOW info = {};
      info.hwndOwner = GetHandle();
      info.lpszTitle = L"Select a folder";
      info.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
      auto folder = SHBrowseForFolderW(&info);
      if (!folder) { result->Success(); return; }
      wchar_t selected[MAX_PATH] = {};
      const bool ok = SHGetPathFromIDListW(folder, selected) != FALSE;
      CoTaskMemFree(folder);
      if (!ok) { result->Error("FOLDER_FAILED", "Cannot read selected directory"); return; }
      const int size = WideCharToMultiByte(CP_UTF8, 0, selected, -1, nullptr, 0, nullptr, nullptr);
      if (size <= 1) { result->Error("FOLDER_FAILED", "Cannot encode selected directory"); return; }
      std::string utf8(size, '\0');
      if (!WideCharToMultiByte(CP_UTF8, 0, selected, -1, utf8.data(), size, nullptr, nullptr)) {
        result->Error("FOLDER_FAILED", "Cannot encode selected directory"); return;
      }
      utf8.resize(size - 1);
      result->Success(flutter::EncodableValue(utf8));
      return;
    }
    if (call.method_name() != "pickIcs") { result->NotImplemented(); return; }
    wchar_t path[32768] = {};
    OPENFILENAMEW dialog = {};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = GetHandle();
    dialog.lpstrFilter = L"ICS calendar (*.ics)\0*.ics\0\0";
    dialog.lpstrFile = path;
    dialog.nMaxFile = 32768;
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&dialog)) {
      if (CommDlgExtendedError()) result->Error("PICK_FAILED", "Cannot open file dialog");
      else result->Success();
      return;
    }
    std::ifstream file(std::filesystem::path(path), std::ios::binary | std::ios::ate);
    if (!file || file.tellg() <= 0 || file.tellg() > 5 * 1024 * 1024) {
      result->Error("READ_FAILED", "ICS file is empty, unreadable or larger than 5 MB"); return;
    }
    std::vector<uint8_t> bytes(static_cast<size_t>(file.tellg()));
    file.seekg(0);
    if (!file.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()))) {
      result->Error("READ_FAILED", "Cannot read ICS file"); return;
    }
    auto name = std::filesystem::path(path).filename().u8string();
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("name"), flutter::EncodableValue(name)},
      {flutter::EncodableValue("bytes"), flutter::EncodableValue(bytes)}
    }));
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  startup_channel_ = nullptr;
  import_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
