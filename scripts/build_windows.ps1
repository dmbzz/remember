# 构建 Windows 桌面端（Flutter）。
# 会先检测 Visual Studio 的 C++ 桌面开发工具链；缺失时给出**明确提示**（而不是让 flutter build 抛一堆错）。
# 用法：pwsh ./scripts/build_windows.ps1
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $projectRoot "app"

function Get-FlutterPath {
    $candidates = @(
        (Get-Command flutter.bat -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Get-VsCppPath {
    # 1) 优先用 vswhere 精准查询「C++ 桌面开发」工作负载
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $path = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
        if ($LASTEXITCODE -eq 0 -and $path) { return $path.Trim() }
    }
    # 2) 回退：扫描常见安装目录
    $globs = @(
        "$env:ProgramFiles\Microsoft Visual Studio\2022\*\Common7\IDE",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\Common7\IDE"
    )
    foreach ($g in $globs) {
        $hit = Get-ChildItem -Path $g -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return (Split-Path -Parent (Split-Path -Parent $hit.FullName)) }
    }
    return $null
}

Write-Host "[build_windows] 项目根：$projectRoot"

$flutter = Get-FlutterPath
if (-not $flutter) {
    Write-Host "[build_windows] 未找到 Flutter SDK（flutter.bat）。请安装 Flutter 或将其加入 PATH。" -ForegroundColor Red
    exit 1
}
Write-Host "[build_windows] Flutter：$flutter"

$vs = Get-VsCppPath
if (-not $vs) {
    Write-Host ""
    Write-Host "[build_windows] 缺少 Visual Studio C++ 桌面开发工具链 —— 无法构建 Windows 端。" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Flutter 构建 Windows 桌面应用『必须』安装 Visual Studio 2022（Community 版即可），并勾选："
    Write-Host "    - 工作负载：『使用 C++ 的桌面开发』(Desktop development with C++)"
    Write-Host "    - 该工作负载内的『MSVC v143 - VS 2022 C++ x64/x86 生成工具』与『Windows 10/11 SDK』"
    Write-Host ""
    Write-Host "下载地址：https://visualstudio.microsoft.com/zh-hans/downloads/"
    Write-Host "安装完成后请重开终端，再次运行本脚本。"
    exit 1
}
Write-Host "[build_windows] 检测到 Visual Studio：$vs"

Set-Location $appDir
Write-Host "[build_windows] 开始构建（flutter build windows --release）..."
$buildLogDir = Join-Path $appDir "build/windows"
New-Item -ItemType Directory -Path $buildLogDir -Force | Out-Null
$buildLog = Join-Path $buildLogDir "last_flutter_build.log"
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $flutter build windows --release 2>&1 | Tee-Object -FilePath $buildLog
} finally {
    $ErrorActionPreference = $previousErrorAction
}
$flutterExit = $LASTEXITCODE
if ($flutterExit -ne 0) {
    $symlinkFailure = Select-String -Path $buildLog -Pattern "symlink support|PathExistsException" -Quiet
    if (-not $symlinkFailure) {
        Write-Host "[build_windows] Flutter 构建失败（退出码 $flutterExit），详见 $buildLog。" -ForegroundColor Red
        exit $flutterExit
    }
    # Windows 未启用开发者模式时 Flutter 无法创建插件链接。已有 CMake 工程
    # 可从 Pub 缓存复制两个 Windows 插件后继续增量构建，不改系统权限。
    Write-Host "[build_windows] 插件链接权限不足，尝试现有 CMake 工程增量构建..."
    $depsFile = Join-Path $appDir ".flutter-plugins-dependencies"
    $symlinkDir = Join-Path $appDir "windows/flutter/ephemeral/.plugin_symlinks"
    $buildDir = Join-Path $appDir "build/windows/x64"
    $cmake = Join-Path $vs "Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe"
    if (-not (Test-Path $depsFile) -or -not (Test-Path (Join-Path $buildDir "CMakeCache.txt")) -or -not (Test-Path $cmake)) {
        Write-Host "[build_windows] 缺少 CMake 增量构建所需缓存或工具，详见 $buildLog。" -ForegroundColor Red
        exit $flutterExit
    }
    $deps = Get-Content -LiteralPath $depsFile -Raw | ConvertFrom-Json
    New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
    foreach ($plugin in $deps.plugins.windows) {
        $pluginDir = Join-Path $symlinkDir $plugin.name
        if (-not (Test-Path -LiteralPath $pluginDir)) {
            Copy-Item -LiteralPath $plugin.path -Destination $pluginDir -Recurse -Force
        }
    }
    & $cmake --build $buildDir --config Release --target INSTALL
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[build_windows] CMake 增量构建也失败。" -ForegroundColor Red
        exit 1
    }
}

$outDir = Join-Path $appDir "build\windows\x64\runner\Release"
Write-Host "[build_windows] 构建成功 ✓" -ForegroundColor Green
Write-Host "[build_windows] 产物目录：$outDir"
if (Test-Path $outDir) {
    Get-ChildItem $outDir | Select-Object Name, Length | Format-Table -AutoSize
}
