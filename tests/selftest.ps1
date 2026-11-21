<#
.SYNOPSIS
    win-cache-relocator 自测。
    在临时目录里造数据、跑真实搬移/撤销/护栏，逐项断言。

    台账用 -StateDir 隔离到临时目录，绝不碰用户的真实记录。

.EXAMPLE
    .\tests\selftest.ps1
#>
[CmdletBinding()]
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

$root = Split-Path -Parent $PSScriptRoot
$relocator = Join-Path $root 'relocator.ps1'
if (-not (Test-Path -LiteralPath $relocator)) { throw "找不到 relocator.ps1: $relocator" }

$work = Join-Path $env:TEMP ("wcr-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$state = Join-Path $work '_state'
New-Item -ItemType Directory -Path $work, $state -Force | Out-Null

function Test-That {
    param([string]$Label, [scriptblock]$Condition)
    try {
        if (& $Condition) { $script:Pass++; Write-Host "  [OK]   $Label" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  [FAIL] $Label" -ForegroundColor Red }
    } catch {
        $script:Fail++; Write-Host "  [FAIL] $Label  ($($_.Exception.Message))" -ForegroundColor Red
    }
}

function Invoke-Relocator {
    param([string[]]$Arguments)
    $all = $Arguments + @('-StateDir', $state)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $relocator @all 2>&1
    return @{ Output = ($out -join "`n"); Code = $LASTEXITCODE }
}

function New-TestTree {
    param([string]$Path, [int]$Files = 8)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $payload = ('x' * 1024)
    for ($i = 1; $i -le $Files; $i++) { Set-Content -LiteralPath (Join-Path $Path "file$i.txt") -Value $payload }
    New-Item -ItemType Directory -Path (Join-Path $Path 'nested') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'nested\deep.txt') -Value 'deep'
}

function Clear-State { Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Path $state -Force | Out-Null }

Write-Host "`n=== win-cache-relocator 自测 ===" -ForegroundColor Cyan
Write-Host "临时目录: $work" -ForegroundColor DarkGray
Write-Host '台账已隔离到临时目录，不会动你的真实记录' -ForegroundColor DarkGray

try {
    $srcRoot = Join-Path $work 'src'
    $tgtRoot = Join-Path $work 'target'
    New-Item -ItemType Directory -Path $srcRoot, $tgtRoot -Force | Out-Null

    # ---------------------------------------------------------- 1. 正常搬移
    Write-Host "`n1. 目录联接模式" -ForegroundColor Cyan
    $a = Join-Path $srcRoot 'appdata'
    New-TestTree -Path $a -Files 8
    $r = Invoke-Relocator @('move', '-Source', $a, '-Target', $tgtRoot, '-Yes', '-AllowUnknown', '-AllowSameVolume')

    Test-That '搬移成功（退出码 0）' { $r.Code -eq 0 }
    Test-That '原路径变成目录联接' { (Get-Item -LiteralPath $a -Force).LinkType -eq 'Junction' }
    Test-That '经联接能读到 8 个文件' { @(Get-ChildItem -LiteralPath $a -File).Count -eq 8 }
    Test-That '子目录内容完好' { Test-Path -LiteralPath (Join-Path $a 'nested\deep.txt') }
    Test-That '没有残留快照' { @(Get-ChildItem -LiteralPath $srcRoot -Filter 'appdata.moved-*' -Force).Count -eq 0 }
    Test-That '台账写入 1 条' {
        $l = Get-Content -LiteralPath (Join-Path $state 'ledger.json') -Raw | ConvertFrom-Json
        @($l).Count -eq 1 -and @($l)[0].Mode -eq 'junction'
    }

    # ---------------------------------------------------------- 2. 撤销
    Write-Host "`n2. 撤销" -ForegroundColor Cyan
    $r = Invoke-Relocator @('undo', '-Name', 'appdata', '-Yes')
    Test-That '撤销成功（退出码 0）' { $r.Code -eq 0 }
    Test-That '撤销后不再是联接' { -not ((Get-Item -LiteralPath $a -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) }
    Test-That '撤销后文件数正确' { @(Get-ChildItem -LiteralPath $a -File).Count -eq 8 }
    Test-That '撤销后台账清空' {
        $raw = Get-Content -LiteralPath (Join-Path $state 'ledger.json') -Raw
        $raw.Trim() -eq '[]' -or ($raw | ConvertFrom-Json).Count -eq 0
    }

    # ---------------------------------------------------------- 3. move-only
    Write-Host "`n3. move-only 模式（拒绝联接的软件）" -ForegroundColor Cyan
    Clear-State
    $b = Join-Path $srcRoot 'nojunction'
    New-TestTree -Path $b -Files 4
    $r = Invoke-Relocator @('move', '-Source', $b, '-Target', $tgtRoot, '-Mode', 'move-only', '-Yes', '-AllowUnknown', '-AllowSameVolume')
    Test-That 'move-only 成功' { $r.Code -eq 0 }
    Test-That 'move-only 后源目录被删除' { -not (Test-Path -LiteralPath $b) }
    Test-That 'move-only 后数据在目标' {
        $dst = Join-Path $tgtRoot ((Split-Path $b -Leaf))
        $found = Get-ChildItem -LiteralPath $tgtRoot -Recurse -File -Filter 'file1.txt'
        @($found).Count -ge 1
    }
    $r = Invoke-Relocator @('undo', '-Name', 'nojunction', '-Yes')
    Test-That 'move-only 可以 undo' { $r.Code -eq 0 -and (Test-Path -LiteralPath $b) }
    Test-That 'move-only undo 后文件回到原位' { @(Get-ChildItem -LiteralPath $b -File).Count -eq 4 }

    # ---------------------------------------------------------- 4. 护栏
    Write-Host "`n4. 安全护栏" -ForegroundColor Cyan
    Clear-State

    $appdataTrailing = Join-Path $env:USERPROFILE 'AppData\'
    $r = Invoke-Relocator @('move', '-Source', $appdataTrailing, '-Target', $tgtRoot, '-Yes', '-AllowUnknown', '-AllowSameVolume')
    Test-That '尾随反斜杠的 AppData\ 被拒绝' { $r.Code -ne 0 -and $r.Output -match '拒绝搬移' }

    $r = Invoke-Relocator @('move', '-Source', (Join-Path $env:USERPROFILE 'Documents'), '-Target', $tgtRoot, '-Yes', '-AllowUnknown', '-AllowSameVolume')
    Test-That '用户数据目录 Documents 被拒绝' { $r.Code -ne 0 -and $r.Output -match '用户数据目录|拒绝' }

    $mystery = Join-Path $srcRoot 'mystery-data'
    New-TestTree -Path $mystery -Files 2
    $r = Invoke-Relocator @('move', '-Source', $mystery, '-Target', $tgtRoot, '-Yes', '-AllowSameVolume')
    Test-That '未收录目录默认拒绝' { $r.Code -ne 0 -and $r.Output -match '不在收录库' }

    # 目标在源内部
    $c = Join-Path $srcRoot 'inside'
    New-TestTree -Path $c -Files 2
    $r = Invoke-Relocator @('move', '-Source', $c, '-Target', $c, '-Yes', '-AllowUnknown', '-AllowSameVolume')
    Test-That '目标等于源被拒绝' { $r.Code -ne 0 -and $r.Output -match '内部' }

    $r = Invoke-Relocator @('move', '-Source', $c, '-Target', (Join-Path $c 'sub'), '-Yes', '-AllowUnknown', '-AllowSameVolume')
    Test-That '目标位于源内部被拒绝' { $r.Code -ne 0 -and $r.Output -match '内部' }

    # 已存在的快照
    $d = Join-Path $srcRoot 'leftover'
    New-TestTree -Path $d -Files 2
    $fake = "$d.moved-20200101-000000-abcdef"
    New-Item -ItemType Directory -Path $fake -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fake 'only-copy.txt') -Value 'must survive'
    $r = Invoke-Relocator @('move', '-Source', $d, '-Target', $tgtRoot, '-Yes', '-AllowUnknown', '-AllowSameVolume')
    Test-That '预存快照时不搬移并报错' { $r.Code -ne 0 -and $r.Output -match '快照' }
    Test-That '预存快照没有被删除' { Test-Path -LiteralPath (Join-Path $fake 'only-copy.txt') }

    # 方括号路径：Test-Path 对 [ ] 会当通配符，必须用 -LiteralPath
    $e = Join-Path $srcRoot 'cache[1]'
    New-TestTree -Path $e -Files 3
    $dry = (Invoke-Relocator @('move', '-Source', $e, '-Target', $tgtRoot, '-DryRun', '-AllowUnknown', '-AllowSameVolume')).Output
    $planned = ([regex]::Match($dry, '目标:\s*(.+)')).Groups[1].Value.Trim()
    Test-That 'DryRun 能报出目标路径' { $planned -ne '' }
    New-Item -ItemType Directory -Path $planned -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $planned 'file1.txt') -Value 'OLD-IMPORTANT'
    $r = Invoke-Relocator @('move', '-Source', $e, '-Target', $tgtRoot, '-Yes', '-AllowUnknown', '-AllowSameVolume')
    Test-That '方括号路径的已存在目标被识别并拒绝' { $r.Code -ne 0 -and $r.Output -match '目标已存在' }
    Test-That '目标原有内容没被覆盖' {
        (Get-Content -LiteralPath (Join-Path $planned 'file1.txt') -Raw).Trim() -eq 'OLD-IMPORTANT'
    }

    # ---------------------------------------------------------- 5. 不跟随联接
    Write-Host "`n5. 复制时不跟随子联接" -ForegroundColor Cyan
    Clear-State
    $f = Join-Path $srcRoot 'withlink'
    New-TestTree -Path $f -Files 3
    $outside = Join-Path $work 'outside'
    New-TestTree -Path $outside -Files 10
    & cmd /c mklink /J "$f\childlink" "$outside" | Out-Null
    $r = Invoke-Relocator @('move', '-Source', $f, '-Target', $tgtRoot, '-Yes', '-AllowUnknown', '-AllowSameVolume')
    Test-That '搬移成功并提示嵌套联接' { $r.Code -eq 0 -and $r.Output -match '嵌套联接' }
    Test-That '外部数据没有被复制进来' {
        @(Get-ChildItem -LiteralPath $tgtRoot -Recurse -File -Filter 'file10.txt' -ErrorAction SilentlyContinue).Count -eq 0
    }
    Test-That '外部原始数据完好' { @(Get-ChildItem -LiteralPath $outside -File).Count -eq 10 }

    # ---------------------------------------------------------- 6. 退出码
    Write-Host "`n6. 退出码与待办状态" -ForegroundColor Cyan
    $r = Invoke-Relocator @('move', '-Source', (Join-Path $work 'does-not-exist'), '-Target', $tgtRoot, '-Yes')
    Test-That '源不存在时返回非零' { $r.Code -ne 0 }

    $r = Invoke-Relocator @('undo', '-Name', 'nope', '-Yes')
    Test-That '撤销不存在的项返回非零' { $r.Code -ne 0 }

    # ---------------------------------------------------------- 7. 台账
    Write-Host "`n7. 台账" -ForegroundColor Cyan
    Clear-State
    $g = Join-Path $srcRoot 'ledger'
    New-TestTree -Path $g -Files 2
    $r = Invoke-Relocator @('move', '-Source', $g, '-Target', $tgtRoot, '-Yes', '-AllowUnknown', '-AllowSameVolume')
    Test-That '台账记录带唯一 Id' {
        $l = @(Get-Content -LiteralPath (Join-Path $state 'ledger.json') -Raw | ConvertFrom-Json)
        $l.Count -eq 1 -and $l[0].Id -and $l[0].Id.Length -ge 16
    }
    Test-That 'list 能列出' { (Invoke-Relocator @('list')).Output -match '已搬移 1 项' }
    Test-That 'doctor 正常' { $x = Invoke-Relocator @('doctor'); ($x.Output -match '体检') }
    Test-That '没有遗留待办' { -not (Test-Path -LiteralPath (Join-Path $state 'pending.json')) }
}
finally {
    # 清理：先摘联接再删目录，避免递归进目标
    foreach ($dir in @($work)) {
        if (Test-Path -LiteralPath $dir) {
            Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
                ForEach-Object { & cmd /c rmdir "$($_.FullName)" 2>$null }
        }
    }
    if (-not $KeepTemp) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    else { Write-Host "`n临时目录保留: $work" -ForegroundColor DarkGray }
}

Write-Host "`n=== 结果 ===" -ForegroundColor Cyan
Write-Host ("  通过 {0} · 失败 {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) { exit 1 }
exit 0
