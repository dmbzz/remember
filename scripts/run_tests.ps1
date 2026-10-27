# 运行后端测试（pytest，使用全路径 Python）
# 用法：pwsh ./scripts/run_tests.ps1
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

Set-Location $serverDir
& $python -m pytest -q @args
