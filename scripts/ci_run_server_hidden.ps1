# Portable distribution launcher. All paths are relative to the extracted app.
$ErrorActionPreference = 'Continue'
$projectRoot = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $projectRoot 'server'
$logDir = Join-Path $projectRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$stdoutLog = Join-Path $logDir 'server.stdout.log'
$stderrLog = Join-Path $logDir 'server.stderr.log'
$python = Join-Path $projectRoot 'runtime\python.exe'

function Write-LauncherLog([string]$message) {
    ('{0:o} launcher: {1}' -f [DateTime]::Now,$message) |
        Add-Content -LiteralPath $stderrLog -Encoding UTF8
}

# The desktop client may be launched more than once; run only one backend.
$mutex = New-Object System.Threading.Mutex($false, 'Local\ClassNotesAssistantBackend8000')
$ownsMutex = $false
$resultCode = 1
try {
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) {
        Write-LauncherLog 'Another local backend launcher is already active.'
        exit 0
    }
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        Write-LauncherLog 'Bundled Python is missing.'
        exit 103
    }
    $env:CNA_CONFIG_FILE = 'config/config.local.yaml'
    Set-Location -LiteralPath $serverDir
    $probe = & $python -c 'import fastapi,uvicorn,sqlalchemy,aiosqlite; print(314159265)' 2>&1
    if ($LASTEXITCODE -ne 0 -or -not ($probe -join "`n").Contains('314159265')) {
        Write-LauncherLog 'Bundled Python dependency probe failed.'
        exit 103
    }
    Write-LauncherLog 'Starting bundled backend.'
    & $python -m app.main 1>> $stdoutLog 2>> $stderrLog
    $resultCode = $LASTEXITCODE
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
exit $resultCode
