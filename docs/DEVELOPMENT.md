# 开发与配置

源码版本 0.1.37+38，包含 Flutter Windows/Android 客户端、Kotlin 原生录音/排期/组件/SAF 文件事务、Windows 原生通知/开机启动和 FastAPI 后端。内部包名、方法通道和存储身份仍使用历史名称，以兼容现有安装。

## 本地启动

安装兼容项目的 Flutter SDK、Android SDK/JDK（Android），或 Visual Studio C++ 桌面工具链（Windows）。当前源码的 Dart/Flutter 约束和版本锁见 app/pubspec.yaml 与 pubspec.lock。Android 已保留原有 gradlew、gradlew.bat、wrapper JAR 和 properties；运行 Flutter 命令会生成本机 local.properties。不要提交该文件或个人签名密钥。

```powershell
python -m venv server/.venv
server/.venv/Scripts/python.exe -m pip install -r server/requirements.txt
./scripts/dev_server.ps1
```

另开终端：

```powershell
cd app
flutter pub get
flutter run -d windows
# 或 flutter build apk --release
```

也可在 server/ 下执行 `python -m app.main`，在浏览器打开 http://127.0.0.1:8000。Windows 客户端从完整项目启动时会寻找 scripts/run_server_hidden.ps1，优先使用 CNA_PYTHON 或 server/.venv。构建产物需要和 Python 后端、运行时及依赖一起合理打包；本源码压缩包没有附带 Python/模型/FFmpeg/Flutter SDK。

本地默认数据位于 server/ 工作目录下的 ./data/remember.db、./data/storage、./data/notes 和 ./data/textbooks。实际笔记库和录音位置可以在电脑端设置；库需由用户自行准备。敏感配置放 server/config/config.user.yaml、server/config/asr.user.json、server/config/desktop.user.json 或 server/.env，均被 .gitignore 排除。不要把示例配置误当成真实凭据。

Android 模拟器默认使用 10.0.2.2:8000；真机需要在设置填写电脑局域网地址，完成应用内配对并授予相应权限。常驻通知、后台录音、精确闹钟和小组件的实际行为取决于 Android/厂商设置，构建成功不代表目标手机已经验证。

## Qwen 转写

上传触发的自动转写默认关闭。使用电脑端录音页的转写设置，填写存在的绝对输出目录和 Qwen3-ASR-1.7B/ForcedAligner 路径，或兼容的 Qwen 服务地址；服务密钥只保存在本机配置。local Qwen 模式需要在所选 Python 环境安装对应 Qwen、PyTorch 和音频依赖，这些不随 server/requirements.txt 自动安装。硬件运行时需要按实际设备选择，GPU 失败时同一 Qwen 引擎可回退 CPU。

可选检测根为 ~/.remember/asr（通过 REMEMBER_ASR_HOME 覆盖）：venv/Scripts/python.exe 或 venv/bin/python、models/Qwen3-ASR-1.7B、models/Qwen3-ForcedAligner-0.6B、bin/ffmpeg[.exe]。也可从 PATH 检测 FFmpeg；REMEMBER_TRANSCRIPT_DIR 仅在显式设置且目录存在时提供输出建议。自动检测不会读取其他应用的安装目录。不要提交模型权重或真实录音。

## 验证与边界

后端在 server/ 下运行 `python -m pytest -q`；Flutter 在 app/ 下运行 `flutter test`。Android 原生测试可从 app/android 运行现有 Gradle 测试任务。ASR 模型/服务和实体 Android/Windows 系统功能需另外验证。更新下载 API 需要自行放置构建出的安装包，源码副本不包含发布 APK。

笔记同步默认每天一次并保留手动操作；当前电脑优先覆盖策略、手机独有文件保留及显式来源选择与源版本一致。源文件、扫描教材、笔记、录音、数据库和配对凭据均不包含在仓库中。

LICENSE 沿用用户创建仓库时选择的 Apache-2.0，仅用于有权授权的自有代码。PyMuPDF 等第三方依赖有各自义务；发布前阅读 THIRD_PARTY_NOTICES.md。该说明不等于已完成全部依赖许可审计。
