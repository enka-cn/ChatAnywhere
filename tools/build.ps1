# ChatAnyWhere cross-agent build script.
#
# Serializes hvigor builds between parallel coding agents with a file lock,
# then prints only the actionable compiler diagnostics.
#
# 签名说明（重要）：
#   本机 DevEco 自动签名材料在 CLI 下可能报 `11014003 Init keystore failed`（环境问题，与源码无关）。
#   本脚本检测到该签名失败时会：临时把 build-profile.json5 的 signingConfigs 置空 → 重跑 → 立即恢复原配置，
#   从而保证「编译验证」不被环境签名问题阻塞，且不会改动用户已配置的签名材料。
#
# Usage:
#   pwsh tools/build.ps1                      # build entry HAP (compiles every module)
#   pwsh tools/build.ps1 -Module core_model   # build one HAR module only (fast inner loop)
#   pwsh tools/build.ps1 -Module chat         # same as default
#   pwsh tools/build.ps1 -LockTimeoutSec 2400
#
# Exit code: 0 = build ok, 1 = compile/build failure, 2 = lock timeout, 3 = toolchain missing.
param(
  [string]$Module = '',
  [int]$LockTimeoutSec = 2400
)

$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$deveco = 'C:\Application\DevEco Studio'
$node = Join-Path $deveco 'tools\node\node.exe'
$hvigor = Join-Path $deveco 'tools\hvigor\bin\hvigorw.js'
if (-not (Test-Path $node) -or -not (Test-Path $hvigor)) {
  Write-Output 'BUILD-ERROR: DevEco Studio toolchain not found at C:\Application\DevEco Studio'
  exit 3
}

$env:DEVECO_SDK_HOME = Join-Path $deveco 'sdk'
$env:JAVA_HOME = Join-Path $deveco 'jbr'

$harModules = @('core_model', 'core_protocol', 'core_context', 'core_plugin')
$isHarBuild = ($Module -ne '') -and ($harModules -contains $Module)

$lockDir = Join-Path $root '.build.lock'
$lockOwner = Join-Path $lockDir 'owner.txt'
$logDir = Join-Path $root 'build-logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# ---- acquire cross-agent build lock -------------------------------------
$deadline = (Get-Date).AddSeconds($LockTimeoutSec)
$acquired = $false
while (-not $acquired) {
  try {
    New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
    Set-Content -Path $lockOwner -Value ("agent={0} pid={1} at={2}" -f $env:DSH_AGENT_NAME, $PID, (Get-Date).ToString('s')) -ErrorAction SilentlyContinue
    $acquired = $true
  } catch {
    # reclaim a stale lock (holder died or hung)
    try {
      $ownerItem = Get-Item $lockOwner -ErrorAction SilentlyContinue
      if ($null -ne $ownerItem) {
        $age = (Get-Date) - $ownerItem.LastWriteTime
        if ($age.TotalMinutes -gt 20) {
          Remove-Item $lockDir -Recurse -Force -ErrorAction SilentlyContinue
          continue
        }
      } else {
        # 锁目录存在但 owner 文件已被并发进程清理：短暂等待后重试
        Start-Sleep -Seconds 1
        continue
      }
    } catch {
      # 锁被并发持有者释放：直接重试
      Start-Sleep -Seconds 1
      continue
    }
    if ((Get-Date) -gt $deadline) {
      Write-Output "BUILD-ERROR: timed out waiting for the build lock at $lockDir (holder: $(Get-Content $lockOwner -ErrorAction SilentlyContinue))"
      exit 2
    }
    Start-Sleep -Seconds 3
  }
}

# ---- build helpers -------------------------------------------------------
function Invoke-HvigorBuild {
  param(
    [string[]]$HvigorArgs,
    [string]$LogPath
  )
  Push-Location $root
  & $node $hvigor @HvigorArgs 2>&1 | Tee-Object -FilePath $LogPath | Out-Null
  $code = $LASTEXITCODE
  Pop-Location
  return $code
}

function Get-Diagnostics {
  param([string]$LogPath)
  $lines = Get-Content $LogPath -ErrorAction SilentlyContinue
  $noise = '^(> hvigor (Finished|UP-TO-DATE|Running|WARN: Will skip sign)|\s+If needed, configure|\s+\d+ tasks in total|BUILD-LOG)'
  $useful = @($lines | Where-Object { $_ -and ($_ -notmatch $noise) })
  $errors = @($useful | Where-Object { $_ -match 'Error Message|At File:|ArkTS:ERROR|ERROR:|BUILD FAILED|COMPILE RESULT:FAIL' })
  return @{ Lines = $lines; Useful = $useful; Errors = $errors }
}

$exitCode = 1
$logPath = ''
$retriedUnsigned = $false
$buildProfileBackup = $null
$buildProfilePath = Join-Path $root 'build-profile.json5'

try {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $label = if ($Module) { $Module } else { 'all' }
  $logPath = Join-Path $logDir ("{0}-{1}.log" -f $label, $stamp)

  if ($isHarBuild) {
    $hvigorArgs = @('assembleHar', '--mode', 'module', '-p', "module=$Module@default", '--no-daemon')
  } else {
    $hvigorArgs = @('assembleHap', '--no-daemon')
  }

  $exitCode = Invoke-HvigorBuild -HvigorArgs $hvigorArgs -LogPath $logPath

  # ---- environment signing fallback (HAP only) ---------------------------
  if ($exitCode -ne 0 -and -not $isHarBuild) {
    $info = Get-Diagnostics -LogPath $logPath
    $signFailure = @($info.Lines | Where-Object { $_ -match 'SignHap|11014003|Init keystore' }).Count -gt 0
    $hasAnyCompileError = @($info.Lines | Where-Object { $_ -match 'ArkTS:ERROR|COMPILE RESULT:FAIL' }).Count -gt 0
    if ($signFailure -and -not $hasAnyCompileError -and (Test-Path $buildProfilePath)) {
      $buildProfileBackup = [System.IO.File]::ReadAllText($buildProfilePath)
      $patched = [regex]::Replace($buildProfileBackup, '("signingConfigs"\s*:\s*)\[\s*[\s\S]*?\]', '$1[]', 1)
      if ($patched -ne $buildProfileBackup) {
        [System.IO.File]::WriteAllText($buildProfilePath, $patched, (New-Object System.Text.UTF8Encoding($false)))
        $unsignedLog = $logPath -replace '\.log$', '-unsigned.log'
        Write-Output 'NOTE: 本机签名材料在 CLI 下不可用（11014003），已临时跳过签名重试（build-profile.json5 稍后自动恢复）。'
        $exitCode = Invoke-HvigorBuild -HvigorArgs $hvigorArgs -LogPath $unsignedLog
        if (Test-Path $unsignedLog) { $logPath = $unsignedLog }
        $retriedUnsigned = $true
      }
    }
  }

  $info = Get-Diagnostics -LogPath $logPath
  $useful = $info.Useful
  $errors = $info.Errors

  if ($exitCode -eq 0) {
    if ($retriedUnsigned) {
      Write-Output "BUILD-OK ($label) [unsigned verification: signingConfigs 已临时跳过并恢复]"
    } else {
      Write-Output "BUILD-OK ($label)"
    }
    $warns = @($useful | Where-Object { $_ -match 'ArkTS:WARN' })
    if ($warns.Count -gt 0) {
      Write-Output "WARNINGS: $($warns.Count) (see log)"
    }
    Write-Output "LOG: $logPath"
  } else {
    Write-Output "BUILD-FAILED ($label), exit=$exitCode"
    Write-Output '--- diagnostics ---'
    if ($errors.Count -eq 0) {
      $useful | Select-Object -Last 40 | ForEach-Object { Write-Output $_ }
    } else {
      $errors | Select-Object -First 60 | ForEach-Object { Write-Output $_ }
    }
    Write-Output '--- end diagnostics ---'
    Write-Output "FULL LOG: $logPath"
  }
} finally {
  if ($buildProfileBackup -ne $null) {
    try {
      [System.IO.File]::WriteAllText($buildProfilePath, $buildProfileBackup, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
      Write-Output "BUILD-WARN: failed to restore build-profile.json5: $($_.Exception.Message)"
    }
  }
  Remove-Item $lockDir -Recurse -Force -ErrorAction SilentlyContinue
}
exit $exitCode
