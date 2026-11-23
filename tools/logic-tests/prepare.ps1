# tools/logic-tests/prepare.ps1
#
# 把「纯逻辑」ArkTS(.ets) 源码复制为 (.ts) 到 tools/logic-tests/build/，供 DevEco 自带
# Node 24（原生 TS 类型擦除）直接运行。
#
# 为什么要复制而不是原地跑：
#   1) .ets 不是 Node 认识的扩展名；.ets 相对 import 不带扩展名，ESM 必须显式扩展名；
#   2) Node 的类型擦除**只删类型语法，不做类型推导**：`import { SomeInterface }` 会在
#      运行时变成真实导入 → "does not provide an export named ..."（已实测）。
#      所以本脚本按全仓 export 表把命名 import 拆成 `import type {...}` 与值导入。
#   3) `@app/*` 是鸿蒙 oh-package 别名，Node 不认 → 生成 build/_shims/<pkg>.ts 转发。
#
# 安全边界（只读被测源码，绝不修改 packages/*、chat/*）：
#   - 只拷贝下面显式清单命中的文件，以及它们「纯逻辑」相对/@app 依赖的传递闭包；
#   - 任何 import @kit.* / @ohos.* / @hms.* 的文件一律不拷贝（平台绑定，靠编译期检查）；
#   - ArkUI 装饰器文件、含 enum/namespace/declare 的文件（Node 擦除不支持代码生成）跳过；
#   - 跳过清单与原因写入 build/_prepare-report.json，run.ps1 汇总为「跳过」统计。
#
# 用法：pwsh tools/logic-tests/prepare.ps1
param(
  [switch]$NoClean
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $here)
$build = Join-Path $here 'build'
$shimDir = Join-Path $build '_shims'

if (-not $build.StartsWith($here, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "内部错误：build 目录不在 tools/logic-tests 下：$build"
}
if ((Test-Path -LiteralPath $build) -and -not $NoClean) {
  # 文件句柄可能被并发进程短暂占用（杀软/编辑器/上一轮 node），退避重试。
  for ($attempt = 0; $attempt -lt 10; $attempt++) {
    if (-not (Test-Path -LiteralPath $build)) { break }
    try {
      Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction Stop
      break
    } catch {
      Start-Sleep -Milliseconds (150 + $attempt * 100)
    }
  }
  if (Test-Path -LiteralPath $build) {
    Get-ChildItem -LiteralPath $build -Force -ErrorAction SilentlyContinue | ForEach-Object {
      try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { }
    }
  }
}
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------------------
# 显式清单：只有这里列出的「纯逻辑」文件及其纯逻辑传递依赖会被拷贝。
# Dir 相对仓库根；Filter 支持 * ；Recurse 递归子目录。
# 平台绑定目录（runners/impl 等）也列出来，是为了在报告里显式记录「跳过 + 原因」。
# ---------------------------------------------------------------------------
$manifest = @(
  # core_model：纯数据/纯函数
  @{ Dir = 'packages/core_model/src/main/ets/util'; Filter = '*.ets'; Recurse = $false },
  @{ Dir = 'packages/core_model/src/main/ets/interfaces'; Filter = 'ModelTypes.ets'; Recurse = $false },
  # core_protocol：SSE 解析、事件解析、模型目录（RcpStreamClient 平台绑定，不列）
  @{ Dir = 'packages/core_protocol/src/main/ets'; Filter = 'SseParser.ets'; Recurse = $false },
  @{ Dir = 'packages/core_protocol/src/main/ets'; Filter = 'ModelCatalog.ets'; Recurse = $false },
  @{ Dir = 'packages/core_protocol/src/main/ets/adapters'; Filter = '*.ets'; Recurse = $false },
  @{ Dir = 'packages/core_protocol/src/main/ets/interfaces'; Filter = '*.ets'; Recurse = $false },
  # 纯工具（ErrorText 错误中文化 / TitleUtil 标题兜底 / UrlUtil / JsonLite）
  @{ Dir = 'packages/core_protocol/src/main/ets/util'; Filter = '*.ets'; Recurse = $false },
  # core_context：纯逻辑（零平台依赖是硬要求）
  @{ Dir = 'packages/core_context/src/main/ets'; Filter = '*.ets'; Recurse = $false },
  @{ Dir = 'packages/core_context/src/main/ets/interfaces'; Filter = '*.ets'; Recurse = $false },
  # core_plugin：Schema 校验 / Diff / 查询组装与清洗（HTTP/MCP 执行器不列）
  @{ Dir = 'packages/core_plugin/src/main/ets'; Filter = 'SkillSchema.ets'; Recurse = $false },
  @{ Dir = 'packages/core_plugin/src/main/ets'; Filter = 'SkillDiff.ets'; Recurse = $false },
  @{ Dir = 'packages/core_plugin/src/main/ets'; Filter = 'WebCleaner.ets'; Recurse = $false },
  @{ Dir = 'packages/core_plugin/src/main/ets'; Filter = 'BuiltinSkills.ets'; Recurse = $false },
  # v3：SKILL.md ↔ SkillManifest 编解码（纯逻辑）
  @{ Dir = 'packages/core_plugin/src/main/ets'; Filter = 'SkillMarkdown.ets'; Recurse = $false },
  @{ Dir = 'packages/core_plugin/src/main/ets/interfaces'; Filter = '*.ets'; Recurse = $false },
  # 纯函数工具（WebClean 查询组装/阈值清洗、DomainUtil、L1Template、McpProtocol、JsonLite）
  @{ Dir = 'packages/core_plugin/src/main/ets/util'; Filter = '*.ets'; Recurse = $false },
  # 平台绑定的执行器目录：显式列出以在报告里记录「跳过 + 原因」
  @{ Dir = 'packages/core_plugin/src/main/ets/runners'; Filter = '*.ets'; Recurse = $false },
  # chat（UI 层）里的纯逻辑：Markdown 块级分块（MarkdownBlock.ets 导出 splitBlocks/parseInline）
  @{ Dir = 'chat/src/main/ets'; Filter = '*Markdown*.ets'; Recurse = $true },
  @{ Dir = 'chat/src/main/ets'; Filter = '*Chunk*.ets'; Recurse = $true },
  # v3.7：代码高亮（零依赖纯函数）与行内公式 LaTeX→文本映射（纯逻辑）
  @{ Dir = 'chat/src/main/ets/components'; Filter = 'CodeHighlighter.ets'; Recurse = $false },
  @{ Dir = 'chat/src/main/ets/components'; Filter = 'InlineMath.ets'; Recurse = $false },
  # v3：6 档思考的纯逻辑（只 import @app/core_protocol 的类型 ThinkingLevel，会被擦除为 import type）
  @{ Dir = 'chat/src/main/ets/app'; Filter = 'EffortLevels.ets'; Recurse = $false }
)

# 用于 import 类型/值分类与「@app 值导出」溯源的全量源码
$sourceRoots = @(
  (Join-Path $repo 'packages'),
  (Join-Path $repo 'chat\src\main\ets')
)

$script:records = New-Object System.Collections.ArrayList
$script:copied = @{}
$script:skipped = @{}
$script:referencedPkgs = New-Object System.Collections.Generic.HashSet[string]
$script:stubs = @{}
$script:warnings = New-Object System.Collections.Generic.HashSet[string]
$script:missing = New-Object System.Collections.ArrayList

function Read-Text([string]$path) {
  return [System.IO.File]::ReadAllText($path, $utf8)
}
function Write-Text([string]$path, [string]$text) {
  $dir = [System.IO.Path]::GetDirectoryName($path)
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  [System.IO.File]::WriteAllText($path, $text, $utf8)
}
function To-Slash([string]$p) { return $p.Replace('\', '/') }
function Rel-Repo([string]$full) { return (To-Slash ([System.IO.Path]::GetRelativePath($repo, $full))) }
function Rel-Spec([string]$fromFile, [string]$toFile) {
  $fromDir = [System.IO.Path]::GetDirectoryName($fromFile)
  $rel = To-Slash ([System.IO.Path]::GetRelativePath($fromDir, $toFile))
  if (-not $rel.StartsWith('.')) { $rel = './' + $rel }
  return $rel
}
function Resolve-ImportTarget([string]$fromFile, [string]$spec) {
  if (-not $spec.StartsWith('.')) { return $null }
  $fromDir = [System.IO.Path]::GetDirectoryName($fromFile)
  $base = [System.IO.Path]::GetFullPath((Join-Path $fromDir $spec))
  $cands = @()
  if ($spec -match '\.(ets|ts|js|json)$') { $cands += $base } else { $cands += ($base + '.ets'); $cands += $base }
  foreach ($c in $cands) {
    if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
  }
  return $null
}
function Get-ImpureReason([string]$text) {
  if ($text -match "from\s*[`"']@(kit|ohos|hms)\.") { return 'platform-kit-import' }
  if ($text -match '(?m)^\s*@(Entry|Component|Observed|ObjectLink|Builder|Styles|Extend|State|Prop|Link|Provide|Consume|Watch)\b') { return 'arkui-decorator' }
  if ($text -match '(?m)^\s*(export\s+)?(declare\s+)?(enum|namespace)\s+[A-Za-z_$]') { return 'unsupported-ts-syntax(enum/namespace)' }
  return ''
}
function Add-Skip([string]$srcFull, [string]$reason) {
  if ($script:skipped.ContainsKey($srcFull)) { return }
  $script:skipped[$srcFull] = $reason
  [void]$script:records.Add([pscustomobject]@{ status = 'skipped'; source = (Rel-Repo $srcFull); reason = $reason })
}
# import 名单解析（闭包扩散、shim 缺口、改写三处共用，必须先定义）
function Get-NamePieces([string]$inner) {
  $out = @()
  if (-not $inner) { return $out }
  $clean = [regex]::Replace($inner, '(?m)//.*$', '')
  $clean = [regex]::Replace($clean, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  foreach ($piece in ($clean -split ',')) {
    $p = $piece.Trim()
    if (-not $p) { continue }
    $p = $p -replace '^type\s+', ''
    if (-not $p) { continue }
    $out += $p
  }
  return $out
}
function Get-ExportedName([string]$piece) {
  return ((($piece -split '\s+as\s+')[0]).Trim())
}
function Test-IsTypeName([string]$name) {
  if ($script:valueKinds.ContainsKey($name)) { return $false }
  return $script:typeNames.Contains($name)
}
function Convert-Spec([string]$destFile, [string]$spec) {
  if ($spec.StartsWith('@app/')) {
    $pkg = $spec.Substring(5)
    $shimFile = Join-Path $shimDir ($pkg + '.ts')
    return (Rel-Spec $destFile $shimFile)
  }
  if (-not $spec.StartsWith('.')) { return $spec }
  if ($spec -match '\.(ets|ts|js|json)$') { return $spec }
  return ($spec + '.ts')
}

# ---------------------------------------------------------------------------
# 1) 扫全仓 export 表：判定一个名字是「类型」还是「运行时值」。
#    判定规则：既在 type 表又在 value 表 → 按值处理（interface+const 合并声明）。
# ---------------------------------------------------------------------------
$script:typeNames = New-Object System.Collections.Generic.HashSet[string]
$script:valueKinds = @{}
$script:valueOwner = @{}
$allSources = @()
foreach ($r in $sourceRoots) {
  if (Test-Path -LiteralPath $r) {
    $allSources += @(Get-ChildItem -LiteralPath $r -Recurse -File -Filter '*.ets' -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '\\(oh_modules|build|node_modules)\\' })
  }
}
foreach ($f in $allSources) {
  $t = Read-Text $f.FullName
  foreach ($m in [regex]::Matches($t, '(?m)\bexport\s+(?:declare\s+)?(?:interface|type)\s+([A-Za-z_$][A-Za-z0-9_$]*)')) {
    [void]$script:typeNames.Add($m.Groups[1].Value)
  }
}
foreach ($f in $allSources) {
  $t = Read-Text $f.FullName
  foreach ($m in [regex]::Matches($t, '(?m)^\s*export\s+(?:abstract\s+)?(class|async\s+function|function|const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)')) {
    $kind = ($m.Groups[1].Value -replace '\s+', ' ')
    $name = $m.Groups[2].Value
    if (-not $script:valueKinds.ContainsKey($name)) {
      $script:valueKinds[$name] = $kind
      $script:valueOwner[$name] = $f.FullName
    }
  }
}
# 再补一层 export { ... } 再导出名（barrel 文件）
foreach ($f in $allSources) {
  $t = Read-Text $f.FullName
  foreach ($m in [regex]::Matches($t, "(?m)^\s*export\s*\{([^}]*)\}")) {
    foreach ($piece in ($m.Groups[1].Value -split ',')) {
      $n = (($piece.Trim()) -replace '^type\s+', '') -replace '\s+as\s+.*$', ''
      if ($n -match '^[A-Za-z_$][A-Za-z0-9_$]*$' -and -not $script:typeNames.Contains($n) -and -not $script:valueKinds.ContainsKey($n)) {
        $script:valueKinds[$n] = 're-export'
        $script:valueOwner[$n] = $f.FullName
      }
    }
  }
}

# ---------------------------------------------------------------------------
# 2) 拷贝显式清单命中文件（纯逻辑校验在此发生）
# ---------------------------------------------------------------------------
function Copy-Pure([string]$srcFull) {
  if ($script:copied.ContainsKey($srcFull)) { return $true }
  if (-not (Test-Path -LiteralPath $srcFull -PathType Leaf)) { return $false }
  if ($srcFull -match '\.d\.ets$') { Add-Skip $srcFull 'declaration-file'; return $false }
  $text = Read-Text $srcFull
  $reason = Get-ImpureReason $text
  if ($reason) { Add-Skip $srcFull $reason; return $false }
  $rel = [System.IO.Path]::GetRelativePath($repo, $srcFull)
  $dest = Join-Path $build ($rel -replace '\.ets$', '.ts')
  Write-Text $dest $text
  $script:copied[$srcFull] = $dest
  [void]$script:records.Add([pscustomobject]@{ status = 'copied'; source = (To-Slash $rel); output = (Rel-Repo $dest) })
  return $true
}

foreach ($entry in $manifest) {
  $dir = Join-Path $repo ($entry.Dir -replace '/', '\')
  $label = $entry.Dir + '/' + $entry.Filter
  if (-not (Test-Path -LiteralPath $dir)) { [void]$script:missing.Add($label); continue }
  $files = @()
  if ($entry.Recurse) {
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter $entry.Filter -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '\\(oh_modules|build|node_modules)\\' })
  } else {
    $files = @(Get-ChildItem -LiteralPath $dir -File -Filter $entry.Filter -ErrorAction SilentlyContinue)
  }
  if ($files.Count -eq 0) { [void]$script:missing.Add($label); continue }
  foreach ($f in $files) { [void](Copy-Pure $f.FullName) }
}

# ---------------------------------------------------------------------------
# 3) 向纯逻辑依赖闭包扩散：相对 import + @app 值导出溯源
# ---------------------------------------------------------------------------
$round = 0
do {
  $changed = $false
  $round++
  foreach ($src in @($script:copied.Keys)) {
    $text = Read-Text $src
    foreach ($m in [regex]::Matches($text, "(?:from|import)\s*[`"'](\.[^`"']+)[`"']")) {
      $target = Resolve-ImportTarget $src $m.Groups[1].Value
      if ($target -and -not $script:copied.ContainsKey($target)) {
        $before = $script:copied.Count
        [void](Copy-Pure $target)
        if ($script:copied.Count -ne $before) { $changed = $true }
      }
    }
    foreach ($m in [regex]::Matches($text, "import\s*(?:type\s*)?\{([^}]*)\}\s*from\s*[`"']@app/([A-Za-z0-9_]+)[`"']")) {
      $pkg = $m.Groups[2].Value
      [void]$script:referencedPkgs.Add($pkg)
      foreach ($piece in (Get-NamePieces $m.Groups[1].Value)) {
        $name = Get-ExportedName $piece
        # 注释里的示例 import（如 `import { SkillManifest, ... }`）可能被正则误抓：只接受合法标识符
        if ($name -notmatch '^[A-Za-z_$][A-Za-z0-9_$]*$') { continue }
        if ($script:typeNames.Contains($name) -and -not $script:valueKinds.ContainsKey($name)) { continue }
        if ($script:valueOwner.ContainsKey($name)) {
          $owner = $script:valueOwner[$name]
          if (-not $script:copied.ContainsKey($owner) -and -not $script:skipped.ContainsKey($owner)) {
            $before = $script:copied.Count
            [void](Copy-Pure $owner)
            if ($script:copied.Count -ne $before) { $changed = $true }
          }
        }
      }
    }
  }
} while ($changed -and $round -lt 25)

# ---------------------------------------------------------------------------
# 4) 传递性剪枝：依赖了「平台文件/缺失文件」的文件不能进 Node 测试
# ---------------------------------------------------------------------------
$guard = 0
do {
  $pruned = $false
  $guard++
  $toRemove = @()
  foreach ($src in @($script:copied.Keys)) {
    $text = Read-Text $src
    $bad = $false
    foreach ($m in [regex]::Matches($text, "(?:from|import)\s*[`"'](\.[^`"']+)[`"']")) {
      $target = Resolve-ImportTarget $src $m.Groups[1].Value
      if (-not $target) { continue }
      if ($script:skipped.ContainsKey($target) -or -not $script:copied.ContainsKey($target)) { $bad = $true; break }
    }
    if ($bad) { $toRemove += $src }
  }
  foreach ($src in $toRemove) {
    [void]$script:copied.Remove($src)
    Add-Skip $src 'transitive-platform-or-missing-dependency'
    $pruned = $true
  }
} while ($pruned -and $guard -lt 10)

# ---------------------------------------------------------------------------
# 5) 收集 @app 值导出缺口 → 生成「调用即抛错」的同名 shim（导入期不炸，失败点精确）
# ---------------------------------------------------------------------------
foreach ($src in @($script:copied.Keys)) {
  $text = Read-Text $src
  foreach ($m in [regex]::Matches($text, "import\s*(?:type\s*)?\{([^}]*)\}\s*from\s*[`"']@app/([A-Za-z0-9_]+)[`"']")) {
    $pkg = $m.Groups[2].Value
    foreach ($piece in (Get-NamePieces $m.Groups[1].Value)) {
      $name = Get-ExportedName $piece
      # 同上：排除注释示例里的非标识符 token（例如 `...`）
      if ($name -notmatch '^[A-Za-z_$][A-Za-z0-9_$]*$') { continue }
      if ($script:typeNames.Contains($name) -and -not $script:valueKinds.ContainsKey($name)) { continue }
      if (-not $script:stubs.ContainsKey($pkg)) { $script:stubs[$pkg] = @{} }
      if ($script:valueOwner.ContainsKey($name)) {
        if ($script:copied.ContainsKey($script:valueOwner[$name])) { continue }
        $script:stubs[$pkg][$name] = $script:valueKinds[$name]
        [void]$script:warnings.Add("@app/$pkg 的值导出 $name 依赖平台文件或尚未实现：已生成同名抛错 shim（被调用时会失败）")
      } else {
        $script:stubs[$pkg][$name] = 'function'
        [void]$script:warnings.Add("@app/$pkg 的导出 $name 在全仓源码中未找到：已按值导出生成抛错 shim")
      }
    }
  }
}

# ---------------------------------------------------------------------------
# 6) 生成 build/_shims/<pkg>.ts（@app/* 别名 → 本地产物转发）
# ---------------------------------------------------------------------------
$script:copiedByPkg = @{}
foreach ($src in @($script:copied.Keys)) {
  $rel = To-Slash ([System.IO.Path]::GetRelativePath($repo, $src))
  if ($rel -match '^packages/([^/]+)/') { $pkg = $Matches[1] }
  elseif ($rel -match '^chat/') { $pkg = 'chat' }
  else { $pkg = 'misc' }
  if (-not $script:copiedByPkg.ContainsKey($pkg)) { $script:copiedByPkg[$pkg] = @() }
  $script:copiedByPkg[$pkg] += $src
}
$allPkgs = @(@($script:copiedByPkg.Keys) + @($script:referencedPkgs)) | Sort-Object -Unique
foreach ($pkg in $allPkgs) {
  $shimPath = Join-Path $shimDir ($pkg + '.ts')
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add('// 由 tools/logic-tests/prepare.ps1 自动生成，勿手改（每次运行覆盖）。')
  if ($script:copiedByPkg.ContainsKey($pkg)) {
    foreach ($src in ($script:copiedByPkg[$pkg] | Sort-Object)) {
      [void]$lines.Add("export * from '" + (Rel-Spec $shimPath $script:copied[$src]) + "';")
    }
  }
  if ($script:stubs.ContainsKey($pkg)) {
    foreach ($name in ($script:stubs[$pkg].Keys | Sort-Object)) {
      $kind = $script:stubs[$pkg][$name]
      $msg = "logic-test shim: @app/$pkg 的 $name 未能从纯逻辑源码提供（平台依赖或未实现），本次 Node 测试不可用"
      if ($kind -eq 'class') {
        [void]$lines.Add("export class $name { constructor() { throw new Error('$msg'); } }")
      } elseif ($kind -eq 'const' -or $kind -eq 'let' -or $kind -eq 'var') {
        [void]$lines.Add("export const $name = undefined;")
      } else {
        [void]$lines.Add("export function $name() { throw new Error('$msg'); }")
      }
    }
  }
  Write-Text $shimPath ($lines -join "`n")
}

# ---------------------------------------------------------------------------
# 7) import 改写：类型/值拆分 + @app 别名替换 + 相对 import 补 .ts
# ---------------------------------------------------------------------------
foreach ($src in @($script:copied.Keys)) {
  $dest = $script:copied[$src]
  $text = Read-Text $dest

  # 7.1 `export { A } from '...'` → 类型走 export type（Node 擦除），值保留
  $text = [regex]::Replace($text, "(?m)^([ \t]*)export\s*\{([^}]*)\}\s*from\s*[`"']([^`"']+)[`"']\s*;?", {
      param($m)
      $indent = $m.Groups[1].Value
      $pieces = @(Get-NamePieces $m.Groups[2].Value)
      if ($pieces.Count -eq 0) { return $m.Value }
      $spec = Convert-Spec $dest $m.Groups[3].Value
      $typePieces = @(); $valuePieces = @()
      foreach ($p in $pieces) {
        if (Test-IsTypeName (Get-ExportedName $p)) { $typePieces += $p } else { $valuePieces += $p }
      }
      $out = @()
      if ($valuePieces.Count -gt 0) {
        $out += ($indent + 'export { ' + ($valuePieces -join ', ') + " } from '" + $spec + "';")
      }
      if ($typePieces.Count -gt 0) {
        $out += ($indent + 'export type { ' + ($typePieces -join ', ') + " } from '" + $spec + "';")
      }
      return ($out -join "`n")
    })

  # 7.2 `import { A, fn } from '...'` → 拆成 import type + import（保住别名 X as Y）
  $text = [regex]::Replace($text, "(?m)^([ \t]*)import\s*\{([^}]*)\}\s*from\s*[`"']([^`"']+)[`"']\s*;?", {
      param($m)
      $indent = $m.Groups[1].Value
      $pieces = @(Get-NamePieces $m.Groups[2].Value)
      if ($pieces.Count -eq 0) { return $m.Value }
      $spec = Convert-Spec $dest $m.Groups[3].Value
      $typePieces = @(); $valuePieces = @()
      foreach ($p in $pieces) {
        if (Test-IsTypeName (Get-ExportedName $p)) { $typePieces += $p } else { $valuePieces += $p }
      }
      $out = @()
      if ($valuePieces.Count -gt 0) {
        $out += ($indent + 'import { ' + ($valuePieces -join ', ') + " } from '" + $spec + "';")
      }
      if ($typePieces.Count -gt 0) {
        $out += ($indent + 'import type { ' + ($typePieces -join ', ') + " } from '" + $spec + "';")
      }
      return ($out -join "`n")
    })

  # 7.3 其余 `from './x'`（import type / default / export type）补 .ts 后缀
  $text = [regex]::Replace($text, "((?:from|import)\s*[`"'])(\.[^`"']+)([`"'])", {
      param($m)
      $spec = $m.Groups[2].Value
      if ($spec -match '\.(ets|ts|js|json)$') { return $m.Value }
      return ($m.Groups[1].Value + $spec + '.ts' + $m.Groups[3].Value)
    })

  Write-Text $dest $text
}

# ---------------------------------------------------------------------------
# 8) 报告
# ---------------------------------------------------------------------------
$report = [pscustomobject]@{
  generatedAt = (Get-Date).ToString('s')
  repoRoot    = (To-Slash $repo)
  stats       = [pscustomobject]@{
    copied   = $script:copied.Count
    skipped  = $script:skipped.Count
    missing  = $script:missing.Count
    warnings = $script:warnings.Count
  }
  copied      = @($script:records | Where-Object { $_.status -eq 'copied' })
  skipped     = @($script:records | Where-Object { $_.status -eq 'skipped' })
  missing     = @($script:missing)
  warnings    = @($script:warnings)
}
Write-Text (Join-Path $build '_prepare-report.json') ($report | ConvertTo-Json -Depth 6)

Write-Output '=== prepare.ps1 ==='
Write-Output ('拷贝纯逻辑文件 : {0}' -f $script:copied.Count)
Write-Output ('跳过（含平台绑定）: {0}' -f $script:skipped.Count)
Write-Output ('清单未命中（模块未实现）: {0}' -f $script:missing.Count)
Write-Output ('警告 : {0}' -f $script:warnings.Count)
if ($script:missing.Count -gt 0) {
  Write-Output '--- 未命中清单（随模块落地会自然消失）---'
  foreach ($m in $script:missing) { Write-Output ('  · ' + $m) }
}
if ($script:warnings.Count -gt 0) {
  Write-Output '--- 警告 ---'
  foreach ($w in $script:warnings) { Write-Output ('  ! ' + $w) }
}
Write-Output ('产物目录 : ' + (To-Slash $build))
exit 0
