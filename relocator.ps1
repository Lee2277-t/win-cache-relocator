<#
.SYNOPSIS
    win-cache-relocator —— 把 C 盘上会持续增长的缓存目录搬到其他盘，原路径留目录联接。

.DESCRIPTION
    清理只能把问题推迟：删掉 Temp 两周后又长回来。联接是文件系统层的重定向，
    程序仍然访问原路径，字节落在别的盘，新数据也不回 C 盘。

    这个工具做四件事：
      scan   量一量哪些目录值得搬
      locks  查清楚是谁锁着（含系统服务，普通任务管理器看不到）
      move   复制 → 校验 → 建联接 → 删旧目录，任何一步失败自动还原
      undo   按台账一键搬回去

.PARAMETER Command
    scan | locks | move | undo | env | list | help

.EXAMPLE
    .\relocator.ps1 scan

.EXAMPLE
    .\relocator.ps1 move -Name codex -Target D:\Moved

.EXAMPLE
    .\relocator.ps1 undo -All
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Name = '',
    [string]$Target = '',
    [string]$Source = '',
    [switch]$All,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Force,
    [ValidateSet('junction','move-only')][string]$Mode = 'junction'
)

$ErrorActionPreference = 'Stop'
$script:Version = '1.0.0'
$script:StateDir = Join-Path $env:LOCALAPPDATA 'WinCacheRelocator'
$script:LedgerPath = Join-Path $script:StateDir 'ledger.json'
$script:ReportPath = Join-Path $script:StateDir 'last-report.txt'

# ---------------------------------------------------------------- 常量

# 绝对不能搬：系统组件、包数据、安装目录
$script:ProtectedPatterns = @(
    '\\AppData\\Local\\Packages($|\\)'
    '\\AppData\\Local\\Microsoft($|\\)'
    '\\AppData\\Roaming\\Microsoft($|\\)'
    '\\AppData\\Local\\Programs($|\\)'
    '^[A-Za-z]:\\Windows'
    '^[A-Za-z]:\\Program Files'
    '^[A-Za-z]:\\ProgramData'
    '^[A-Za-z]:\\Users\\[^\\]+$'
    '^[A-Za-z]:\\Users\\[^\\]+\\AppData$'
    '\\\.git($|\\)'
)

# 已知目录的安全等级与说明。键是目录名（不区分大小写）
$script:Catalog = @{
    '.cache'                 = @{ Class = 'safe';   Note = 'Python/uv/HF 等通用缓存' }
    '.rembg'                 = @{ Class = 'safe';   Note = '抠图模型（可重新下载）' }
    '.nuget'                 = @{ Class = 'safe';   Note = '.NET 包缓存' }
    '.gradle'                = @{ Class = 'safe';   Note = 'Gradle 缓存' }
    '.m2'                    = @{ Class = 'safe';   Note = 'Maven 本地仓库' }
    '.cargo'                 = @{ Class = 'safe';   Note = 'Rust 依赖与构建产物' }
    '.rustup'                = @{ Class = 'safe';   Note = 'Rust 工具链' }
    'npm-cache'              = @{ Class = 'safe';   Note = 'npm 缓存' }
    '_cacache'               = @{ Class = 'safe';   Note = 'npm 缓存（新布局）' }
    'pnpm-store'             = @{ Class = 'safe';   Note = 'pnpm 内容寻址仓库' }
    'pip'                    = @{ Class = 'safe';   Note = 'pip 缓存' }
    'uv'                     = @{ Class = 'safe';   Note = 'uv 缓存' }
    'ms-playwright'          = @{ Class = 'safe';   Note = 'Playwright 浏览器' }
    'Yarn'                   = @{ Class = 'safe';   Note = 'yarn 缓存' }
    'CrashDumps'             = @{ Class = 'safe';   Note = '崩溃转储' }
    'Temp'                   = @{ Class = 'caution'; Note = '临时文件，建议改用 TEMP 环境变量而不是搬' }

    '.codex'                 = @{ Class = 'close';  Note = 'Codex 数据；有系统服务时需先停服务' }
    '.dsh'                   = @{ Class = 'close';  Note = 'DeepSeek Harness 数据' }
    '.cursor'                = @{ Class = 'close';  Note = 'Cursor 数据' }
    '.claude'                = @{ Class = 'close';  Note = 'Claude Code 数据' }
    '.qoder'                 = @{ Class = 'close';  Note = 'Qoder 数据' }
    '.workbuddy'             = @{ Class = 'close';  Note = 'WorkBuddy 数据' }
    'WorkBuddy'              = @{ Class = 'close';  Note = 'WorkBuddy 工程' }
    'Doubao'                 = @{ Class = 'close';  Note = '豆包数据' }
    'Kingsoft'               = @{ Class = 'close';  Note = 'WPS 缓存' }
    'Tencent'                = @{ Class = 'close';  Note = 'QQ/微信数据' }
    'QQEX'                   = @{ Class = 'close';  Note = 'QQ 扩展数据' }
    'DingTalk'               = @{ Class = 'close';  Note = '钉钉数据' }
    'OpenAI'                 = @{ Class = 'close';  Note = 'OpenAI/ChatGPT 缓存' }
    'electron-capsule'       = @{ Class = 'close';  Note = 'Electron 应用数据' }
    'app_shell_cache_2079'   = @{ Class = 'close';  Note = '应用外壳缓存' }
    'Agents Anywhere'        = @{ Class = 'close';  Note = 'Agent 平台数据' }
    'com.qodercn.app.stable' = @{ Class = 'close';  Note = 'Qoder 应用数据' }
}

# 已知会拒绝"数据目录是联接"的软件。
# 遇到这类，用 -Mode move-only 搬数据，再按 Hints 配置，不要让联接顶在原路径。
$script:NoJunctionApps = @{
    '.dsh' = @{
        Reason = 'DSH 启动时校验数据目录必须为真实目录，见到联接会抛 Expected a real directory'
        Hints  = @(
            '设置用户环境变量 DSH_HOME 与 DSH_DESKTOP_NEXT_HOME 指向真实目录'
            '如需桌面版，另写 %APPDATA%\DSH NEXT\home\desktop-next-location.json：{"home":"<真实目录>"}'
        )
    }
}

# 工具链环境变量：设了以后新缓存直接落新盘
$script:EnvCatalog = [ordered]@{
    'TEMP'                    = 'Temp'
    'TMP'                     = 'Temp'
    'PIP_CACHE_DIR'           = 'Toolchains\pip-cache'
    'UV_CACHE_DIR'            = 'Toolchains\uv-cache'
    'npm_config_cache'        = 'Toolchains\npm-cache'
    'YARN_CACHE_FOLDER'       = 'Toolchains\yarn'
    'GRADLE_USER_HOME'        = 'Toolchains\gradle'
    'NUGET_PACKAGES'          = 'Toolchains\nuget'
    'PLAYWRIGHT_BROWSERS_PATH' = 'Toolchains\playwright'
    'HF_HOME'                 = 'Toolchains\huggingface'
    'TORCH_HOME'              = 'Toolchains\torch'
    'CARGO_HOME'              = 'Toolchains\cargo'
    'RUSTUP_HOME'             = 'Toolchains\rustup'
}

# ---------------------------------------------------------------- 输出

function Write-Head($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Write-Ok($text) { Write-Host "  OK   $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "  注意 $text" -ForegroundColor Yellow }
function Write-Err($text) { Write-Host "  错误 $text" -ForegroundColor Red }
function Format-Size($bytes) {
    if ($bytes -ge 1GB) { '{0:N2} GB' -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { '{0:N0} MB' -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { '{0:N0} KB' -f ($bytes / 1KB) }
    else { "$bytes B" }
}

# ---------------------------------------------------------------- 基础工具

function Test-IsJunction {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    } catch { return $false }
}

function Get-JunctionTarget {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }
        $t = $item.Target
        if ($t -is [array]) { return $t[0] }
        return $t
    } catch { return $null }
}

function Get-TreeStat {
    <#
      统计目录内文件数与字节数。
      关键：遇到联接（reparse point）直接跳过，绝不跟着走——
      否则会把别处的数据重复统计一遍，复制时也会重复复制。
    #>
    param([string]$Path, [int]$MaxFiles = 0)

    $files = 0
    $bytes = [long]0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($dir)) {
                $info = New-Object System.IO.FileInfo $entry
                if ($null -ne $info.Attributes -and ($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    continue        # 联接/符号链接：不跟随
                }
                if (Test-Path -LiteralPath $entry -PathType Container) {
                    $stack.Push($entry)
                } else {
                    $files++
                    $bytes += $info.Length
                    if ($MaxFiles -gt 0 -and $files -ge $MaxFiles) { return @{ Files = $files; Bytes = $bytes; Truncated = $true } }
                }
            }
        } catch { continue }
    }
    return @{ Files = $files; Bytes = $bytes; Truncated = $false }
}

function Test-Protected {
    param([string]$Path)
    foreach ($pattern in $script:ProtectedPatterns) {
        if ($Path -match $pattern) { return $true }
    }
    # 盘根、一层目录都拒绝，避免手滑搬掉整个用户目录
    $segments = ($Path -replace '/', '\').Split('\', [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($segments.Count -lt 3) { return $true }
    return $false
}

# ---------------------------------------------------------------- 台账

function Read-Ledger {
    if (-not (Test-Path $script:LedgerPath)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($script:LedgerPath, [System.Text.Encoding]::UTF8)
        if (-not $raw.Trim()) { return @() }
        # 两个 PS 5.1 的坑：
        #   1. ConvertFrom-Json 得到的对象属性只读，别改，用 [long] 在使用处转换
        #   2. '[]' 会解析成一个"空数组对象"，@(...) 之后 Count 是 1，判空会失效
        $parsed = $raw | ConvertFrom-Json
        $items = @()
        foreach ($one in @($parsed)) {
            if ($null -eq $one) { continue }
            foreach ($inner in @($one)) { if ($null -ne $inner) { $items += $inner } }
        }
        # 空壳没有 Name 属性，按这个特征过滤掉
        return @($items | Where-Object { $_ -and $_.PSObject.Properties['Name'] })
    } catch { return @() }
}

function Write-Ledger {
    param($Entries)
    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
    $json = if (@($Entries).Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject @($Entries) -Depth 6 }
    [System.IO.File]::WriteAllText($script:LedgerPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-LedgerEntry {
    param($Entry)
    $entries = @(Read-Ledger) + $Entry
    Write-Ledger $entries
}

# ---------------------------------------------------------------- 扫描

function Get-Candidates {
    $roots = @(
        $env:USERPROFILE
        (Join-Path $env:USERPROFILE 'AppData\Local')
        (Join-Path $env:USERPROFILE 'AppData\Roaming')
    )
    $seen = @{}
    $result = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue) {
            $key = $dir.FullName.ToLower()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            if (Test-Protected $dir.FullName) { continue }

            $isJunction = Test-IsJunction $dir.FullName
            $entry = [pscustomobject]@{
                Name     = $dir.Name
                Path     = $dir.FullName
                Junction = $isJunction
                Target   = if ($isJunction) { Get-JunctionTarget $dir.FullName } else { $null }
                Files    = 0
                Bytes    = [long]0
                Class    = 'unknown'
                Note     = ''
            }
            $meta = $script:Catalog[$dir.Name]
            if ($meta) { $entry.Class = $meta.Class; $entry.Note = $meta.Note }
            $result += $entry
        }
    }
    return $result
}

function Invoke-Scan {
    Write-Head "扫描 $env:USERPROFILE"
    $cands = Get-Candidates
    $measured = @()
    $i = 0
    foreach ($c in $cands) {
        $i++
        Write-Progress -Activity '测量目录体积' -Status $c.Name -PercentComplete (($i / $cands.Count) * 100)
        if ($c.Junction) { continue }   # 已是联接，不需要再量
        $stat = Get-TreeStat -Path $c.Path
        $c.Files = $stat.Files
        $c.Bytes = $stat.Bytes
        $measured += $c
    }
    Write-Progress -Activity '测量目录体积' -Completed

    $moved = $cands | Where-Object { $_.Junction }
    Write-Host ''
    Write-Host ('{0,-28} {1,10} {2,-9} {3}' -f '目录', '大小', '等级', '说明') -ForegroundColor DarkGray
    foreach ($m in ($measured | Sort-Object Bytes -Descending)) {
        if ($m.Bytes -lt 50MB) { continue }
        $color = switch ($m.Class) {
            'safe'    { 'Green' }
            'close'   { 'Yellow' }
            'caution' { 'DarkYellow' }
            default   { 'Gray' }
        }
        Write-Host ('{0,-28} {1,10} {2,-9} {3}' -f $m.Name, (Format-Size $m.Bytes), $m.Class, $m.Note) -ForegroundColor $color
    }

    $total = ($measured | Measure-Object Bytes -Sum).Sum
    Write-Host "`n可搬合计: $(Format-Size $total)  （只统计 ≥50 MB 的目录）" -ForegroundColor Cyan
    Write-Host "已经搬过的联接: $($moved.Count) 个" -ForegroundColor Cyan
    if ($moved.Count -gt 0) {
        foreach ($m in $moved) { Write-Host "  $($m.Name) -> $($m.Target)" -ForegroundColor DarkGray }
    }
    Write-Host "`n下一步: .\relocator.ps1 locks -Source <目录>   查占用" -ForegroundColor DarkGray
    Write-Host "        .\relocator.ps1 move  -Name  <目录名> -Target D:\Moved" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 占用检测（Restart Manager）

function Initialize-RestartManager {
    if ('WinCacheRelocator.Rm' -as [type]) { return $true }
    $code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WinCacheRelocator {
    public static class Rm {
        [StructLayout(LayoutKind.Sequential)]
        struct RM_UNIQUE_PROCESS {
            public int dwProcessId;
            public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
        }

        const int RmRebootReasonNone = 0;
        const int CCH_RM_MAX_APP_NAME = 255;
        const int CCH_RM_MAX_SVC_NAME = 63;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct RM_PROCESS_INFO {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
            public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
            public string strServiceShortName;
            public int ApplicationType;
            public uint AppStatus;
            public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)]
            public bool bRestartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags,
            [MarshalAs(UnmanagedType.LPWStr)] string strSessionKey);

        [DllImport("rstrtmgr.dll")]
        static extern int RmEndSession(uint pSessionHandle);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        static extern int RmRegisterResources(uint pSessionHandle,
            uint nFiles, string[] rgsFilenames,
            uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications,
            uint nServices, string[] rgsServiceNames);

        [DllImport("rstrtmgr.dll")]
        static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded,
            ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps,
            ref uint lpdwRebootReasons);

        /// <summary>返回占用这些文件的进程/服务名（可能为空）。</summary>
        public static List<string> WhoLocks(string[] files) {
            var result = new List<string>();
            if (files == null || files.Length == 0) return result;

            uint handle;
            string key = Guid.NewGuid().ToString();
            int res = RmStartSession(out handle, 0, key);
            if (res != 0) throw new Exception("RmStartSession 失败：" + res);

            try {
                res = RmRegisterResources(handle, (uint)files.Length, files, 0, null, 0, null);
                if (res != 0) return result;

                uint needed = 0, count = 0, reasons = 0;
                res = RmGetList(handle, out needed, ref count, null, ref reasons);
                if (res == 234 /* ERROR_MORE_DATA */ && needed > 0) {
                    var infos = new RM_PROCESS_INFO[needed];
                    count = needed;
                    res = RmGetList(handle, out needed, ref count, infos, ref reasons);
                    if (res == 0) {
                        for (int i = 0; i < count; i++) {
                            string app = infos[i].strAppName;
                            string svc = infos[i].strServiceShortName;
                            string line = string.IsNullOrEmpty(svc)
                                ? app + " (PID " + infos[i].Process.dwProcessId + ")"
                                : app + " [服务: " + svc + "] (PID " + infos[i].Process.dwProcessId + ")";
                            result.Add(line);
                        }
                    }
                }
            } finally {
                RmEndSession(handle);
            }
            return result;
        }
    }
}
'@
    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
    return $true
}

function Get-Lockers {
    param([string]$Path, [int]$SampleLimit = 200)

    $files = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0 -and $files.Count -lt $SampleLimit) {
        $dir = $stack.Pop()
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($dir)) {
                $info = New-Object System.IO.FileInfo $entry
                if ($null -ne $info.Attributes -and ($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
                if (Test-Path -LiteralPath $entry -PathType Container) { $stack.Push($entry) }
                else { $files.Add($entry); if ($files.Count -ge $SampleLimit) { break } }
            }
        } catch { continue }
    }

    $lockers = New-Object System.Collections.Generic.List[string]
    try {
        Initialize-RestartManager | Out-Null
        foreach ($l in [WinCacheRelocator.Rm]::WhoLocks($files.ToArray())) { $lockers.Add($l) }
    } catch {
        # Restart Manager 不可用时退回"独占打开"探测
        foreach ($f in $files) {
            try {
                $fs = [System.IO.File]::Open($f, 'Open', 'ReadWrite', 'None')
                $fs.Close()
            } catch {
                $lockers.Add("某个进程正占用: $(Split-Path $f -Leaf)")
                break
            }
        }
    }
    return $lockers
}

function Invoke-Locks {
    param([string]$Path)
    if (-not $Path) { Write-Err '用法: .\relocator.ps1 locks -Source <目录>'; return }
    if (-not (Test-Path -LiteralPath $Path)) { Write-Err "目录不存在: $Path"; return }

    Write-Head "检查占用: $Path"
    $lockers = Get-Lockers -Path $Path
    if ($lockers.Count -eq 0) {
        Write-Ok '没有检测到占用，可以搬'
    } else {
        Write-Warn "被 $($lockers.Count) 个进程/服务占用："
        $lockers | ForEach-Object { Write-Host "        $_" -ForegroundColor Yellow }
        if ($lockers -match '\[服务:') {
            Write-Host "`n  带 [服务: xxx] 的是系统服务，普通 Stop-Process 杀不掉，需要：" -ForegroundColor DarkYellow
            Write-Host "        Stop-Service <服务短名> -Force     （在管理员 PowerShell 里）" -ForegroundColor DarkGray
        }
        Write-Host "`n  请先关闭对应软件（托盘右键退出），再重试。" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------- 搬移

function New-Junction {
    param([string]$LinkPath, [string]$TargetPath)
    $out = & cmd /c mklink /J "`"$LinkPath`"" "`"$TargetPath`"" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "建立联接失败: $out" }
    return $true
}

function Remove-Junction {
    param([string]$Path)
    # 只删链接本身，不动目标数据
    & cmd /c rmdir "`"$Path`"" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "删除联接失败: $Path" }
}

function Invoke-Move {
    param([string]$Name, [string]$TargetRoot, [string]$ExplicitSource, [string]$RelocationMode = 'junction')
    $Mode = $RelocationMode

    if (-not $Name -and -not $ExplicitSource) { Write-Err '用法: .\relocator.ps1 move -Name <目录名> -Target <目标根目录>'
        Write-Err '      或: .\relocator.ps1 move -Source <绝对路径> -Target <目标根目录>'; return }

    if ($ExplicitSource) {
        if (-not (Test-Path -LiteralPath $ExplicitSource)) { Write-Err "路径不存在: $ExplicitSource"; return }
        $src = (Resolve-Path -LiteralPath $ExplicitSource).Path
        if (-not $Name) { $Name = Split-Path $src -Leaf }
    } else {
        # 定位源目录
        $cands = Get-Candidates | Where-Object { $_.Name -ieq $Name }
        if ($cands.Count -eq 0) { Write-Err "找不到名为 $Name 的目录（在用户目录 / AppData\Local / AppData\Roaming 下）"; return }
        if ($cands.Count -gt 1) {
            Write-Err "有多个同名目录，请用 -Source 指定完整路径："
            $cands | ForEach-Object { Write-Host "        $($_.Path)" }
            return
        }
        $src = $cands[0].Path
    }

    if (-not $TargetRoot) { Write-Err '请用 -Target 指定目标根目录，例如 -Target D:\Moved'; return }
    if (-not (Test-Path $TargetRoot)) {
        if ($DryRun) { Write-Warn "目标根目录不存在（正式运行会创建）: $TargetRoot" }
        else { New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null }
    }

    $rel = if ($src.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        $src.Substring($env:USERPROFILE.Length).TrimStart('\')
    } else {
        ($src -replace '^[A-Za-z]:\\?', '') -replace '[:*?"<>|]', '_'
    }
    $dst = Join-Path $TargetRoot $rel

    Write-Head "搬移 $Name"
    Write-Host "  源:   $src"
    Write-Host "  目标: $dst"

    if (Test-Protected $src) { Write-Err '这个目录在受保护清单里，拒绝搬移'; return }
    if (Test-IsJunction $src) { Write-Warn "已经是联接（-> $(Get-JunctionTarget $src)），无需再搬"; return }
    if (Test-Path $dst) { Write-Err "目标已存在: $dst （先手动清理或换个 -Target）"; return }

    $noJunction = $script:NoJunctionApps[$Name]
    if ($noJunction -and $Mode -eq 'junction') {
        Write-Warn "这个软件不接受联接作为数据目录（$($noJunction.Reason)）"
        Write-Warn '自动改用 move-only 模式：只搬数据、不建联接'
        foreach ($h in $noJunction.Hints) { Write-Host "        $h" -ForegroundColor DarkGray }
        $Mode = 'move-only'
    }

    $stat = Get-TreeStat -Path $src
    Write-Host "  体积: $(Format-Size $stat.Bytes) / $($stat.Files) 个文件"
    if ($stat.Files -eq 0) { Write-Err '目录是空的，没有搬的必要'; return }

    # 占用检查
    Write-Host '  检查占用…'
    $lockers = Get-Lockers -Path $src
    if ($lockers.Count -gt 0) {
        Write-Warn "被占用，先关掉这些："
        $lockers | ForEach-Object { Write-Host "        $_" -ForegroundColor Yellow }
        if (-not $Force) { Write-Err '已中止（确认无所谓可加 -Force，但不建议）'; return }
        Write-Warn '-Force 已指定，继续'
    } else {
        Write-Ok '没有占用'
    }

    if ($DryRun) {
        Write-Warn 'DryRun：到此为止，没有动任何文件'
        return
    }

    if (-not $Yes) {
        $answer = Read-Host "  确认搬移？(y/N)"
        if ($answer -notmatch '^[yY]') { Write-Warn '已取消'; return }
    }

    # 1. 复制（/XJ 不跟随联接 —— 否则会把别处的数据重复复制一遍）
    $stepTotal = if ($Mode -eq 'move-only') { 3 } else { 5 }
    Write-Host "  [1/$stepTotal] 复制…" -NoNewline
    New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
    & robocopy "$src" "$dst" /E /XJ /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /MT:8 | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        Write-Host ' 失败' -ForegroundColor Red
        Write-Err "robocopy 退出码 $rc，已中止（目标目录保留，源目录未动）"
        return
    }
    Write-Host ' 完成' -ForegroundColor Green

    # 2. 校验
    Write-Host "  [2/$stepTotal] 校验…" -NoNewline
    $dstStat = Get-TreeStat -Path $dst
    if ($dstStat.Files -ne $stat.Files -or $dstStat.Bytes -ne $stat.Bytes) {
        Write-Host ' 不符' -ForegroundColor Red
        Write-Err "源 $($stat.Files) 个/$(Format-Size $stat.Bytes) vs 目标 $($dstStat.Files) 个/$(Format-Size $dstStat.Bytes)"
        Write-Err '已中止，源目录未动。目标目录留给你检查，确认没问题可自行删除。'
        return
    }
    Write-Host " 一致（$($stat.Files) 个 / $(Format-Size $stat.Bytes)）" -ForegroundColor Green

    if ($Mode -eq 'move-only') {
        Write-Host '  [3/3] 删除源目录…' -NoNewline
        Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $src) {
            Write-Host ' 失败' -ForegroundColor Red
            Write-Err "源目录删不干净（有文件被占用？）：$src"
        } else {
            Write-Host ' 完成' -ForegroundColor Green
        }
        Add-LedgerEntry ([pscustomobject]@{
                Name = $Name; Source = $src; Target = $dst
                Bytes = $stat.Bytes; Files = $stat.Files
                MovedAt = (Get-Date).ToString('s'); Version = $script:Version; Mode = 'move-only'
            })
        Write-Host "`n  已搬到 $dst（未建联接）" -ForegroundColor Cyan
        if ($noJunction) {
            Write-Host '  还需要配置软件让它去新位置找数据：' -ForegroundColor Yellow
            foreach ($h in $noJunction.Hints) { Write-Host "        $h" -ForegroundColor DarkGray }
        } else {
            Write-Host '  请在该软件的设置里把数据目录改到新位置。' -ForegroundColor Yellow
        }
        return
    }

    # 3. 原目录改名（先不删，留着兜底）
    Write-Host '  [3/5] 原目录改名…' -NoNewline
    $backup = "$src.moving"
    if (Test-Path $backup) { Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue }
    try {
        Rename-Item -LiteralPath $src -NewName (Split-Path $backup -Leaf) -ErrorAction Stop
    } catch {
        Write-Host ' 失败' -ForegroundColor Red
        Write-Err "改名失败（可能刚被占用）：$($_.Exception.Message)"
        return
    }
    Write-Host ' 完成' -ForegroundColor Green

    # 4. 建联接
    Write-Host '  [4/5] 建立联接…' -NoNewline
    try {
        New-Junction -LinkPath $src -TargetPath $dst | Out-Null
    } catch {
        Write-Host ' 失败' -ForegroundColor Red
        Rename-Item -LiteralPath $backup -NewName (Split-Path $src -Leaf) -ErrorAction SilentlyContinue
        Write-Err "建联接失败，已还原: $($_.Exception.Message)"
        return
    }
    $check = Get-TreeStat -Path $src
    if ($check.Files -ne $stat.Files) {
        Write-Host ' 校验不符' -ForegroundColor Red
        Remove-Junction -Path $src
        Rename-Item -LiteralPath $backup -NewName (Split-Path $src -Leaf) -ErrorAction SilentlyContinue
        Write-Err '经联接读取的文件数不符，已还原'
        return
    }
    Write-Host ' 完成' -ForegroundColor Green

    # 5. 删除旧目录
    Write-Host '  [5/5] 清理原目录…' -NoNewline
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $backup) { Write-Host ' 部分残留' -ForegroundColor Yellow; Write-Warn "残留目录: $backup（可稍后手动删除）" }
    else { Write-Host ' 完成' -ForegroundColor Green }

    Add-LedgerEntry ([pscustomobject]@{
            Name      = $Name
            Source    = $src
            Target    = $dst
            Bytes     = $stat.Bytes
            Files     = $stat.Files
            MovedAt   = (Get-Date).ToString('s')
            Version   = $script:Version
            Mode      = 'junction'
        })

    Write-Host "`n  搬走 $(Format-Size $stat.Bytes) · 现在启动对应软件验证一下能不能正常用" -ForegroundColor Cyan
    Write-Host "  撤销: .\relocator.ps1 undo -Name $Name" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 撤销

function Invoke-Undo {
    param([string]$Name, [switch]$AllFlag)

    $entries = @(Read-Ledger)
    if ($entries.Count -eq 0) { Write-Warn '台账是空的，没有可撤销的记录'; return }

    if (-not $AllFlag -and $Name) {
        $entries = @($entries | Where-Object { $_.Name -ieq $Name })
    } elseif (-not $AllFlag) {
        Write-Head '台账'
        $entries | ForEach-Object { Write-Host ('  {0,-26} {1,10}  {2}' -f $_.Name, (Format-Size $_.Bytes), $_.Target) }
        Write-Host "`n用法: .\relocator.ps1 undo -Name <名字>   或   -All" -ForegroundColor DarkGray
        return
    }

    if ($entries.Count -eq 0) { Write-Warn "台账里没有 $Name"; return }

    foreach ($e in $entries) {
        Write-Head "撤销 $($e.Name)"
        Write-Host "  联接: $($e.Source)"
        Write-Host "  数据: $($e.Target)"

        if (-not (Test-IsJunction $e.Source)) {
            Write-Warn '原路径已经不是联接了，跳过（可能是你手动改过）'
            continue
        }
        if (-not (Test-Path -LiteralPath $e.Target)) {
            Write-Err '目标数据不存在，不敢动（联接会变成断链）'; continue
        }
        if (-not $Yes) {
            $answer = Read-Host '  确认搬回？(y/N)'
            if ($answer -notmatch '^[yY]') { Write-Warn '跳过'; continue }
        }

        $lockers = Get-Lockers -Path $e.Source
        if ($lockers.Count -gt 0) {
            Write-Warn '仍被占用，先关掉这些：'
            $lockers | ForEach-Object { Write-Host "        $_" }
            continue
        }

        Remove-Junction -Path $e.Source
        Write-Host '  移回…' -NoNewline
        Move-Item -LiteralPath $e.Target -Destination $e.Source -Force
        Write-Host ' 完成' -ForegroundColor Green

        $rest = @(Read-Ledger | Where-Object { [string]$_.Source -ne [string]$e.Source })
        Write-Ledger $rest
        Write-Ok "已搬回 $($e.Source)"
    }
}

# ---------------------------------------------------------------- 环境变量

function Invoke-Env {
    param([string]$TargetRoot)
    if (-not $TargetRoot) { $TargetRoot = 'D:\Toolchains' }

    Write-Head "把工具链缓存指到 $TargetRoot"
    $changed = 0
    foreach ($key in $script:EnvCatalog.Keys) {
        $path = Join-Path $TargetRoot $script:EnvCatalog[$key]
        if (-not (Test-Path $path)) {
            if ($DryRun) { Write-Warn "会创建 $path" }
            else { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        }
        $current = [Environment]::GetEnvironmentVariable($key, 'User')
        if ($current -eq $path) { Write-Ok "$key 已经是 $path"; continue }
        if ($DryRun) { Write-Warn "$key : '$current' -> '$path'" }
        else {
            [Environment]::SetEnvironmentVariable($key, $path, 'User')
            Write-Ok "$key -> $path"
        }
        $changed++
    }
    Write-Host "`n共 $changed 项。重新打开终端后生效。" -ForegroundColor Cyan
    Write-Host '想还原：在「系统属性 → 环境变量」里改回去，或提前备份用户变量。' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 台账列表

function Invoke-List {
    $entries = @(Read-Ledger)
    if ($entries.Count -eq 0) { Write-Warn '台账是空的（还没有搬过东西）'; return }
    Write-Head "已搬移 $($entries.Count) 项"
    $total = 0
    foreach ($e in $entries) {
        $alive = Test-IsJunction $e.Source
        $mark = if ($alive) { 'OK ' } else { '断 ' }
        Write-Host ('  [{0}] {1,-24} {2,10}  {3}  ->  {4}' -f $mark, $e.Name, (Format-Size $e.Bytes), $e.Source, $e.Target)
        $total += [long]$e.Bytes
    }
    Write-Host "`n合计 $(Format-Size $total)" -ForegroundColor Cyan
    Write-Host "台账文件: $script:LedgerPath" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 入口

function Show-Help {
    Write-Host @"

win-cache-relocator v$($script:Version)
把 C 盘上会持续增长的缓存目录搬到其他盘，原路径留目录联接（软件无感知）。

用法:
  .\relocator.ps1 scan
      量一量用户目录与 AppData 下哪些目录值得搬

  .\relocator.ps1 locks -Source "C:\Users\你\AppData\Local\Kingsoft"
      查清楚是谁锁着（含系统服务，任务管理器看不到）

  .\relocator.ps1 move -Name Kingsoft -Target D:\Moved [-DryRun] [-Yes]
      搬移：复制 -> 校验 -> 建联接 -> 删旧目录

  .\relocator.ps1 undo -Name Kingsoft
  .\relocator.ps1 undo -All
      按台账搬回去

  .\relocator.ps1 env -Target D:\Toolchains [-DryRun]
      设置工具链缓存环境变量（pip/npm/cargo/gradle/...）

  .\relocator.ps1 list
      看已搬过的清单

选项:
  -DryRun   只做检查和计划，不动文件
  -Yes      跳过确认提示
  -Force    占用检查不通过也继续（不建议）

安全:
  受保护清单里的目录（Packages / Microsoft / Program Files / Windows 等）一律拒绝搬移。
  复制时用 /XJ，不会顺着已有联接重复复制。
  任何一步校验失败都会还原，不会留下"搬了一半"的状态。

"@ -ForegroundColor Gray
}

switch ($Command.ToLower()) {
    'scan'  { Invoke-Scan }
    'locks' { Invoke-Locks -Path $Source }
    'move'  { Invoke-Move -Name $Name -TargetRoot $Target -ExplicitSource $Source -RelocationMode $Mode }
    'undo'  { Invoke-Undo -Name $Name -AllFlag:$All }
    'env'   { Invoke-Env -TargetRoot $Target }
    'list'  { Invoke-List }
    default { Show-Help }
}
