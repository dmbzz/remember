<p align="center"><img src="docs/brand/remember.png" width="112" alt="remember 复习折页图标"></p>

# remember

把值得记住的课堂片段留下来，之后回来重温。

remember 是面向 Android 与 Windows 的课表、笔记和课堂录音工具。当前版本 **0.1.37+38**，使用“复习折页”品牌图标。

## 功能

- **课表**：ICS 导入、当天/整周切换、每日节数与上课时间、教学周/单双周、具体日期调课。
- **课堂录音**：Android 选择课程录音，离线保存，到点录音需授予权限并保持相应前台服务状态。
- **录音同步**：连回运行中的电脑后重试上传；确认电脑完整收到后清理手机副本。
- **Windows 转写**：配置并启用 Qwen 后，完整上传的录音入队转写为带时间戳的 TXT，显示真实任务状态。
- **笔记阅读**：Markdown、公式、表格与思维导图，保留本机笔记目录和手机离线阅读。
- **应用内同步**：电脑默认下发到手机，每日自动核对及手动核对；有显式来源选择时按选择执行。
- **系统入口**：Android 课表小组件、课程提醒；Windows 可选开机自启和转写通知。

## 两端连接

1. Windows 打开 remember，本机后端在可用运行环境中启动。
2. 点击“连接手机”，复制当前完整连接码。
3. 手机与电脑处于同一个可信局域网，在“连接电脑”输入连接码。

离开电脑仍可使用已缓存课程录音及本地笔记。上传、电脑转写和电脑文件访问需要电脑运行且网络可达；这不是手机离线云服务。自动录音和小组件行为受 Android/HyperOS 权限、系统后台限制及实际设备影响。

## 开发

```
app/             Flutter Android / Windows 客户端
server/          FastAPI 服务、配置示例与测试
docs/brand/      已选品牌原稿与接入说明
```

客户端使用 Flutter 3.24、Android SDK 34 / JDK 17；Windows 需要 Visual Studio C++ 桌面工具链。安装依赖后，在 `app/` 下执行 `flutter run -d windows` 或 `flutter build apk --release`。正式发布应使用自己的签名和构建环境。

服务端在 Python 3.13 环境安装 `server/requirements.txt`，按配置示例设置个人数据目录与数据库，再从 `server/` 运行 `python -m app.main`。Qwen 环境、模型与 FFmpeg 需单独准备；服务不会自动安装显卡驱动或下载模型。

本机发行目录可能使用已配置运行时；源码副本不内置所有电脑的 Python/模型环境，不将个人路径当作通用部署要求。

## 品牌与升级

对外名称统一为小写 **remember**。图标原稿为 `docs/brand/remember.svg`。Android launcher/adaptive/round/monochrome、Windows ICO、应用内品牌及网页图标按各宿主分别生成。

为兼容原安装的数据与配对，保留原 Android application ID、Windows 存储身份和内部通道。它们不是产品显示名称。

请勿把个人录音、笔记、数据库、访问令牌、签名私钥或 `*.user.*` 本机配置上传仓库。

## 许可

仓库沿用创建时选择的 Apache-2.0 许可（LICENSE），仅适用于有权授权的自有代码。字体与第三方依赖各自的许可和未完成事项见 THIRD_PARTY_NOTICES.md。测试 ICS 为完全虚构的合成数据，不含用户实际课表。
