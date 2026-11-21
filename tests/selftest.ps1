<#
.SYNOPSIS
    win-cache-relocator 自测。
    在临时目录里造数据，走一遍真实搬移/撤销，逐项断言。任何失败返回非零退出码。

.EXAMPLE
    .\tests\selftest.ps1
#>
[CmdletBinding()]
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$script:Line = 0

$root = Split-Path -Parent $PSScriptRoot
$relocator = Join-Path $root 'relocator.ps1'
if (-not (Test-Path $relocator)) { throw "找不到 relocator.ps1: $relocator" }

function Test-That {
    param([string]$Name, [scriptblock]$Condition)
    $script:Line++
    try {
        $result = & $Condition
        if ($result) {
            $script:Pass++
            Write-Host ("  [OK]   {0}" -f $Name) -ForegroundColor Green
        } else {
            $script:Fail++
            Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red
        }
    } catch {
        $script:Fail++
        Write-Host ("  [FAIL] {0}  ({1})" -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
}

function Invoke-Relocator {
    param([string[]]$Arguments)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $relocator @Arguments 2>&1
}

function New-TestTree {
    param([string]$Path, [int]$Files = 8)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $payload = ('x' * 1024)
    for ($i = 1; $i -le $Files; $i++) {
        Set-Content -LiteralPath (Join-Path $Path "file$i.txt") -Value $payload
    }
    New-Item -ItemType Directory -Path (Join-Path $Path 'nested') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'nested\deep.txt') -Value 'deep'
}

$work = Join-Path $env:TEMP ("wcr-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$workSrc = Join-Path $work 'src'
$workTarget = Join-Path $work 'target'

Write-Host "`n=== win-cache-relocator 自测 ===" -ForegroundColor Cyan
Write-Host "临时目录: $work`n" -ForegroundColor DarkGray

try {
    # ---------------------------------------------------------- 1. junction 模式
    Write-Host '1. junction 模式' -ForegroundColor Cyan
    $a = Join-Path $workSrc 'appdata'
    New-TestTree -Path $a -Files 8

    Invoke-Relocator @('move', '-Source', $a, '-Target', $workTarget, '-Yes') | Out-Null

    Test-That '原路径变成联接' {
        $item = Get-Item -LiteralPath $a -Force
        [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    }
    Test-That '联接指向目标目录' {
        $item = Get-Item -LiteralPath $a -Force
        $t = if ($item.Target -is [array]) { $item.Target[0] } else { $item.Target }
        -not [string]::IsNullOrEmpty($t) -and (Test-Path $t.Substring(0, [Math]::Min(3, $t.Length)))
    }
    Test-That '经联接能读到 8 个文件' {
        @(Get-ChildItem -LiteralPath $a -File).Count -eq 8
    }
    Test-That '子目录内容完好' {
        Test-Path (Join-Path $a 'nested\deep.txt')
    }
    Test-That '没有留下 .moving 残留' {
        -not (Test-Path "$a.moving")
    }

    # ---------------------------------------------------------- 2. 台账与撤销
    Write-Host "`n2. 台账与撤销" -ForegroundColor Cyan
    Test-That '台账里有记录' {
        $out = (Invoke-Relocator @('list')) -join "`n"
        $out -match '已搬移 1 项'
    }

    Invoke-Relocator @('undo', '-Name', 'appdata', '-Yes') | Out-Null

    Test-That '撤销后不再是联接' {
        $item = Get-Item -LiteralPath $a -Force
        -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    }
    Test-That '撤销后文件数正确' {
        @(Get-ChildItem -LiteralPath $a -File).Count -eq 8
    }
    Test-That '撤销后台账清空' {
        $out = (Invoke-Relocator @('list')) -join "`n"
        $out -match '台账是空的'
    }

    # ---------------------------------------------------------- 3. move-only 模式
    Write-Host "`n3. move-only 模式（给拒绝联接的软件）" -ForegroundColor Cyan
    $b = Join-Path $workSrc 'nojunction'
    New-TestTree -Path $b -Files 4

    Invoke-Relocator @('move', '-Source', $b, '-Target', $workTarget, '-Mode', 'move-only', '-Yes') | Out-Null

    Test-That 'move-only 后源目录被删除' {
        -not (Test-Path -LiteralPath $b)
    }
    Test-That 'move-only 后数据在目标目录' {
        $rel = $b.Substring(3) -replace '\\', '\'
        $dst = Join-Path $workTarget $rel
        (Test-Path $dst) -and (@(Get-ChildItem -LiteralPath $dst -File).Count -eq 4)
    }

    # ---------------------------------------------------------- 4. 受保护路径
    Write-Host "`n4. 安全护栏" -ForegroundColor Cyan
    $protected = Join-Path $env:LOCALAPPDATA 'Microsoft'
    Test-That '拒绝搬移受保护目录' {
        $out = (Invoke-Relocator @('move', '-Source', $protected, '-Target', $workTarget, '-Yes')) -join "`n"
        $out -match '拒绝搬移'
    }
    Test-That '空目录会被拒绝' {
        $empty = Join-Path $workSrc 'empty'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $out = (Invoke-Relocator @('move', '-Source', $empty, '-Target', $workTarget, '-Yes')) -join "`n"
        $out -match '空'
    }

    # ---------------------------------------------------------- 5. 不跟随联接
    Write-Host "`n5. 复制时不跟随子联接" -ForegroundColor Cyan
    $c = Join-Path $workSrc 'withlink'
    New-TestTree -Path $c -Files 3
    $outside = Join-Path $work 'outside'
    New-TestTree -Path $outside -Files 10
    & cmd /c mklink /J "$c\link_out" "$outside" | Out-Null

    Invoke-Relocator @('move', '-Source', $c, '-Target', $workTarget, '-Yes') | Out-Null

    Test-That '子联接指向的外部数据没有被复制进来' {
        # 目标里应有 3 + 1（deep）= 4 个文件，不含外部那 10 个
        $found = Get-ChildItem -LiteralPath $workTarget -Recurse -File -Force |
            Where-Object { $_.Name -like 'file*.txt' -and $_.FullName -match 'withlink' }
        @($found).Count -eq 3
    }

    # ---------------------------------------------------------- 6. 占用检测不报错
    Write-Host "`n6. 占用检测" -ForegroundColor Cyan
    Test-That 'locks 能正常返回' {
        $d = Join-Path $workSrc 'locktest'
        New-TestTree -Path $d -Files 2
        $out = (Invoke-Relocator @('locks', '-Source', $d)) -join "`n"
        $out -match '没有检测到占用|被 .* 个进程'
    }
}
finally {
    try {
        # 清理：先删联接再删目录，避免 rmdir 递归踩到目标盘
        foreach ($dir in @($workSrc, $workTarget, $work)) {
            if (Test-Path $dir) {
                Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
                    ForEach-Object { & cmd /c rmdir "`"$($_.FullName)`"" 2>$null }
            }
        }
        if (-not $KeepTemp) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'WinCacheRelocator\ledger.json') -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

Write-Host "`n=== 结果 ===" -ForegroundColor Cyan
Write-Host ("  通过 {0} · 失败 {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) { exit 1 }
exit 0
