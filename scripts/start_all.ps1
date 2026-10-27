# 一键启动：检测并按需启动本地后端，立即打开 Windows 桌面端。
#
# 由项目根「启动.bat」双击调用；也可直接运行：
#     powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start_all.ps1
#
# 环境：Windows + Windows PowerShell 5.1（本机 ACP = UTF-8）。
#
# 可选覆盖（便于测试 / 自定义构建，正常使用无需设置）：
#     CNA_APP_EXE     指定 Windows 端 exe 路径（默认 app\build\windows\x64\runner\Release\app.exe）
#     CNA_START_PORT  指定后端端口（默认 8000）
#
# 退出码：0 = 后端就绪且已打开前端；1 = 启动异常（前端可能已打开并显示连接状态）。

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 路径（全部基于脚本自身位置，双击或任意工作目录均可）
# ---------------------------------------------------------------------------
$scriptDir    = $PSScriptRoot
$projectRoot  = Split-Path -Parent $scriptDir
$devServerPs1 = Join-Path $scriptDir "dev_server.ps1"

$defaultAppExe = Join-Path $projectRoot "app\build\windows\x64\runner\Release\app.exe"
$appExe = if ($env:CNA_APP_EXE) { $env:CNA_APP_EXE } else { $defaultAppExe }

$backendPort = if ($env:CNA_START_PORT) { [int]$env:CNA_START_PORT } else { 8000 }
$healthUrl   = "http://127.0.0.1:$backendPort/api/health"
$readyTimeoutSeconds = 30

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
function Write-Info([string]$message) { Write-Host $message }
function Write-Err([string]$message) {
    Write-Host ""
    Write-Host "[错误] $message" -ForegroundColor Red
}

# 探测「本项目后端」是否就绪：/api/health 返回 200，且 JSON 命中本项目标识。
# 用 HttpWebRequest 直连（Proxy=$null）绕过系统代理，避免 127.0.0.1 被代理拦截。
function Test-BackendReady {
    try {
        $req = [System.Net.HttpWebRequest]::Create($healthUrl)
        $req.Method  = "GET"
        $req.Timeout = 700
        $req.Proxy   = $null
        $resp = $req.GetResponse()
        try {
            if ([int]$resp.StatusCode -ne 200) { return $false }
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            $reader.Close()
        } finally {
            $resp.Close()
        }
        $json = $body | ConvertFrom-Json
        return ($json.code -eq 0 -and $json.data.status -eq 'ok' -and $json.data.app -eq 'class_notes_assistant')
    } catch {
        return $false
    }
}

# 该端口是否有进程在监听（用于区分「非本项目进程占用」）。
# 首选 Get-NetTCPConnection（快、无输出）；仅当该 cmdlet 不存在（老系统）时才回退 Test-NetConnection。
# 注意：端口空闲时 Get-NetTCPConnection 会返回空集合，并发出一条「无匹配对象」的**非终止**错误；
#       这里用 -ErrorAction SilentlyContinue 抑制它，避免误触发回退（Test-NetConnection 会打印
#       "Waiting for response" 进度污染启动窗口）。
function Test-PortListening([int]$port) {
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        return (@($conns).Count -gt 0)
    }
    try {
        $tcp = Test-NetConnection -ComputerName "127.0.0.1" -Port $port -WarningAction SilentlyContinue -InformationLevel Quiet
        return [bool]$tcp
    } catch { }
    return $false
}

# ---------------------------------------------------------------------------
# 0) 前置检查：前端可执行文件必须存在（失败即退出，不启动后端，避免白开一个窗口）
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $appExe)) {
    Write-Err "未找到 Windows 桌面端程序：`n        $appExe"
    Write-Info "请先构建 Windows 端，再运行本启动器。构建命令（在项目根执行）："
    Write-Info "        powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows.ps1"
    exit 1
}

Write-Info "========================================================"
Write-Info "        remember  ——  一键启动"
Write-Info "========================================================"
Write-Info ("项目根：{0}" -f $projectRoot)
Write-Info ""

# ---------------------------------------------------------------------------
# 1) 后端：已在跑 → 跳过；端口被别的程序占 → 报错；否则 → 新窗口启动
# ---------------------------------------------------------------------------
if (Test-BackendReady) {
    Write-Info ("[1/3] 后端已在运行（{0}），跳过启动。" -f $healthUrl)
}
elseif (Test-PortListening $backendPort) {
    Write-Err ("端口 {0} 已被「其他程序」占用，但它不是本项目后端。" -f $backendPort)
    Write-Info "请先找到并关闭占用该端口的程序，再重新运行本启动器："
    Write-Info ("        netstat -ano | findstr :{0}" -f $backendPort)
    Write-Info "        taskkill /PID <上面列出的PID> /F"
    exit 1
}
else {
    if (-not (Test-Path -LiteralPath $devServerPs1)) {
        Write-Err "未找到后端启动脚本：$devServerPs1"
        exit 1
    }
    Write-Info ("[1/3] 后端未运行，正在后台启动（端口 {0}）……" -f $backendPort)
    $logDir = Join-Path $projectRoot "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $serverOutLog = Join-Path $logDir "server.out.log"
    $serverErrLog = Join-Path $logDir "server.err.log"
    # 后端后台运行，输出落在项目日志；界面无需等 Python 完全启动。
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $devServerPs1) `
        -WorkingDirectory $projectRoot -WindowStyle Hidden `
        -RedirectStandardOutput $serverOutLog -RedirectStandardError $serverErrLog | Out-Null
}

# ---------------------------------------------------------------------------
# 2) 先打开前端，让用户立即看到界面；笔记页会自动重试连接。
# ---------------------------------------------------------------------------
Write-Info "[2/3] 正在打开 Windows 桌面端……"
Start-Process -FilePath $appExe -WorkingDirectory (Split-Path -Parent $appExe) | Out-Null

# ---------------------------------------------------------------------------
# 3) 检查后端就绪状态（轮询 /api/health，最多约 30 秒）
# ---------------------------------------------------------------------------
Write-Info ("[3/3] 等待后端就绪（最多 {0} 秒）……" -f $readyTimeoutSeconds)
$deadline = (Get-Date).AddSeconds($readyTimeoutSeconds)
$ready = $false
while ((Get-Date) -lt $deadline) {
    if (Test-BackendReady) { $ready = $true; break }
    Start-Sleep -Milliseconds 800
}

if (-not $ready) {
    Write-Err ("后端在 {0} 秒内仍未就绪。前端已打开，可在设置页检查服务地址。" -f $readyTimeoutSeconds)
    Write-Info ("后端日志：{0}" -f (Join-Path $projectRoot 'logs'))
    Write-Info "常见原因："
    Write-Info "  - Python 依赖未安装（在 server\ 下执行：pip install -r requirements.txt）"
    Write-Info "  - 端口被占用 / 配置错误 / 数据库或数据目录不可写"
    exit 1
}
Write-Info "[3/3] 后端已就绪 ✓"
Write-Info "启动完成。本窗口将在 1 秒后自动关闭。"
Start-Sleep -Seconds 1
exit 0
