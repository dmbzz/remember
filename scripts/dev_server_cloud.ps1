# 启动云端模式后端（读 config/config.cloud.yaml）
# 用法：pwsh ./scripts/dev_server_cloud.ps1
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $projectRoot "server"

# Runtime is explicit, project-local, or found on PATH.
$python = $env:CNA_PYTHON
if (-not $python) {
    $localPython = Join-Path $serverDir '.venv\Scripts\python.exe'
    $python = if (Test-Path -LiteralPath $localPython) { $localPython } else {
        Get-Command python -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    }
}
if (-not $python) { throw 'Create server/.venv or set CNA_PYTHON to a configured Python interpreter.' }

$env:CNA_CONFIG_FILE = "config/config.cloud.yaml"
Write-Host "[dev_server_cloud] 云端模式启动，配置：$env:CNA_CONFIG_FILE"
Write-Host "[dev_server_cloud] 提示：云端模式强制鉴权（除 /api/health 外需 Bearer Token）"

Set-Location $serverDir
& $python -m app.main
