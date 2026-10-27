# Windows local backend launcher: validate the runtime, then retry transient
# runtime failures. Never accept an executable merely because its path exists.
$ErrorActionPreference = 'Continue'
$projectRoot = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $projectRoot 'server'
$logDir = Join-Path $projectRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$stdoutLog = Join-Path $logDir 'server.stdout.log'
$stderrLog = Join-Path $logDir 'server.stderr.log'
$pythonCandidates = @(
    $env:CNA_PYTHON,
    (Join-Path $serverDir '.venv\Scripts\python.exe'),
    (Join-Path $projectRoot 'runtime\Scripts\python.exe'),
    (Get-Command python -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
) | Where-Object { $_ }

function Write-LauncherLog([string]$message) {
    ('{0:o} launcher: {1}' -f [DateTime]::Now,$message) |
        Add-Content -LiteralPath $stderrLog -Encoding UTF8
}

# Keep competing client launches from starting two servers on the same port.
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

    $env:CNA_CONFIG_FILE = 'config/config.local.yaml'
    Set-Location -LiteralPath $serverDir
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $python = $null
        foreach ($candidate in $pythonCandidates) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            try {
                $probe = & $candidate -c 'import fastapi,uvicorn,sqlalchemy,aiosqlite; print(314159265)' 2>&1
                $probeCode = $LASTEXITCODE
                if ($probeCode -eq 0 -and ($probe -join "`n").Contains('314159265')) {
                    $python = $candidate
                    break
                }
                Write-LauncherLog "Runtime probe failed code=$probeCode path=$candidate"
            } catch {
                Write-LauncherLog "Runtime probe could not execute path=$candidate"
            }
        }
        if (-not $python) {
            Write-LauncherLog "No usable Python runtime (attempt $attempt/3)."
            $resultCode = 103
        } else {
            Write-LauncherLog "Starting backend (attempt $attempt/3) using $python"
            & $python -m app.main 1>> $stdoutLog 2>> $stderrLog
            $resultCode = $LASTEXITCODE
            if ($resultCode -eq 0) { break }
            Write-LauncherLog "Backend exited code=$resultCode"
            # Retry runtime lookup after a temporary install/update failure.
            # Other server errors remain explicit in the log, without looping.
            if ($resultCode -ne 103) { break }
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
exit $resultCode
