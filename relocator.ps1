<#
.SYNOPSIS
    win-cache-relocator —— 把 C 盘上会持续增长的缓存搬到其他盘。

.DESCRIPTION
    清理只能把问题推迟两周。本工具把目录搬走、原路径留重定向点，
    程序仍访问原路径，字节落在别的盘，新数据也不再回 C 盘。

    重定向有三种机制，按可靠性排序：
      1. 应用自己的设置
      2. 环境变量
      3. NTFS 目录联接（通用兜底，个别应用会拒绝）

    搬移是一个显式状态机，每一步都落盘：
      pending -> copying -> verified -> renamed -> linked -> done
    任何一步失败，下次运行会告诉你停在哪、原始数据在哪、怎么继续。

.PARAMETER Command
    scan / locks / move / resume / undo / repair / doctor / env / undo-env / list / help

.EXAMPLE
    .\relocator.ps1 scan
.EXAMPLE
    .\relocator.ps1 move -Name codex -Target D:\Moved -DryRun
.EXAMPLE
    .\relocator.ps1 resume
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Name = '',
    [string]$Source = '',
    [string]$Target = '',
    [string]$Subdir = '',
    [string]$StateDir = '',
    [switch]$All,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Hash,
    [switch]$Json,
    [switch]$AllSafe,
    [switch]$AllowSameVolume,
    [switch]$AllowUnknown,
    [ValidateSet('auto', 'junction', 'env', 'move-only')][string]$Mode = 'auto'
)

$ErrorActionPreference = 'Stop'
$script:Version = '1.2.0'
$script:StateRoot = if ($StateDir) { $StateDir } else { Join-Path $env:LOCALAPPDATA 'WinCacheRelocator' }
$script:LedgerPath = Join-Path $script:StateRoot 'ledger.json'
$script:PendingPath = Join-Path $script:StateRoot 'pending.json'
$script:Failures = 0

function Set-Failure { $script:Failures++ }

# =====================================================================
# 数据表
# =====================================================================

# 系统与安装目录：永远不搬
$script:SystemRoots = @(
    "$env:SystemRoot"
    "$env:ProgramFiles"
    "${env:ProgramFiles(x86)}"
    "$env:ProgramData"
    "$env:LOCALAPPDATA\Packages"
    "$env:LOCALAPPDATA\Microsoft"
    "$env:LOCALAPPDATA\Programs"
    "$env:APPDATA\Microsoft"
)

# 只保护这些容器目录本身，不保护它们下面的子目录 ——
# 否则 %LOCALAPPDATA%\Temp、Google、Python 会被整个连带保护掉
$script:ContainerPaths = @(
    "$env:USERPROFILE"
    "$env:USERPROFILE\AppData"
    "$env:USERPROFILE\AppData\Local"
    "$env:USERPROFILE\AppData\Roaming"
    "$env:USERPROFILE\AppData\LocalLow"
)

# 用户自己产生、丢了找不回来的目录名（按最后一段匹配）
$script:UserDataNames = @(
    'Documents', 'Desktop', 'Downloads', 'Pictures', 'Music', 'Videos',
    'Saved Games', 'Contacts', 'Favorites', 'Links', 'Searches',
    'OneDrive', 'Dropbox', 'Google Drive', 'iCloudDrive', 'OneDrive - Personal',
    '3D Objects', 'Templates', 'Public'
)

# 目录库。Verified：local=本机实测 / doc=官方文档 / guess=约定推断
$script:Catalog = [ordered]@{
    'codex'           = @{ Paths = @('~\.codex'); Processes = @('codex*', 'Codex*'); Class = 'close'; Env = @{}; Note = 'Codex 数据；系统服务会锁住它，需先停服务'; Verified = 'local' }
    'dsh'             = @{ Paths = @('~\.dsh', '%APPDATA%\DSH NEXT'); Class = 'close'; Env = @{ DSH_HOME = '1'; DSH_DESKTOP_NEXT_HOME = '1' }; RefusesJunction = $true; Note = 'DeepSeek Harness；拒绝联接作为数据目录，只能用环境变量重定向'; Verified = 'local' }
    'claude'          = @{ Paths = @('~\.claude'); Class = 'close'; Env = @{ CLAUDE_CONFIG_DIR = '1' }; Note = 'Claude Code 会话记录'; Verified = 'doc' }
    'cursor'          = @{ Paths = @('%APPDATA%\Cursor', '%LOCALAPPDATA%\Cursor'); Class = 'close'; Env = @{}; Note = 'Cursor 数据分布在 Roaming 与 Local 两侧'; Verified = 'guess' }
    'workbuddy'       = @{ Paths = @('~\.workbuddy', '~\WorkBuddy'); Class = 'close'; Env = @{}; Note = 'WorkBuddy；多版本共用变量会互相踩数据，只能用联接'; Verified = 'local' }
    'qoder'           = @{ Paths = @('~\.qoder', '~\.qoder-cn', '~\.qoder-cn', '%APPDATA%\com.qodercn.app.stable'); Class = 'close'; Env = @{}; Note = 'Qoder 数据与缓存'; Verified = 'local' }
    'doubao'          = @{ Paths = @('%LOCALAPPDATA%\Doubao', '%APPDATA%\Doubao'); Class = 'close'; Env = @{}; Note = '豆包'; Verified = 'local' }
    'dingtalk'        = @{ Paths = @('%APPDATA%\DingTalk'); Class = 'close'; Env = @{}; Note = '钉钉'; Verified = 'local' }
    'kingsoft'        = @{ Paths = @('%LOCALAPPDATA%\Kingsoft', '%APPDATA%\kingsoft'); Class = 'close'; Env = @{}; Note = 'WPS 缓存'; Verified = 'local' }
    'tencent'         = @{ Paths = @('%APPDATA%\Tencent', '%APPDATA%\QQEX', '%LOCALAPPDATA%\Tencent'); Class = 'close'; Env = @{}; Note = 'QQ/微信数据；聊天记录丢了找不回来'; Verified = 'local' }
    'openai'          = @{ Paths = @('%LOCALAPPDATA%\OpenAI'); Class = 'close'; Env = @{}; Note = 'OpenAI/ChatGPT 缓存'; Verified = 'local' }
    'agents-anywhere' = @{ Paths = @('%APPDATA%\Agents Anywhere'); Class = 'close'; Env = @{}; Note = 'Agent 平台数据'; Verified = 'local' }
    'electron-capsule'= @{ Paths = @('%APPDATA%\electron-capsule', '%LOCALAPPDATA%\app_shell_cache_2079'); Class = 'close'; Env = @{}; Note = 'Electron 应用外壳缓存'; Verified = 'local' }
    'ollama'          = @{ Paths = @('~\.ollama'); Class = 'close'; Env = @{ OLLAMA_MODELS = '1' }; Note = '本地模型，通常很大'; Verified = 'doc' }
    'hf'              = @{ Paths = @('~\.cache\huggingface'); Class = 'safe'; Env = @{ HF_HOME = '1' }; Note = 'HuggingFace 模型缓存'; Verified = 'doc' }
    'torch'           = @{ Paths = @('~\.cache\torch'); Class = 'safe'; Env = @{ TORCH_HOME = '1' }; Note = 'PyTorch 预训练权重'; Verified = 'doc' }
    'npm-cache'       = @{ Paths = @('%LOCALAPPDATA%\npm-cache', '~\.npm\_cacache'); Class = 'safe'; Env = @{ npm_config_cache = '1' }; Note = 'npm 缓存'; Verified = 'doc' }
    'pip-cache'       = @{ Paths = @('%LOCALAPPDATA%\pip\Cache'); Class = 'safe'; Env = @{ PIP_CACHE_DIR = '1' }; Note = 'pip 缓存'; Verified = 'doc' }
    'uv-cache'        = @{ Paths = @('%LOCALAPPDATA%\uv'); Class = 'safe'; Env = @{ UV_CACHE_DIR = '1' }; Note = 'uv 缓存'; Verified = 'local' }
    'playwright'      = @{ Paths = @('%LOCALAPPDATA%\ms-playwright'); Class = 'safe'; Env = @{ PLAYWRIGHT_BROWSERS_PATH = '1' }; Note = 'Playwright 浏览器'; Verified = 'doc' }
    'nuget'           = @{ Paths = @('~\.nuget\packages'); Class = 'safe'; Env = @{ NUGET_PACKAGES = '1' }; Note = '.NET 包缓存'; Verified = 'doc' }
    'gradle'          = @{ Paths = @('~\.gradle'); Class = 'safe'; Env = @{ GRADLE_USER_HOME = '1' }; Note = 'Gradle 缓存'; Verified = 'doc' }
    'cargo'           = @{ Paths = @('~\.cargo'); Class = 'safe'; Env = @{ CARGO_HOME = '1' }; Note = 'Rust 依赖'; Verified = 'local' }
    'rustup'          = @{ Paths = @('~\.rustup'); Class = 'safe'; Env = @{ RUSTUP_HOME = '1' }; Note = 'Rust 工具链'; Verified = 'local' }
    'temp'            = @{ Paths = @('%LOCALAPPDATA%\Temp'); Class = 'caution'; Env = @{ TEMP = '1'; TMP = '1' }; Note = '临时文件；改环境变量比搬目录合适'; Verified = 'local' }
    'crashdumps'      = @{ Paths = @('%LOCALAPPDATA%\CrashDumps'); Class = 'safe'; Env = @{}; Note = '崩溃转储'; Verified = 'doc' }
}

$script:EnvLayout = [ordered]@{
    'TEMP' = 'Temp'; 'TMP' = 'Temp'
    'PIP_CACHE_DIR' = 'Toolchains\pip-cache'; 'UV_CACHE_DIR' = 'Toolchains\uv-cache'
    'npm_config_cache' = 'Toolchains\npm-cache'; 'YARN_CACHE_FOLDER' = 'Toolchains\yarn'
    'GRADLE_USER_HOME' = 'Toolchains\gradle'; 'NUGET_PACKAGES' = 'Toolchains\nuget'
    'PLAYWRIGHT_BROWSERS_PATH' = 'Toolchains\playwright'; 'HF_HOME' = 'Toolchains\huggingface'
    'TORCH_HOME' = 'Toolchains\torch'; 'CARGO_HOME' = 'Toolchains\cargo'
    'RUSTUP_HOME' = 'Toolchains\rustup'; 'OLLAMA_MODELS' = 'Toolchains\ollama'
    'CLAUDE_CONFIG_DIR' = 'Toolchains\claude'; 'CODEX_HOME' = 'Toolchains\codex'
    'DSH_HOME' = 'Toolchains\dsh'; 'DSH_DESKTOP_NEXT_HOME' = 'Toolchains\dsh'
}

# =====================================================================
# 输出
# =====================================================================

function Write-H { param($t) Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok { param($t) Write-Host "  OK   $t" -ForegroundColor Green }
function Write-No { param($t) Write-Host "  注意 $t" -ForegroundColor Yellow }
function Write-Bad { param($t) Write-Host "  错误 $t" -ForegroundColor Red }
function Write-Dim { param($t) Write-Host "        $t" -ForegroundColor DarkGray }

function Format-Size {
    param($Bytes)
    $b = [double]$Bytes
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return "$([long]$b) B"
}

function Format-Cell {
    param([string]$Text, [int]$Width)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) { if ([int]$ch -gt 127) { $w += 2 } else { $w += 1 } }
    if ($w -ge $Width) {
        $out = ''; $acc = 0
        foreach ($ch in $Text.ToCharArray()) {
            $cw = if ([int]$ch -gt 127) { 2 } else { 1 }
            if ($acc + $cw -gt $Width - 1) { break }
            $out += $ch; $acc += $cw
        }
        return $out + '…' + (' ' * [Math]::Max(0, $Width - $acc - 1))
    }
    return $Text + (' ' * ($Width - $w))
}

# =====================================================================
# 路径归一化 —— 所有判断都建立在归一化之后的绝对路径上
# =====================================================================

function Resolve-FullPath {
    <#
      统一成绝对路径并去掉尾随分隔符/空格。
      审计发现：'C:\...\AppData\' 带尾随反斜杠时，用 `$` 结尾的正则全部失效。
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim()
    if ($p.StartsWith('~')) { $p = $env:USERPROFILE + $p.Substring(1) }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        $p = Join-Path ([Environment]::CurrentDirectory) $p
    }
    try { $full = [System.IO.Path]::GetFullPath($p) } catch { return $p }
    $full = $full.TrimEnd([char]'\', [char]' ')
    if ($full -match '^[A-Za-z]:$') { $full += '\' }
    return $full
}

function Test-PathUnder {
    param([string]$Child, [string]$Parent)
    $c = Resolve-FullPath $Child
    $p = Resolve-FullPath $Parent
    if (-not $c -or -not $p) { return $false }
    if ($c -ieq $p) { return $true }
    return $c.StartsWith($p.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-PathKind {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $i) { return 'missing' }
    if (-not ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return 'real' }
    $t = $i.Target
    if ($t -is [array]) { $t = if ($t.Count -gt 0) { $t[0] } else { $null } }
    if (-not $t) { return 'link-noshell' }   # 系统兼容链接，没有目标
    if (Test-Path -LiteralPath $t) { return 'link-ok' }
    return 'link-broken'
}

function Test-IsJunction {
    # 只认真正的目录联接；符号链接和卷挂载点不算，避免 undo 误删
    param([string]$Path)
    try {
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
        if ($i.PSObject.Properties['LinkType'] -and $i.LinkType) { return ($i.LinkType -eq 'Junction') }
        # 老版本没有 LinkType，用 fsutil 兜底
        $out = & cmd /c fsutil reparsepoint query "$Path" 2>&1
        return (($out -join ' ') -match 'Mount Point')
    } catch { return $false }
}

function Get-LinkTarget {
    param([string]$Path)
    try {
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }
        $t = $i.Target
        if ($t -is [array]) { $t = if ($t.Count -gt 0) { $t[0] } else { $null } }
        return $t
    } catch { return $null }
}

function Get-VolumeInfo {
    param([string]$Path)
    try {
        $full = Resolve-FullPath $Path
        $root = [System.IO.Path]::GetPathRoot($full)
        if (-not $root) { $root = (Split-Path $full -Qualifier) + '\' }
        $d = New-Object System.IO.DriveInfo $root
        if (-not $d.IsReady) { return $null }
        return @{ Root = $d.RootDirectory.FullName; Format = $d.DriveFormat; Free = $d.AvailableFreeSpace; Total = $d.TotalSize; IsNtfs = ($d.DriveFormat -eq 'NTFS') }
    } catch { return $null }
}

# =====================================================================
# 保护判定
# =====================================================================

function Test-ProtectedPath {
    param([string]$Path)
    $p = Resolve-FullPath $Path
    if (-not $p) { return @{ Protected = $true; Reason = '路径无法解析' } }
    if ($p.StartsWith('\\')) { return @{ Protected = $true; Reason = '网络路径不搬' } }

    foreach ($r in $script:SystemRoots) {
        if (-not $r) { continue }
        $rf = Resolve-FullPath $r
        if (-not $rf) { continue }
        if ($p -ieq $rf) { return @{ Protected = $true; Reason = "系统/安装目录（$rf）" } }
        if ($p.StartsWith($rf.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return @{ Protected = $true; Reason = "位于系统/安装目录内（$rf）" }
        }
    }

    foreach ($special in @('.git', '.ssh', '.gnupg')) {
        if ($p -match ('\\' + [regex]::Escape($special) + '($|\\)')) {
            return @{ Protected = $true; Reason = "包含 $special，不搬" }
        }
    }

    foreach ($c in $script:ContainerPaths) {
        if (-not $c) { continue }
        if ($p -ieq (Resolve-FullPath $c)) { return @{ Protected = $true; Reason = "容器目录本身（$c）" } }
    }

    $segs = $p.Split('\', [System.StringSplitOptions]::RemoveEmptyEntries)
    # C:\Users\x\dir 至少 4 段（C: / Users / x / dir）
    if ($segs.Count -lt 4) { return @{ Protected = $true; Reason = '路径层级太浅（盘根、用户目录或一级目录）' } }

    $leaf = $segs[$segs.Count - 1]
    foreach ($u in $script:UserDataNames) {
        if ($leaf -ieq $u) { return @{ Protected = $true; Reason = "用户数据目录（$u），不搬" } }
    }
    return @{ Protected = $false; Reason = '' }
}

function Get-CatalogEntry {
    param([string]$Path)
    $p = Resolve-FullPath $Path
    foreach ($k in $script:Catalog.Keys) {
        foreach ($tpl in $script:Catalog[$k].Paths) {
            if ($p -ieq (Resolve-FullPath $tpl)) { return @{ Key = $k; Entry = $script:Catalog[$k] } }
        }
    }

    # Electron 类应用的更新器目录：<app>-updater / @<app>-updater，纯缓存，可重新下载
    $leaf = Split-Path $p -Leaf
    if ($leaf -match '-updater$') {
        return @{ Key = 'updater'; Entry = @{ Paths = @(); Class = 'safe'; Env = @{}; Note = 'Electron 更新器缓存（可重新下载）'; Verified = 'doc' } }
    }

    # 通用工具链缓存：pip / npm / uv 等在 Local 下的变体
    if ($leaf -in @('npm-cache', 'ms-playwright', 'CrashDumps')) {
        return @{ Key = $leaf; Entry = @{ Paths = @(); Class = 'safe'; Env = @{}; Note = '工具链缓存'; Verified = 'doc' } }
    }

    return $null
}

# =====================================================================
# 清单与校验
# =====================================================================

function Get-TreeManifest {
    <#
      返回 @{ Files; Bytes; Dirs; MaxWrite; Map; Links; Errors }
      跳过所有重解析点（不跟随），但把它们记进 Links —— /XJ 不会复制它们。
      枚举错误不吞掉，记进 Errors，调用方据此判失败（审计 #21）。
    #>
    param([string]$Path, [switch]$WithHash)

    $map = @{}
    $files = 0; $bytes = [long]0; $dirs = 0
    $maxWrite = [datetime]::MinValue
    $links = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Files = 0; Bytes = 0; Dirs = 0; MaxWrite = [datetime]::MinValue; Map = @{}; Links = $links; Errors = $errors } }
    $stack.Push([System.IO.DirectoryInfo]::new($Path))

    # 用 DirectoryInfo 一次拿到所有元数据，比逐条 GetAttributes 快好几倍
    $rootLen = $Path.Length
    while ($stack.Count -gt 0) {
        $di = $stack.Pop()
        try {
            foreach ($fi in $di.EnumerateFileSystemInfos()) {
                $attrs = $fi.Attributes
                if ($attrs -band [System.IO.FileAttributes]::ReparsePoint) {
                    $links.Add($fi.FullName.Substring($rootLen).TrimStart('\'))
                    continue
                }
                if ($attrs -band [System.IO.FileAttributes]::Directory) {
                    $dirs++
                    $stack.Push($fi)
                    continue
                }
                try {
                    $rel = $fi.FullName.Substring($rootLen).TrimStart('\')
                    $e = @{ Size = [long]$fi.Length; Write = $fi.LastWriteTimeUtc }
                    if ($WithHash) { try { $e.Hash = (Get-FileHash -LiteralPath $fi.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { } }
                    $map[$rel] = $e
                    $files++; $bytes += $fi.Length
                    if ($fi.LastWriteTimeUtc -gt $maxWrite) { $maxWrite = $fi.LastWriteTimeUtc }
                } catch { $errors.Add("$($fi.FullName) : $($_.Exception.Message)") }
            }
        } catch { $errors.Add("$($di.FullName) : $($_.Exception.Message)") }
    }

    return @{ Files = $files; Bytes = $bytes; Dirs = $dirs; MaxWrite = $maxWrite; Map = $map; Links = $links; Errors = $errors }
}

function Compare-Manifest {
    param($Src, $Dst, [switch]$WithHash)
    $missing = New-Object System.Collections.Generic.List[string]
    $differs = New-Object System.Collections.Generic.List[string]
    $extra = New-Object System.Collections.Generic.List[string]

    foreach ($rel in $Src.Map.Keys) {
        if (-not $Dst.Map.ContainsKey($rel)) { $missing.Add($rel); continue }
        $a = $Src.Map[$rel]; $b = $Dst.Map[$rel]
        if ($a.Size -ne $b.Size) { $differs.Add("$rel (源 $($a.Size) / 目标 $($b.Size))"); continue }
        if ($WithHash -and $a.Hash -and $b.Hash -and ($a.Hash -ne $b.Hash)) { $differs.Add("$rel (内容哈希不同)"); continue }
    }
    foreach ($rel in $Dst.Map.Keys) { if (-not $Src.Map.ContainsKey($rel)) { $extra.Add($rel) } }

    return @{
        Same = ($missing.Count -eq 0 -and $differs.Count -eq 0)
        Missing = $missing; Differs = $differs; Extra = $extra
        SrcFiles = $Src.Files; SrcBytes = $Src.Bytes; DstFiles = $Dst.Files; DstBytes = $Dst.Bytes
        SrcDirs = $Src.Dirs; DstDirs = $Dst.Dirs
    }
}

# =====================================================================
# 台账（带互斥与原子写）
# =====================================================================

function Invoke-LedgerLock {
    param([scriptblock]$Body)
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\WinCacheRelocator.Ledger')
        $null = $mutex.WaitOne(10000)
    } catch { $mutex = $null }
    try { & $Body }
    finally {
        if ($mutex) {
            try { $mutex.ReleaseMutex() } catch { }
            $mutex.Dispose()
        }
    }
}

function Read-LedgerRaw {
    if (-not (Test-Path -LiteralPath $script:LedgerPath)) { return '[]' }
    return [System.IO.File]::ReadAllText($script:LedgerPath, [System.Text.Encoding]::UTF8)
}

function ConvertFrom-LedgerJson {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    $parsed = $Raw | ConvertFrom-Json
    $items = @()
    foreach ($one in @($parsed)) {
        if ($null -eq $one) { continue }
        foreach ($inner in @($one)) { if ($null -ne $inner) { $items += $inner } }
    }
    # PS 5.1：'[]' 会解析成没有 Name 属性的空壳，按此过滤
    return @($items | Where-Object { $_ -and $_.PSObject.Properties['Name'] })
}

function Read-Ledger {
    $raw = Read-LedgerRaw
    try { return ConvertFrom-LedgerJson -Raw $raw }
    catch {
        # 审计 #8：解析失败不能当成空台账，否则下次搬移会覆盖掉旧记录
        $bad = "$script:LedgerPath.corrupt-" + (Get-Date).ToString('yyyyMMdd-HHmmss')
        try { Move-Item -LiteralPath $script:LedgerPath -Destination $bad -Force } catch { }
        Write-Bad "台账损坏，已隔离到：$bad"
        Write-Bad '这不影响已经建立的联接，但 undo 记录需要从隔离文件里手工恢复。'
        Set-Failure
        return @()
    }
}

function Write-LedgerAtomic {
    param($Entries)
    if (-not (Test-Path -LiteralPath $script:StateRoot)) { New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null }
    $list = @($Entries | Where-Object { $null -ne $_ })
    $json = if ($list.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $list -Depth 6 }
    $tmp = "$script:LedgerPath.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $script:LedgerPath) {
        try { [System.IO.File]::Replace($tmp, $script:LedgerPath, $null) }
        catch { Move-Item -LiteralPath $tmp -Destination $script:LedgerPath -Force }
    } else {
        Move-Item -LiteralPath $tmp -Destination $script:LedgerPath -Force
    }
}

function Add-LedgerEntry {
    param($Entry)
    Invoke-LedgerLock {
        $entries = @(Read-Ledger) + $Entry
        Write-LedgerAtomic $entries
    }
}

function Remove-LedgerEntry {
    param([string]$Id)
    Invoke-LedgerLock {
        $entries = @(Read-Ledger | Where-Object { [string]$_.Id -ne $Id })
        Write-LedgerAtomic $entries
    }
}

# =====================================================================
# 待办状态（pending）—— 让失败可续、可恢复
# =====================================================================

function Get-Pending {
    if (-not (Test-Path -LiteralPath $script:PendingPath)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($script:PendingPath, [System.Text.Encoding]::UTF8)
        if (-not $raw.Trim()) { return $null }
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

function Set-Pending {
    param($Data)
    if (-not (Test-Path -LiteralPath $script:StateRoot)) { New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $Data -Depth 6
    [System.IO.File]::WriteAllText($script:PendingPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Clear-Pending {
    if (Test-Path -LiteralPath $script:PendingPath) { Remove-Item -LiteralPath $script:PendingPath -Force -ErrorAction SilentlyContinue }
}

function Show-PendingWarning {
    $p = Get-Pending
    if (-not $p) { return $false }
    Write-H '发现未完成的搬移'
    Write-Host "  源:   $($p.Source)"
    Write-Host "  目标: $($p.Target)"
    Write-Host "  停在: $($p.Stage)"
    Write-Host "  快照: $(if ($p.Snapshot) { $p.Snapshot } else { '(还没有)' })"
    Write-Dim '先运行 .\relocator.ps1 resume 看该怎么继续；确认无误后再做新的搬移。'
    Write-Dim '若已手工处理完，运行 .\relocator.ps1 resume -Force 清除这条待办。'
    return $true
}

# =====================================================================
# 占用检测
# =====================================================================

function Initialize-RestartManager {
    if ('WinCacheRelocator.Rm' -as [type]) { return $true }
    $code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WinCacheRelocator {
    public static class Rm {
        [StructLayout(LayoutKind.Sequential)]
        struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
        const int CCH_RM_MAX_APP_NAME = 255;
        const int CCH_RM_MAX_SVC_NAME = 63;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct RM_PROCESS_INFO {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)] public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)] public string strServiceShortName;
            public int ApplicationType; public uint AppStatus; public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, [MarshalAs(UnmanagedType.LPWStr)] string strSessionKey);
        [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint pSessionHandle);
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
            uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
        [DllImport("rstrtmgr.dll")]
        static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
            [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

        public class Result { public bool Ok; public string Error; public List<string> Lockers = new List<string>(); }

        // 只接受文件路径 —— 混入目录会让整个注册返回 ERROR_INVALID_PARAMETER
        public static Result WhoLocks(string[] files) {
            var r = new Result();
            if (files == null || files.Length == 0) { r.Ok = true; return r; }
            uint handle; string key = Guid.NewGuid().ToString();
            int res = RmStartSession(out handle, 0, key);
            if (res != 0) { r.Error = "RmStartSession=" + res; return r; }
            try {
                res = RmRegisterResources(handle, (uint)files.Length, files, 0, null, 0, null);
                if (res != 0) { r.Error = "RmRegisterResources=" + res; return r; }
                uint needed = 0, count = 0, reasons = 0;
                res = RmGetList(handle, out needed, ref count, null, ref reasons);
                if (res == 234 && needed > 0) {
                    var infos = new RM_PROCESS_INFO[needed]; count = needed;
                    res = RmGetList(handle, out needed, ref count, infos, ref reasons);
                    if (res != 0) { r.Error = "RmGetList=" + res; return r; }
                    for (int i = 0; i < count; i++) {
                        string app = infos[i].strAppName, svc = infos[i].strServiceShortName;
                        string line = string.IsNullOrEmpty(svc)
                            ? app + " (PID " + infos[i].Process.dwProcessId + ")"
                            : app + " [服务: " + svc + "] (PID " + infos[i].Process.dwProcessId + ")";
                        if (!r.Lockers.Contains(line)) r.Lockers.Add(line);
                    }
                }
                r.Ok = true; return r;
            } finally { RmEndSession(handle); }
        }
    }
}
'@
    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
    return $true
}

function Get-LockerFiles {
    param([string]$Path, [int]$MaxFiles = 5000)
    $files = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0 -and $files.Count -lt $MaxFiles) {
        $dir = $stack.Pop()
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($dir)) {
                $attrs = $null
                try { $attrs = [System.IO.File]::GetAttributes($entry) } catch { continue }
                if ($attrs -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($attrs -band [System.IO.FileAttributes]::Directory) { $stack.Push($entry) }
                else { $files.Add($entry); if ($files.Count -ge $MaxFiles) { break } }
            }
        } catch { continue }
    }
    return $files
}

function Invoke-CheckLocks {
    param([string]$Path, [int]$MaxFiles = 5000)

    $lockers = New-Object System.Collections.Generic.List[string]
    $uncertain = $false
    # 注意：PowerShell 在函数返回时会把 List 解包成数组，这里必须重新包成 [string[]]
    $files = @(Get-LockerFiles -Path $Path -MaxFiles $MaxFiles)

    if ($files.Count -gt 0) {
        try {
            Initialize-RestartManager | Out-Null
            $r = [WinCacheRelocator.Rm]::WhoLocks([string[]]$files)
            if (-not $r.Ok) { $uncertain = $true; $lockers.Add("Restart Manager 查询失败（$($r.Error)）") }
            else { foreach ($l in $r.Lockers) { if (-not $lockers.Contains($l)) { $lockers.Add($l) } } }
        } catch {
            $uncertain = $true
            $lockers.Add("Restart Manager 不可用：$($_.Exception.Message)")
        }
    }

    # 改名探针：能发现 RM 覆盖不到的目录句柄占用
    $probe = "$Path.__probe"
    if (Test-Path -LiteralPath $Path) {
        try {
            Rename-Item -LiteralPath $Path -NewName (Split-Path $probe -Leaf) -ErrorAction Stop
            Rename-Item -LiteralPath $probe -NewName (Split-Path $Path -Leaf) -ErrorAction Stop
        } catch {
            if (Test-Path -LiteralPath $probe) {
                try { Rename-Item -LiteralPath $probe -NewName (Split-Path $Path -Leaf) -ErrorAction Stop } catch { }
                else { }
            }
            $msg = '正被占用（目录改名失败）'
            if (-not $lockers.Contains($msg)) { $lockers.Add($msg) }
        }
    }

    return @{ Locked = ($lockers.Count -gt 0); Lockers = $lockers; Uncertain = $uncertain; Scanned = $files.Count; Truncated = ($files.Count -ge $MaxFiles) }
}

# =====================================================================
# 联接
# =====================================================================

function ConvertTo-CmdArg {
    # cmd 会展开 %VAR%，路径里出现 % 要写成 %%
    param([string]$p)
    return '"' + ($p -replace '%', '%%') + '"'
}

function New-DirJunction {
    param([string]$LinkPath, [string]$TargetPath)
    $out = & cmd /c mklink /J (ConvertTo-CmdArg $LinkPath) (ConvertTo-CmdArg $TargetPath) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "mklink 失败：$($out -join ' ')" }
    if (-not (Test-IsJunction $LinkPath)) { throw 'mklink 报告成功，但目标不是目录联接' }
    return $true
}

function Remove-DirJunction {
    param([string]$Path)
    if (-not (Test-IsJunction $Path)) { throw "不是目录联接，拒绝删除：$Path" }
    & cmd /c rmdir (ConvertTo-CmdArg $Path) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "删除联接失败：$Path" }
    return $true
}

# =====================================================================
# scan
# =====================================================================

function Get-CandidateDirs {
    $roots = @($env:USERPROFILE, (Join-Path $env:USERPROFILE 'AppData\Local'), (Join-Path $env:USERPROFILE 'AppData\Roaming'))
    $seen = @{}
    $out = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue) {
            if ($d.Name -eq 'AppData') { continue }   # 容器，不是缓存
            $full = Resolve-FullPath $d.FullName
            $key = $full.ToLower()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $kind = Get-PathKind $full
            $prot = Test-ProtectedPath $full
            $cat = Get-CatalogEntry $full
            $class = 'unknown'; $note = ''; $strategy = ''
            if ($prot.Protected) { $class = 'protect'; $note = $prot.Reason }
            elseif ($cat) {
                $class = $cat.Entry.Class; $note = $cat.Entry.Note
                if ($cat.Entry.ContainsKey('RefusesJunction') -and $cat.Entry.RefusesJunction) { $strategy = 'env' }
                elseif ($cat.Entry.Env.Count -gt 0) { $strategy = 'env?' }
                else { $strategy = 'junction' }
            } else { $note = '未收录，默认不搬' }

            $out += [pscustomobject]@{
                Name = $d.Name; Path = $full; Kind = $kind; Class = $class; Note = $note
                Strategy = $strategy; Catalog = $(if ($cat) { $cat.Key } else { '' })
                Bytes = [long]0; Files = 0
            }
        }
    }
    return $out
}

function Invoke-Scan {
    # -Json 时不能有额外输出，否则调用方无法解析
    if (-not $Json) { Write-H $("扫描 {0}（只读）" -f $env:USERPROFILE) }
    $cands = Get-CandidateDirs
    $i = 0
    $measured = @()
    foreach ($c in $cands) {
        $i++
        if (-not $Json) { Write-Progress -Activity '测量体积' -Status $c.Name -PercentComplete (($i / [Math]::Max(1, $cands.Count)) * 100) }
        if ($c.Kind -like 'link*') { $measured += $c; continue }
        $m = Get-TreeManifest -Path $c.Path
        $c.Bytes = $m.Bytes; $c.Files = $m.Files
        $measured += $c
    }
    if (-not $Json) { Write-Progress -Activity '测量体积' -Completed }

    if ($Json) { $measured | ConvertTo-Json -Depth 4; return }

    $rows = @($measured | Where-Object { $_.Bytes -ge 50MB -or $_.Kind -like 'link*' } | Sort-Object Bytes -Descending)
    Write-Host ''
    Write-Host ('  {0}{1}{2}{3}{4}' -f (Format-Cell '目录' 26), (Format-Cell '大小' 11), (Format-Cell '分类' 10), (Format-Cell '建议' 12), '说明') -ForegroundColor DarkGray
    foreach ($r in $rows) {
        $label = switch ($r.Class) { 'safe' { '缓存' } 'close' { '应用数据' } 'protect' { '不搬' } 'caution' { '谨慎' } default { '未收录' } }
        $advice = switch ($r.Kind) {
            'link-ok' { '已搬' } 'link-broken' { '联接断了' } 'link-noshell' { '系统链接' }
            default { switch ($r.Strategy) { 'env' { '改环境变量' } 'env?' { '可用变量' } 'junction' { '可搬' } default { '—' } } }
        }
        $color = switch ($r.Class) {
            'safe' { 'Green' } 'close' { 'Yellow' } 'protect' { 'DarkGray' } 'caution' { 'DarkYellow' } default { 'Gray' }
        }
        Write-Host ('  {0}{1}{2}{3}{4}' -f (Format-Cell $r.Name 26), (Format-Cell (Format-Size $r.Bytes) 11),
            (Format-Cell $label 10), (Format-Cell $advice 12), $r.Note) -ForegroundColor $color
    }

    $movable = (@($rows | Where-Object { $_.Class -in @('safe', 'close', 'caution') -and $_.Kind -eq 'real' }) | Measure-Object Bytes -Sum).Sum
    $unknown = (@($rows | Where-Object { $_.Class -eq 'unknown' -and $_.Kind -eq 'real' }) | Measure-Object Bytes -Sum).Sum
    $protected = (@($rows | Where-Object { $_.Class -eq 'protect' }) | Measure-Object Bytes -Sum).Sum
    $links = @($measured | Where-Object { $_.Kind -like 'link*' })

    Write-Host ''
    Write-Host ("  已收录可搬 $(Format-Size $movable) · 未收录 $(Format-Size $unknown) · 受保护 $(Format-Size $protected)") -ForegroundColor Cyan
    if ($links.Count -gt 0) {
        Write-Host ("  已经是重定向点：$($links.Count) 个") -ForegroundColor Cyan
        foreach ($l in $links) {
            $tgt = Get-LinkTarget $l.Path
            $mark = switch ($l.Kind) { 'link-broken' { '断了' } 'link-noshell' { '系统' } default { 'OK ' } }
            Write-Dim ("[$mark] {0} -> {1}" -f $l.Name, $(if ($tgt) { $tgt } else { '(无目标)' }))
        }
    }
    Write-Host ''
    Write-Dim '未收录的目录默认不搬。确认安全后可预览：'
    Write-Dim '  .\relocator.ps1 move -Source "<路径>" -Target D:\Moved -DryRun -AllowUnknown'
}

# =====================================================================
# locks
# =====================================================================

function Invoke-Locks {
    if (-not $Source) { Write-Bad '用法: .\relocator.ps1 locks -Source <目录>'; Set-Failure; return }
    if (-not (Test-Path -LiteralPath $Source)) { Write-Bad "目录不存在: $Source"; Set-Failure; return }

    Write-H "检查占用: $Source"
    $r = Invoke-CheckLocks -Path $Source
    if ($r.Uncertain) { Write-No '无法确认状态（Restart Manager 不可用），按"可能被占用"处理' }
    if ($r.Truncated) { Write-No "文件数超过 $($r.Scanned) 个，只检查了前 $($r.Scanned) 个" }

    if (-not $r.Locked) {
        Write-Ok "未发现占用（检查了 $($r.Scanned) 个文件）"
        Write-Dim '注意：这不等于保证。以其他用户身份运行的进程探测不到。'
        return
    }
    Write-No "被 $($r.Lockers.Count) 个对象占用："
    foreach ($l in $r.Lockers) { Write-Dim $l }
    if (($r.Lockers -join ' ') -match '\[服务:') {
        Write-No '带 [服务: xxx] 的是系统服务，普通 Stop-Process 杀不掉：'
        Write-Dim '管理员 PowerShell：Stop-Service <服务名> -Force'
        Write-Dim '若会自动重启：Set-Service <服务名> -StartupType Manual'
    }
    Set-Failure
}

# =====================================================================
# move —— 显式状态机
# =====================================================================

function Resolve-MoveTarget {
    param([string]$Src, [string]$TargetRoot)
    $rel = if (Test-PathUnder $Src $env:USERPROFILE) {
        $Src.Substring((Resolve-FullPath $env:USERPROFILE).Length).TrimStart('\')
    } else {
        # 用户目录之外：保留盘符，避免 C:\foo 与 D:\foo 撞到同一个目标
        $drive = ($Src -replace ':.*$', '')
        $rest = $Src.Substring(2).TrimStart('\')
        ($drive + '_' + $rest) -replace '[:*?"<>|]', '_'
    }
    return (Resolve-FullPath (Join-Path (Resolve-FullPath $TargetRoot) $rel))
}

function Invoke-Move {
    param([string]$ExplicitSource, [switch]$Resuming, [switch]$batch)
    if ($batch) { $Yes = $true }

    if (-not $Resuming) {
        if (Show-PendingWarning) {
            Write-Bad '有一个未完成的搬移，先处理它（resume），或加 -Force 忽略'
            if (-not $Force) { Set-Failure; return }
            Write-No '已用 -Force 忽略未完成记录'
        }
    }

    # ---- 定位源
    if ($ExplicitSource) {
        $src = Resolve-FullPath $ExplicitSource
        if (-not (Test-Path -LiteralPath $src)) { Write-Bad "路径不存在: $ExplicitSource"; Set-Failure; return }
        if (-not $Name) { $Name = Split-Path $src -Leaf }
    } else {
        if (-not $Name) { Write-Bad '用法: .\relocator.ps1 move -Name <名字> -Target <根目录>'; Set-Failure; return }
        $hits = @(Get-CandidateDirs | Where-Object { $_.Name -ieq $Name -and $_.Kind -eq 'real' })
        if ($hits.Count -eq 0) {
            $all = @(Get-CandidateDirs | Where-Object { $_.Name -ieq $Name })
            if ($all.Count -gt 0) {
                Write-No "找到 $Name，但没有可搬的真实目录："
                foreach ($h in $all) { Write-Dim ("[{0}] {1}" -f $h.Kind, $h.Path) }
                Set-Failure; return
            }
            Write-Bad "找不到名为 $Name 的目录"; Set-Failure; return
        }
        if ($hits.Count -gt 1) {
            Write-No "有 $($hits.Count) 个同名目录，请用 -Source 指定："
            foreach ($h in $hits) { Write-Dim $h.Path }
            Set-Failure; return
        }
        $src = $hits[0].Path
    }

    if ($Subdir) {
        $src = Resolve-FullPath (Join-Path $src $Subdir)
        $Name = "$Name/$Subdir"
        if (-not (Test-Path -LiteralPath $src)) { Write-Bad "子目录不存在: $src"; Set-Failure; return }
    }

    if (-not $Target -and -not $Resuming) {
        $auto = Get-DefaultTargetRoot
        if (-not $auto) { Write-Bad '没有可用的非系统盘，请用 -Target 指定'; Set-Failure; return }
        $Target = $auto
        Write-No "没有指定 -Target，自动选择 $Target"
    }

    Write-H "搬移 $Name"
    Write-Host "  源:   $src"

    # ---- 预检：保护
    $prot = Test-ProtectedPath $src
    if ($prot.Protected) { Write-Bad "拒绝搬移：$($prot.Reason)"; Set-Failure; return }

    $kind = Get-PathKind $src
    if ($kind -eq 'link-ok') { Write-No "已经是重定向点（-> $(Get-LinkTarget $src)），不用再搬"; return }
    if ($kind -eq 'link-broken') { Write-Bad '原路径是断掉的联接，先跑 repair'; Set-Failure; return }
    if ($kind -eq 'link-noshell') { Write-Bad '原路径是系统兼容链接，不处理'; Set-Failure; return }
    if ($kind -eq 'missing') { Write-Bad '源目录不存在'; Set-Failure; return }

    # 残留快照检查：绝不静默删除（审计致命项 #1）
    $leftovers = @(Get-ChildItem -LiteralPath (Split-Path $src -Parent) -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ((Split-Path $src -Leaf) + '.moved-*') -or $_.Name -like ((Split-Path $src -Leaf) + '.moving*') })
    if ($leftovers.Count -gt 0) {
        Write-Bad '发现上次搬移留下的快照目录：'
        foreach ($l in $leftovers) { Write-Dim $l.FullName }
        Write-Bad '里面可能是原始数据，工具不会自动删除它。请先确认再手工处理。'
        Set-Failure; return
    }

    $cat = Get-CatalogEntry $src
    if (-not $cat -and -not $AllowUnknown) {
        Write-Bad '不在收录库里，默认不搬。'
        Write-Dim '目录库只收录已知的缓存与应用数据目录。确认它不是文档、不是项目代码后再加 -AllowUnknown。'
        Set-Failure; return
    }
    if ($cat -and $cat.Entry.ContainsKey('RefusesJunction') -and $cat.Entry.RefusesJunction -and $Mode -eq 'auto') {
        Write-No "这个应用拒绝联接作为数据目录，改用环境变量重定向"
        $Mode = 'env'
    }
    if ($Mode -eq 'auto') { $Mode = 'junction' }

    # ---- 预检：目标
    $dst = if ($Resuming) {
        (Get-Pending).Target
    } else {
        Resolve-MoveTarget -Src $src -TargetRoot $Target
    }
    if (-not $dst) { Write-Bad '无法确定目标路径'; Set-Failure; return }
    Write-Host "  目标: $dst"

    if (Test-PathUnder $dst $src) { Write-Bad '目标位于源目录内部，会造成自我复制'; Set-Failure; return }
    if (Test-PathUnder $src $dst) { Write-Bad '源目录位于目标内部，会造成自我复制'; Set-Failure; return }

    $protDst = Test-ProtectedPath $dst
    if ($protDst.Protected) { Write-Bad "目标路径不安全：$($protDst.Reason)"; Set-Failure; return }

    $vol = Get-VolumeInfo (Split-Path $dst -Parent).ToString()
    if (-not $vol) { $vol = Get-VolumeInfo $dst }
    if (-not $vol) { Write-Bad '无法读取目标卷信息'; Set-Failure; return }
    if (-not $vol.IsNtfs) { Write-Bad "目标卷不是 NTFS（$($vol.Format)），联接与属性复制都不可靠"; Set-Failure; return }

    $srcVol = Get-VolumeInfo $src
    if ($srcVol -and $srcVol.Root -eq $vol.Root -and -not $AllowSameVolume) {
        Write-Bad "源和目标在同一个卷（$($vol.Root)），搬了不省空间"
        Write-Dim '确实要这样做（例如重排目录）加 -AllowSameVolume'
        Set-Failure; return
    }

    # ---- 预检：体积与空间
    Write-Host '  统计体积…' -NoNewline
    $man = Get-TreeManifest -Path $src -WithHash:$Hash
    Write-Host " 完成（$(Format-Size $man.Bytes) / $($man.Files) 个文件 / $($man.Dirs) 个目录）" -ForegroundColor Green
    if ($man.Files -eq 0) { Write-Bad '目录是空的'; Set-Failure; return }
    if ($man.Errors.Count -gt 0) {
        Write-Bad "枚举时有 $($man.Errors.Count) 个错误，无法确认完整性："
        foreach ($e in ($man.Errors | Select-Object -First 3)) { Write-Dim $e }
        Set-Failure; return
    }

    $need = [long]($man.Bytes * 1.05) + 64MB
    if ($vol.Free -lt $need) {
        Write-Bad ("目标卷剩余 $(Format-Size $vol.Free)，至少需要 $(Format-Size $need)")
        Set-Failure; return
    }
    if ($man.Links.Count -gt 0) {
        Write-No "源目录里有 $($man.Links.Count) 个嵌套联接，不会被复制（避免重复搬运）："
        foreach ($l in ($man.Links | Select-Object -First 5)) { Write-Dim $l }
        Write-Dim '搬完后这些子链接会缺失。若应用依赖它们，请先单独处理。'
    }

    # ---- 预检：占用
    Write-Host '  检查占用…' -NoNewline
    $lock = Invoke-CheckLocks -Path $src
    if ($lock.Locked) {
        Write-Host ' 被占用' -ForegroundColor Yellow
        foreach ($l in $lock.Lockers) { Write-Dim $l }
        if (-not $Force) { Write-Bad '已中止。关掉对应软件后重试。'; Set-Failure; return }
        Write-No '已用 -Force 强制继续'
    } elseif ($lock.Uncertain) {
        Write-Host ' 无法确认' -ForegroundColor Yellow
        if (-not $Force) { Write-Bad '无法确认占用状态，已中止（确认无占用可加 -Force）'; Set-Failure; return }
    } else {
        Write-Host ' 没有' -ForegroundColor Green
    }

    if ($DryRun) {
        Write-Host ''
        Write-No "DryRun：模式 $Mode，会把 $(Format-Size $man.Bytes) 复制到 $dst"
        Write-Dim '没有动任何文件。'
        return
    }

    if (-not $Yes) {
        Write-Host ''
        $a = Read-Host '  确认搬移？(y/N)'
        if ($a -notmatch '^[yY]') { Write-No '已取消'; return }
    }

    if (Test-Path -LiteralPath $dst) {
        Write-Bad "目标已存在: $dst"
        Write-Dim '若是上次失败留下的半成品，先确认内容再手工删除，或换一个 -Target。'
        Set-Failure; return
    }

    # ---- 状态机开始
    $id = [guid]::NewGuid().ToString('N')
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $snapshot = "$src.moved-$stamp-$($id.Substring(0,6))"

    $state = [pscustomobject]@{
        Id = $id; Name = $Name; Source = $src; Target = $dst; Mode = $Mode
        Stage = 'pending'; Snapshot = ''; StartedAt = (Get-Date).ToString('s')
        Bytes = $man.Bytes; Files = $man.Files; Dirs = $man.Dirs
    }
    Set-Pending $state

    $stepTotal = if ($Mode -in @('move-only', 'env')) { 3 } else { 5 }

    # ---- 1. 复制
    Write-Host "  [1/$stepTotal] 复制…" -NoNewline
    if (-not (Test-Path -LiteralPath (Split-Path $dst -Parent))) { New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null }
    $log = Join-Path $script:StateRoot ("robocopy-" + $id + ".log")
    & robocopy "$src" "$dst" /E /XJ /COPY:DAT /DCOPY:DAT /R:1 /W:1 /MT:8 /LOG:"$log" /NP | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        Write-Host ' 失败' -ForegroundColor Red
        Write-Bad "robocopy 退出码 $rc（0-7 为成功位掩码，8+ 失败）。日志：$log"
        $state.Stage = 'copy-failed'; Set-Pending $state
        Set-Failure; return
    }
    if ($rc -in @(4, 6)) {
        Write-Host ' 有差异' -ForegroundColor Yellow
        Write-No "robocopy 报告了不一致（退出码 $rc），继续校验。日志：$log"
    }
    Write-Host " 完成（退出码 $rc）" -ForegroundColor Green
    $state.Stage = 'copied'; Set-Pending $state

    # ---- 2. 独立重数
    Write-Host "  [2/$stepTotal] 独立重数…" -NoNewline
    $dstMan = Get-TreeManifest -Path $dst -WithHash:$Hash
    $cmp = Compare-Manifest -Src $man -Dst $dstMan -WithHash:$Hash
    if (-not $cmp.Same -or $dstMan.Errors.Count -gt 0) {
        Write-Host ' 不一致' -ForegroundColor Red
        Write-Bad ("源 {0} 个/{1} · 目标 {2} 个/{3}" -f $cmp.SrcFiles, (Format-Size $cmp.SrcBytes), $cmp.DstFiles, (Format-Size $cmp.DstBytes))
        if ($cmp.Missing.Count -gt 0) { Write-Dim ("缺 $($cmp.Missing.Count) 个，例如：" + (($cmp.Missing | Select-Object -First 3) -join ' | ')) }
        if ($cmp.Differs.Count -gt 0) { Write-Dim ("不同 $($cmp.Differs.Count) 个，例如：" + (($cmp.Differs | Select-Object -First 3) -join ' | ')) }
        if ($dstMan.Errors.Count -gt 0) { Write-Dim ("目标枚举错误 $($dstMan.Errors.Count) 个：" + $dstMan.Errors[0]) }
        Write-Bad '已中止。源目录完好；目标目录是半成品，可手工删除后重试。'
        $state.Stage = 'verify-failed'; Set-Pending $state
        Set-Failure; return
    }
    Write-Host " 一致（$($cmp.DstFiles) 个 / $(Format-Size $cmp.DstBytes)）" -ForegroundColor Green
    $state.Stage = 'verified'; Set-Pending $state

    # ---- 3. 改成快照名
    Write-Host "  [3/$stepTotal] 源目录改名为快照…" -NoNewline
    if (Test-Path -LiteralPath $snapshot) { Write-Host ' 冲突' -ForegroundColor Red; Write-Bad "快照路径已存在: $snapshot"; Set-Failure; return }
    try {
        Rename-Item -LiteralPath $src -NewName (Split-Path $snapshot -Leaf) -ErrorAction Stop
    } catch {
        Write-Host ' 失败' -ForegroundColor Red
        Write-Bad "改名失败（可能刚被占用）：$($_.Exception.Message)"
        $state.Stage = 'rename-failed'; Set-Pending $state
        Set-Failure; return
    }
    Write-Host ' 完成' -ForegroundColor Green
    $state.Stage = 'renamed'; $state.Snapshot = $snapshot; Set-Pending $state

    # ---- move-only / env：删旧目录，不建联接
    if ($Mode -in @('move-only', 'env')) {
        Write-Host "  [3/$stepTotal] 删除旧目录…" -NoNewline
        Remove-Item -LiteralPath $snapshot -Recurse -Force -ErrorAction SilentlyContinue
        $left = Get-TreeManifest -Path $snapshot
        if (Test-Path -LiteralPath $snapshot) {
            Write-Host ' 未删干净' -ForegroundColor Yellow
            Write-Bad ("还剩 $($left.Files) 个文件（$(Format-Size $left.Bytes)）删不掉，多半被占用")
            Write-Bad "数据是完整的：目标 $dst 有全量副本，快照 $snapshot 也在"
            Write-Bad '这不算成功。关掉占用它的程序后，手工删除那份快照。'
            $state.Stage = 'cleanup-failed'; Set-Pending $state
            Set-Failure; return
        }
        Write-Host ' 完成' -ForegroundColor Green
        Add-LedgerEntry ([pscustomobject]@{
                Id = $id; Name = $Name; Source = $src; Target = $dst; Mode = $Mode
                Bytes = $man.Bytes; Files = $man.Files; MovedAt = (Get-Date).ToString('s'); Version = $script:Version
            })
        Clear-Pending
        Write-Host ''
        Write-Ok "已搬到 $dst（没有建联接）"
        Show-EnvHint -CatalogEntry $cat
        return
    }

    # ---- 4. 建联接
    Write-Host "  [4/$stepTotal] 建立联接…" -NoNewline
    try {
        New-DirJunction -LinkPath $src -TargetPath $dst | Out-Null
    } catch {
        Write-Host ' 失败' -ForegroundColor Red
        $restored = $false
        if (-not (Test-Path -LiteralPath $src)) {
            try {
                Rename-Item -LiteralPath $snapshot -NewName (Split-Path $src -Leaf) -ErrorAction Stop
                $restored = (Get-PathKind $src) -eq 'real'
            } catch { $restored = $false }
        }
        if ($restored) {
            Write-Bad "建联接失败，已把原目录改回：$($_.Exception.Message)"
            $state.Stage = 'link-failed'; Set-Pending $state
        } else {
            Write-Bad '建联接失败，且改回原名也失败！'
            Write-Bad "现状：完整数据在 $snapshot，完整副本在 $dst，原路径 $src 不存在"
            Write-Bad "恢复方法：把 $snapshot 改名回 $(Split-Path $src -Leaf)"
            $state.Stage = 'link-failed-unrestored'; Set-Pending $state
        }
        Set-Failure; return
    }

    $through = Get-TreeManifest -Path $src
    if ($through.Files -ne $man.Files -or $through.Bytes -ne $man.Bytes) {
        Write-Host ' 校验失败' -ForegroundColor Red
        $ok = $true
        try { Remove-DirJunction -Path $src } catch { $ok = $false; Write-Bad "删联接失败：$($_.Exception.Message)" }
        if ($ok) {
            try { Rename-Item -LiteralPath $snapshot -NewName (Split-Path $src -Leaf) -ErrorAction Stop }
            catch { Write-Bad "改回原名失败，原始数据在 $snapshot"; $ok = $false }
        }
        if ($ok) { Write-Bad '经联接读到的内容与源不一致，已还原'; $state.Stage = 'link-verify-failed'; Set-Pending $state }
        else { Write-Bad '还原不完整，请按上面提示手工处理'; $state.Stage = 'link-verify-failed-unrestored'; Set-Pending $state }
        Set-Failure; return
    }
    Write-Host " 完成（经联接读到 $($through.Files) 个 / $(Format-Size $through.Bytes)）" -ForegroundColor Green
    $state.Stage = 'linked'; Set-Pending $state

    # ---- 5. 删快照
    Write-Host "  [5/$stepTotal] 删除快照…" -NoNewline
    Remove-Item -LiteralPath $snapshot -Recurse -Force -ErrorAction SilentlyContinue
    $snapshotLeft = Test-Path -LiteralPath $snapshot
    if ($snapshotLeft) {
        Write-Host ' 部分残留' -ForegroundColor Yellow
        Write-No "快照没删干净：$snapshot"
    } else {
        Write-Host ' 完成' -ForegroundColor Green
    }

    Add-LedgerEntry ([pscustomobject]@{
            Id = $id; Name = $Name; Source = $src; Target = $dst; Mode = 'junction'
            Bytes = $man.Bytes; Files = $man.Files; MovedAt = (Get-Date).ToString('s'); Version = $script:Version
            Snapshot = $(if ($snapshotLeft) { $snapshot } else { '' })
        })
    Clear-Pending

    Write-Host ''
    Write-Ok "搬走 $(Format-Size $man.Bytes)"
    Write-Dim "启动 $Name 验证能正常用；有问题执行：.\relocator.ps1 undo -Name `"$Name`""
}

function Get-DefaultTargetRoot {
    <#
      没指定 -Target 时，挑剩余空间最大的非系统盘（必须是本地固定 NTFS）。
    #>
    $sysRoot = (Get-VolumeInfo $env:USERPROFILE).Root
    $best = $null
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        if ($d.DriveType -ne 'Fixed') { continue }
        if ($d.DriveFormat -ne 'NTFS') { continue }
        if ($d.RootDirectory.FullName -eq $sysRoot) { continue }
        if ($d.AvailableFreeSpace -lt 5GB) { continue }
        if (-not $best -or $d.AvailableFreeSpace -gt $best.AvailableFreeSpace) { $best = $d }
    }
    if (-not $best) { return $null }
    return (Join-Path $best.RootDirectory.FullName 'Moved')
}

function Invoke-MoveAllSafe {
    <#
      把所有"已收录且分类为 safe"的目录按体积从大到小搬走。
      这是最省心的入口：不需要用户逐个判断，因为收录库已经判过了。
    #>
    $cands = @(Get-CandidateDirs | Where-Object { $_.Class -eq 'safe' -and $_.Kind -eq 'real' })
    if ($cands.Count -eq 0) { Write-No '没有可批量搬的已收录缓存目录'; return }

    $rows = @()
    foreach ($c in $cands) {
        $m = Get-TreeManifest -Path $c.Path
        if ($m.Files -eq 0) { continue }
        $rows += [pscustomobject]@{ Name = $c.Name; Path = $c.Path; Bytes = $m.Bytes; Files = $m.Files }
    }
    $rows = @($rows | Sort-Object Bytes -Descending)
    if ($rows.Count -eq 0) { Write-No '没有可搬的'; return }

    Write-H "批量搬移 $($rows.Count) 个已收录的安全缓存"
    foreach ($r in $rows) { Write-Host ('  {0}{1}' -f (Format-Cell $r.Name 30), (Format-Size $r.Bytes)) }
    $total = ($rows | Measure-Object Bytes -Sum).Sum
    Write-Host ''
    Write-Host ("  合计 $(Format-Size $total)") -ForegroundColor Cyan

    if (-not $Target) {
        $auto = Get-DefaultTargetRoot
        if ($auto) { $Target = $auto; Write-No "目标未指定，自动选择 $Target" }
        else { Write-Bad '没有可用的非系统盘，请用 -Target 指定'; Set-Failure; return }
    }
    if ($DryRun) { Write-Host ''; Write-No 'DryRun：以上都会被搬走，现在没动任何文件'; return }
    if (-not $Yes) {
        Write-Host ''
        $a = Read-Host "  确认搬走这 $($rows.Count) 个目录？(y/N)"
        if ($a -notmatch '^[yY]') { Write-No '已取消'; return }
    }

    $ok = 0; $failed = 0
    foreach ($r in $rows) {
        Write-Host ''
        Invoke-Move -ExplicitSource $r.Path -Target $Target -batch
        if ($script:Failures -gt 0) { $failed++; $script:Failures = 0 } else { $ok++ }
    }
    Write-Host ''
    if ($failed -eq 0) { Write-Ok "全部完成：$ok 个目录" }
    else { Write-No "成功 $ok 个，失败 $failed 个（原因见上）"; Set-Failure }
}

function Show-EnvHint {
    param($CatalogEntry)
    if (-not $CatalogEntry) { Write-No '还要在软件自己的设置里把数据目录改到新位置'; return }
    $vars = $CatalogEntry.Entry.Env
    if (-not $vars -or $vars.Count -eq 0) { Write-No '这个应用没有已知的重定位变量，请在它自己的设置里改数据目录'; return }
    Write-No '还需要让软件去新位置找数据：'
    Write-Dim ('  设置环境变量：' + (($vars.Keys) -join ', '))
    Write-Dim '  或 .\relocator.ps1 env -Target <根目录>（会同时设置其他已知变量）'
}

# =====================================================================
# resume
# =====================================================================

function Invoke-Resume {
    $p = Get-Pending
    if (-not $p) { Write-No '没有未完成的搬移'; return }

    Write-H '未完成的搬移'
    Write-Host "  源:   $($p.Source)"
    Write-Host "  目标: $($p.Target)"
    Write-Host "  停在: $($p.Stage)"
    Write-Host "  快照: $(if ($p.Snapshot) { $p.Snapshot } else { '(无)' })"
    Write-Host ''

    switch ($p.Stage) {
        'pending' {
            Write-No '还没开始复制。可以直接重新运行 move。'
            if (Test-Path -LiteralPath $p.Target) { Write-Dim "目标目录已存在，可能复制了一部分：$($p.Target)" }
            Clear-Pending; Write-Ok '已清除待办，可以重新搬移'
        }
        { $_ -in @('copy-failed', 'verify-failed') } {
            Write-No '复制或校验没通过。源目录完好。'
            if (Test-Path -LiteralPath $p.Target) {
                Write-Dim "目标半成品：$($p.Target)"
                Write-Dim '确认它没用之后删掉，再重新搬移：'
                Write-Dim ('  Remove-Item -LiteralPath "' + $p.Target + '" -Recurse -Force')
            }
            Clear-Pending; Write-Ok '已清除待办'
        }
        'rename-failed' {
            Write-No '源目录改名失败，源目录应该完好。'
            if ((Get-PathKind $p.Source) -eq 'real') { Write-Ok '确认源目录是真实目录，可以重新搬移' }
            else { Write-Bad "源路径状态异常：$(Get-PathKind $p.Source)" }
            Clear-Pending
        }
        { $_ -in @('renamed', 'link-failed', 'link-failed-unrestored', 'link-verify-failed', 'link-verify-failed-unrestored', 'cleanup-failed', 'linked') } {
            Write-No '需要的原始数据在快照目录里：'
            Write-Dim $(if ($p.Snapshot) { $p.Snapshot } else { '(未记录，请检查源目录旁边)' })
            Write-Host ''
            Write-Host '  当前状态：' -ForegroundColor DarkGray
            Write-Dim ("源路径 {$($p.Source)}: " + (Get-PathKind $p.Source))
            Write-Dim ("目标 {$($p.Target)}: " + (Get-PathKind $p.Target))
            if ($p.Snapshot) { Write-Dim ("快照: " + (Get-PathKind $p.Snapshot)) }
            Write-Host ''
            Write-Host '  可选操作：' -ForegroundColor DarkGray
            Write-Dim 'a) 源路径是联接、目标有数据 -> 已完成，清掉快照并清除待办：'
            Write-Dim ('   Remove-Item -LiteralPath "' + $p.Snapshot + '" -Recurse -Force')
            Write-Dim '   然后 .\relocator.ps1 resume -Force'
            Write-Dim 'b) 想放弃 -> 删联接、把快照改名回原名、删目标：'
            Write-Dim ('   cmd /c rmdir "' + $p.Source + '"')
            Write-Dim ('   Rename-Item -LiteralPath "' + $p.Snapshot + '" -NewName "' + (Split-Path $p.Source -Leaf) + '"')
            Write-Dim ('   Remove-Item -LiteralPath "' + $p.Target + '" -Recurse -Force')
            Write-Dim '   然后 .\relocator.ps1 resume -Force'
            if ($Force) { Clear-Pending; Write-Ok '已清除待办（你自己承担状态正确性）' }
            else { Set-Failure }
        }
        default {
            Write-No "未知阶段：$($p.Stage)。请手工检查上面三个路径。"
            if ($Force) { Clear-Pending; Write-Ok '已清除待办' } else { Set-Failure }
        }
    }
}

# =====================================================================
# undo
# =====================================================================

function Invoke-Undo {
    param([switch]$AllFlag)

    $entries = @(Read-Ledger)
    if ($entries.Count -eq 0) {
        Write-No '台账是空的'
        if ($Name) { Set-Failure }
        return
    }

    if (-not $AllFlag -and $Name) {
        $entries = @($entries | Where-Object { $_.Name -ieq $Name })
        if ($entries.Count -eq 0) { Write-No "台账里没有 $Name"; Set-Failure; return }
    } elseif (-not $AllFlag) {
        Show-Ledger
        Write-Host ''
        Write-Host '  用法: .\relocator.ps1 undo -Name <名字>   或   undo -All' -ForegroundColor DarkGray
        return
    }

    if ((Show-PendingWarning)) {
        Write-Bad '有未完成的搬移，先 resume 处理'; Set-Failure; return
    }

    foreach ($e in $entries) {
        $src = Resolve-FullPath ([string]$e.Source)
        $dst = Resolve-FullPath ([string]$e.Target)
        $id = [string]$e.Id
        $mode = if ($e.PSObject.Properties['Mode'] -and $e.Mode) { [string]$e.Mode } else { 'junction' }

        Write-H "撤销 $($e.Name)"
        Write-Host "  来源: $src"
        Write-Host "  数据: $dst"

        if (-not (Test-Path -LiteralPath $dst)) {
            Write-Bad "目标数据不见了，不敢动原路径"; Set-Failure; continue
        }

        $kind = Get-PathKind $src
        if ($mode -eq 'junction') {
            if ($kind -eq 'real') { Write-Bad '原路径是真实目录（应用重建了？），请手工合并'; Set-Failure; continue }
            if ($kind -eq 'link-noshell') { Write-Bad '原路径是系统链接，跳过'; Set-Failure; continue }
            # missing / link-ok / link-broken 都可以继续
        } else {
            if ($kind -eq 'real') { Write-Bad '原路径已存在真实目录，请手工合并'; Set-Failure; continue }
        }

        if (-not $Yes) {
            $a = Read-Host '  确认搬回？(y/N)'
            if ($a -notmatch '^[yY]') { Write-No '跳过'; continue }
        }

        # 搬移之后应用可能又写了新数据，先留副本
        $rescue = ''
        try {
            $snapTime = [datetime]::Parse($e.MovedAt)
            $dstMan = Get-TreeManifest -Path $dst
            $newer = @($dstMan.Map.Values | Where-Object { $_.Write.ToLocalTime() -gt $snapTime.AddMinutes(1) })
            if ($newer.Count -gt 0) {
                $rescue = "$src.rescued-" + (Get-Date).ToString('yyyyMMdd-HHmmss')
                Write-No "目标里有 $($newer.Count) 个搬移后新写的文件，先备份到 $rescue"
                & robocopy "$dst" "$rescue" /E /XJ /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
            }
        } catch { }

        # 跨卷搬回用"复制 -> 校验 -> 切换"，避免 Move-Item 半途失败留下残缺目录
        $staging = "$src.restoring-" + (Get-Date).ToString('yyyyMMdd-HHmmss')
        Write-Host '  复制回原位置…' -NoNewline
        $nameOnly = Split-Path $src -Leaf
        if (Test-Path -LiteralPath $src) {
            # 原路径是联接或断链：先复制到兄弟目录，最后再换
            $staging = Join-Path (Split-Path $src -Parent) ($nameOnly + '.restoring-' + (Get-Date).ToString('yyyyMMddHHmmss'))
        }
        & robocopy "$dst" "$staging" /E /XJ /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /MT:8 | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Write-Host ' 失败' -ForegroundColor Red
            Write-Bad "复制失败，原联接保持不变"
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
            Set-Failure; continue
        }
        $back = Get-TreeManifest -Path $staging
        $orig = Get-TreeManifest -Path $dst
        if ($back.Files -ne $orig.Files -or $back.Bytes -ne $orig.Bytes) {
            Write-Host ' 校验不符' -ForegroundColor Red
            Write-Bad ("目标 {0} 个/{1} vs 副本 {2} 个/{3}" -f $orig.Files, (Format-Size $orig.Bytes), $back.Files, (Format-Size $back.Bytes))
            Write-Bad "没动原联接。副本留在 $staging"
            Set-Failure; continue
        }
        Write-Host " 完成（$($back.Files) 个 / $(Format-Size $back.Bytes)）" -ForegroundColor Green

        # 切换：删联接 -> 改名 -> 删目标
        if ($kind -in @('link-ok', 'link-broken')) {
            try { Remove-DirJunction -Path $src } catch { Write-Bad "删联接失败：$($_.Exception.Message)"; Set-Failure; continue }
        }
        try {
            Rename-Item -LiteralPath $staging -NewName $nameOnly -ErrorAction Stop
        } catch {
            Write-Bad "改名失败：$($_.Exception.Message)。副本在 $staging"
            if ($mode -eq 'junction') {
                try { New-DirJunction -LinkPath $src -TargetPath $dst | Out-Null; Write-No '已重建联接，恢复原状' } catch { Write-Bad '重建联接也失败了，请手工处理' }
            }
            Set-Failure; continue
        }
        Write-Ok "已搬回 $src"

        Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $dst) { Write-No "目标目录没删干净：$dst（可手工删除）" }

        if ($id) { Remove-LedgerEntry $id }
        else {
            Invoke-LedgerLock {
                $rest = @(Read-Ledger | Where-Object { -not ([string]$_.Source -eq [string]$e.Source -and [string]$_.Target -eq [string]$e.Target) })
                Write-LedgerAtomic $rest
            }
        }
        if ($rescue) { Write-No "搬移期间的新数据备份在：$rescue" }
    }
}

# =====================================================================
# repair / doctor / list
# =====================================================================

function Invoke-Repair {
    $entries = @(Read-Ledger)
    if ($Name) { $entries = @($entries | Where-Object { $_.Name -ieq $Name }) }
    if ($entries.Count -eq 0) { Write-No '台账里没有对应记录'; return }

    foreach ($e in $entries) {
        $src = Resolve-FullPath ([string]$e.Source)
        $dst = Resolve-FullPath ([string]$e.Target)
        $mode = if ($e.PSObject.Properties['Mode'] -and $e.Mode) { [string]$e.Mode } else { 'junction' }
        if ($mode -ne 'junction') { continue }

        $kind = Get-PathKind $src
        if ($kind -eq 'link-ok') { continue }
        Write-H "修复 $($e.Name)"
        if (-not (Test-Path -LiteralPath $dst)) { Write-Bad "目标数据不存在: $dst"; Set-Failure; continue }

        if ($kind -eq 'link-broken') {
            try { Remove-DirJunction -Path $src } catch { Write-Bad '删不掉断掉的联接'; Set-Failure; continue }
        } elseif ($kind -eq 'real') {
            Write-Bad '原路径是真实目录，可能应用重建了数据。为安全不动。'; Set-Failure; continue
        }
        try {
            New-DirJunction -LinkPath $src -TargetPath $dst | Out-Null
            $m = Get-TreeManifest -Path $src
            Write-Ok "已重建联接（读到 $($m.Files) 个文件）"
        } catch {
            Write-Bad "重建失败：$($_.Exception.Message)"; Set-Failure
        }
    }
}

function Invoke-Doctor {
    Write-H '体检'
    $issues = 0

    if (Show-PendingWarning) { $issues++ }

    $entries = @(Read-Ledger)
    Write-Host "  台账: $($entries.Count) 条记录"
    foreach ($e in $entries) {
        $src = Resolve-FullPath ([string]$e.Source)
        $dst = Resolve-FullPath ([string]$e.Target)
        $mode = if ($e.PSObject.Properties['Mode'] -and $e.Mode) { [string]$e.Mode } else { 'junction' }
        $kind = Get-PathKind $src
        $dstOk = Test-Path -LiteralPath $dst

        if (-not $dstOk) { Write-Bad "  [$($e.Name)] 目标数据丢失：$dst"; $issues++ }
        elseif ($mode -eq 'junction' -and $kind -eq 'link-broken') { Write-No "  [$($e.Name)] 联接断了，运行 repair"; $issues++ }
        elseif ($mode -eq 'junction' -and $kind -eq 'real') { Write-No "  [$($e.Name)] 原路径变回真实目录，请检查"; $issues++ }

        if ($e.PSObject.Properties['Snapshot'] -and $e.Snapshot -and (Test-Path -LiteralPath $e.Snapshot)) {
            Write-No "  [$($e.Name)] 有未删净的快照：$($e.Snapshot)"; $issues++
        }
    }

    Write-Host ''
    Write-Host '  扫描断掉的联接…'
    $broken = 0
    foreach ($r in @($env:USERPROFILE, (Join-Path $env:USERPROFILE 'AppData\Local'), (Join-Path $env:USERPROFILE 'AppData\Roaming'))) {
        foreach ($d in Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue) {
            if (-not ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
            $t = Get-LinkTarget $d.FullName
            if (-not $t) { continue }
            if (-not (Test-Path -LiteralPath $t)) { Write-Bad "  断链：$($d.FullName) -> $t"; $broken++ }
        }
    }
    $issues += $broken
    if ($broken -eq 0) { Write-Ok '  没有断掉的联接' }

    Write-Host ''
    if ($issues -eq 0) { Write-Ok '没发现问题' } else { Write-No "共 $issues 处需要处理" }
}

function Show-Ledger {
    $entries = @(Read-Ledger)
    if ($entries.Count -eq 0) { Write-No '台账是空的（还没有搬过东西）'; return }
    Write-H "已搬移 $($entries.Count) 项"
    $total = [long]0
    foreach ($e in $entries) {
        $mode = if ($e.PSObject.Properties['Mode'] -and $e.Mode) { [string]$e.Mode } else { 'junction' }
        $kind = Get-PathKind ([string]$e.Source)
        $dstOk = Test-Path -LiteralPath ([string]$e.Target)
        $mark = if (-not $dstOk) { '丢' } elseif ($mode -eq 'junction' -and $kind -ne 'link-ok') { '断' } else { 'OK' }
        $label = if ($mode -eq 'junction') { '联接' } else { $mode }
        Write-Host ('  [{0}] {1}{2}{3}{4}' -f $mark, (Format-Cell ([string]$e.Name) 24), (Format-Cell $label 11),
            (Format-Cell (Format-Size $e.Bytes) 10), [string]$e.Source)
        Write-Dim ("-> " + [string]$e.Target)
        $total += [long]$e.Bytes
    }
    Write-Host ''
    Write-Host "  合计 $(Format-Size $total)" -ForegroundColor Cyan
    Write-Dim "台账：$script:LedgerPath"
}

# =====================================================================
# env
# =====================================================================

function Invoke-Env {
    param([string]$Root)
    if (-not $Root) { $Root = 'D:\Toolchains' }
    $Root = Resolve-FullPath $Root

    Write-H "把工具链缓存指向 $Root"
    $plan = @()
    foreach ($k in $script:EnvLayout.Keys) {
        $path = Resolve-FullPath (Join-Path $Root $script:EnvLayout[$k])
        $cur = [Environment]::GetEnvironmentVariable($k, 'User')
        if ($cur -eq $path) { continue }
        $plan += [pscustomobject]@{ Key = $k; Old = $cur; New = $path }
    }
    if ($plan.Count -eq 0) { Write-Ok '所有变量都已经是目标值'; return }

    Write-Host ''
    foreach ($p in $plan) {
        Write-Host ('  {0,-26} {1}' -f $p.Key, $(if ($p.Old) { $p.Old } else { '(未设置)' })) -ForegroundColor DarkGray
        Write-Host ('  {0,-26} -> {1}' -f '', $p.New) -ForegroundColor Green
    }

    if ($DryRun) { Write-Host ''; Write-No "DryRun：以上 $($plan.Count) 项会被修改，现在没动"; return }

    if (-not (Test-Path -LiteralPath $script:StateRoot)) { New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null }
    $backup = Join-Path $script:StateRoot ("env-backup-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + ".json")
    $snapshot = @{}
    foreach ($p in $plan) { $snapshot[$p.Key] = $p.Old }
    [System.IO.File]::WriteAllText($backup, (ConvertTo-Json $snapshot -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "旧值已备份：$backup"

    foreach ($p in $plan) {
        if (-not (Test-Path -LiteralPath $p.New)) { New-Item -ItemType Directory -Path $p.New -Force | Out-Null }
        [Environment]::SetEnvironmentVariable($p.Key, $p.New, 'User')
        Write-Ok "$($p.Key) -> $($p.New)"
    }
    Write-Host ''
    Write-No '重新打开终端（或重启应用）后生效。'
    Write-Dim '回滚：.\relocator.ps1 undo-env'
}

function Invoke-UndoEnv {
    $latest = Get-ChildItem -LiteralPath $script:StateRoot -Filter 'env-backup-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { Write-No '没有找到 env 备份'; Set-Failure; return }
    Write-H "从 $($latest.Name) 恢复环境变量"
    $map = [System.IO.File]::ReadAllText($latest.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($k in $map.PSObject.Properties.Name) {
        $old = $map.$k
        if ($old) { [Environment]::SetEnvironmentVariable($k, $old, 'User'); Write-Ok "$k -> $old" }
        else { [Environment]::SetEnvironmentVariable($k, $null, 'User'); Write-Ok "$k 已清除" }
    }
    try { Move-Item -LiteralPath $latest.FullName -Destination ($latest.FullName + '.done') -Force } catch { }
}

# =====================================================================
# help
# =====================================================================

function Show-Help {
    Write-Host @"

win-cache-relocator v$($script:Version)
把 C 盘上会一直长回来的缓存搬到其他盘，原路径留重定向点（NTFS 目录联接）。

命令
  scan                        量体积、分类（只读）
  locks  -Source <路径>        查占用，含系统服务
  move   -Name <名字> [-Target <根目录>]
                              搬移某个目录；加 -DryRun 只预演
  move   -AllSafe [-Target <根目录>]
                              批量搬走所有已收录的安全缓存
  resume                      继续/收尾一次未完成的搬移
  undo   -Name <名字> | -All   撤销
  repair                      重建断掉的联接（不动数据）
  doctor                      体检：断链、丢失、未完成的搬移
  env    [-Target <根目录>]    设置工具链缓存环境变量
  undo-env                    还原上一次 env 的修改
  list                        已搬移清单

选项
  -DryRun           只检查、只打印计划
  -Yes              跳过确认
  -AllowUnknown     搬走未收录的目录（默认拒绝）
  -AllowSameVolume  允许源和目的在同一个盘（默认拒绝）
  -Mode             auto | junction | env | move-only
  -Hash             逐文件 SHA-256 校验（慢，更严）
  -Json             scan 输出 JSON
  -StateDir <路径>  指定台账目录（自测用）

三种重定向机制，按可靠性排序
  1. 应用自己的设置   最稳
  2. 环境变量         工具链普遍支持
  3. NTFS 目录联接    通用兜底，个别应用会拒绝

搬移是一个状态机
  pending -> 复制 -> 独立重数 -> 改名快照 -> 建联接 -> 经联接复验 -> 删快照 -> done
  每一步都落盘。中途失败，下次运行会告诉你停在哪、原始数据在哪、怎么继续。

安全约定
  · 用户数据目录（Documents / Desktop / Downloads / OneDrive 等）永远不搬
  · 未收录的目录默认不搬
  · 源和目标各自独立重数，不一致就中止，源目录不动
  · 已存在的快照目录绝不自动删除
  · 所有路径判断都用规范化后的绝对路径

"@ -ForegroundColor Gray
}

# =====================================================================
# 入口
# =====================================================================

try {
    switch ($Command.ToLower()) {
        'scan' { Invoke-Scan }
        'locks' { Invoke-Locks }
        'move' { if ($AllSafe) { Invoke-MoveAllSafe } else { Invoke-Move -ExplicitSource $Source } }
        'resume' { Invoke-Resume }
        'undo' { Invoke-Undo -AllFlag:$All }
        'repair' { Invoke-Repair }
        'doctor' { Invoke-Doctor }
        'env' { Invoke-Env -Root $Target }
        'undo-env' { Invoke-UndoEnv }
        'list' { Show-Ledger }
        default { Show-Help }
    }
} catch {
    Write-Bad "未预期的错误：$($_.Exception.Message)"
    Write-Dim $_.ScriptStackTrace
    Set-Failure
}

if ($script:Failures -gt 0) { exit 1 }
exit 0
