# tools/logic-tests/run.ps1
#
# 纯逻辑回归入口：先 prepare.ps1 生成 build/*.ts，再用 DevEco 自带 Node 24
# （原生 TS 类型擦除）逐个运行 tools/logic-tests/cases/*.test.mjs。
#
# - 用例只用 Node 内置模块（node:assert / node:fs 等），无第三方依赖、可离线。
# - 每个用例文件通过 cases/_harness.mjs 输出 PASS/FAIL/SKIP 行与一行
#   `SUMMARY passed=N failed=M skipped=K`；本脚本据此汇总。
# - 退出码：0 = 全通过；1 = 有用例失败 / 用例文件加载失败；2 = 等锁超时；3 = 环境缺失。
#
# 并发保护：prepare.ps1 会先清空并重写 build/，两个 run.ps1 同时跑会互相删文件
# （表现为随机 skip 或 "Could not find a part of the path"）。这里用与
# tools/build.ps1 相同的目录抢占锁，把「prepare + 全部用例」串行化。
#
# 用法：
#   pwsh tools/logic-tests/run.ps1
#   pwsh tools/logic-tests/run.ps1 -Filter sse
#   pwsh tools/logic-tests/run.ps1 -SkipPrepare
#   pwsh tools/logic-tests/run.ps1 -LockTimeoutSec 1200
param(
  [string]$Filter = '',
  [switch]$SkipPrepare,
  [switch]$NoColor,
  [int]$LockTimeoutSec = 900
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $here)
$build = Join-Path $here 'build'
$caseDir = Join-Path $here 'cases'
$node = 'C:\Application\DevEco Studio\tools\node\node.exe'

try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

# ---- 0) 跨进程互斥锁（与 tools/build.ps1 同思路）--------------------------
$lockDir = Join-Path $here '.run.lock'
$lockOwner = Join-Path $lockDir 'owner.txt'
$deadline = (Get-Date).AddSeconds($LockTimeoutSec)
$acquired = $false
while (-not $acquired) {
  try {
    New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
    $ownerText = "agent={0} pid={1} at={2}" -f $env:DSH_AGENT_NAME, $PID, (Get-Date).ToString('s')
    Set-Content -Path $lockOwner -Value $ownerText -ErrorAction SilentlyContinue
    $acquired = $true
  } catch {
    # 回收僵死/超时的锁（与 build.ps1 一致：20 分钟视为陈旧）
    if (Test-Path $lockOwner) {
      $age = (Get-Date) - (Get-Item $lockOwner).LastWriteTime
      if ($age.TotalMinutes -gt 20) {
        Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
        continue
      }
    }
    if ((Get-Date) -gt $deadline) {
      Write-Output "TEST-ERROR: 等待逻辑测试锁超时（另一个 run.ps1 正在执行；锁：$lockDir，持有者：$(Get-Content $lockOwner -ErrorAction SilentlyContinue)）"
      exit 2
    }
    Start-Sleep -Seconds 2
  }
}

try {
  Write-Output '========================================================'
  Write-Output ' ChatAnyWhere 纯逻辑回归（Node 类型擦除，无三方依赖）'
  Write-Output '========================================================'

  if (-not (Test-Path -LiteralPath $node)) {
    Write-Output "TEST-ERROR: 未找到 DevEco 自带 Node：$node"
    exit 3
  }

  # ---- 1) prepare ---------------------------------------------------------
  if (-not $SkipPrepare) {
    Write-Output '--- [1/2] prepare（复制纯逻辑 .ets -> build/*.ts）---'
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
    $prepOut = & $pwshExe -NoProfile -File (Join-Path $here 'prepare.ps1') 2>&1
    $prepCode = $LASTEXITCODE
    foreach ($line in @($prepOut)) { Write-Output ([string]$line) }
    if ($prepCode -ne 0) {
      Write-Output "TEST-ERROR: prepare.ps1 失败（exit=$prepCode）"
      exit $prepCode
    }
  }

  # prepare 统计（用于报告里的「跳过」）
  $prepared = $null
  $reportPath = Join-Path $build '_prepare-report.json'
  if (Test-Path -LiteralPath $reportPath) {
    try { $prepared = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }

  # ---- 2) 发现用例 --------------------------------------------------------
  if (-not (Test-Path -LiteralPath $caseDir)) {
    Write-Output "TEST-ERROR: 用例目录不存在：$caseDir"
    exit 1
  }
  $cases = @(Get-ChildItem -LiteralPath $caseDir -File -Filter '*.test.mjs' |
    Where-Object { (-not $Filter) -or ($_.Name -like ('*' + $Filter + '*')) } |
    Sort-Object Name)
  if ($cases.Count -eq 0) {
    Write-Output 'TEST-ERROR: 未发现任何 *.test.mjs 用例文件'
    exit 1
  }

  Write-Output ''
  Write-Output '--- [2/2] 运行用例 ---'

  $totalPass = 0
  $totalFail = 0
  $totalSkip = 0
  $fileRows = New-Object System.Collections.ArrayList
  $summaryRe = '^SUMMARY\s+passed=(\d+)\s+failed=(\d+)\s+skipped=(\d+)'

  foreach ($case in $cases) {
    $name = $case.Name
    Write-Output ''
    Write-Output ("===== " + $name + " =====")
    $raw = & $node $case.FullName 2>&1
    $code = $LASTEXITCODE
    $lines = @($raw | ForEach-Object { [string]$_ })
    foreach ($l in $lines) { Write-Output $l }

    $summary = $null
    foreach ($l in $lines) {
      if ($l -match $summaryRe) {
        $summary = @{ pass = [int]$Matches[1]; fail = [int]$Matches[2]; skip = [int]$Matches[3] }
      }
    }
    if ($null -eq $summary) {
      [void]$fileRows.Add([pscustomobject]@{ file = $name; status = 'ERROR'; pass = 0; fail = 1; skip = 0; code = $code })
      $totalFail++
      Write-Output ("  [文件级失败] 未输出 SUMMARY（node exit=$code）：用例文件可能在 import 阶段就抛错")
    } else {
      $status = if ($summary.fail -gt 0) { 'FAIL' } else { 'PASS' }
      [void]$fileRows.Add([pscustomobject]@{ file = $name; status = $status; pass = $summary.pass; fail = $summary.fail; skip = $summary.skip; code = $code })
      $totalPass += $summary.pass
      $totalFail += $summary.fail
      $totalSkip += $summary.skip
    }
  }

  # ---- 3) 汇总 ------------------------------------------------------------
  $prepCopied = 0; $prepSkipped = 0; $prepMissing = 0
  if ($null -ne $prepared) {
    $prepCopied = [int]$prepared.stats.copied
    $prepSkipped = [int]$prepared.stats.skipped
    $prepMissing = [int]$prepared.stats.missing
  }
  $nodeVersion = (& $node --version 2>&1 | Select-Object -First 1)

  Write-Output ''
  Write-Output '========================================================'
  Write-Output ' 逻辑测试汇总'
  Write-Output '========================================================'
  Write-Output ("Node                : $nodeVersion（$node）")
  Write-Output ("prepare 产物        : build/ 拷贝 $prepCopied 个纯逻辑文件；跳过 $prepSkipped 个（平台绑定/不可擦除语法）；清单未命中 $prepMissing 项")
  Write-Output ("用例文件            : {0} 个（PASS {1} / FAIL {2}）" -f $cases.Count,
    (@($fileRows | Where-Object { $_.status -eq 'PASS' }).Count),
    (@($fileRows | Where-Object { $_.status -ne 'PASS' }).Count))
  Write-Output ("用例（assert 级）   : {0} 通过 / {1} 失败 / {2} 跳过" -f $totalPass, $totalFail, $totalSkip)
  Write-Output ("执行时间            : " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
  Write-Output '--------------------------------------------------------'
  foreach ($row in $fileRows) {
    Write-Output ("  [{0,-5}] {1}  (pass={2} fail={3} skip={4})" -f $row.status, $row.file, $row.pass, $row.fail, $row.skip)
  }
  Write-Output '--------------------------------------------------------'

  if ($totalFail -gt 0) {
    Write-Output ("RESULT: FAIL —— 共 {0} 条用例失败（含文件级失败）" -f $totalFail)
    exit 1
  }
  Write-Output 'RESULT: PASS —— 全部逻辑用例通过'
  exit 0
} finally {
  Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
}
