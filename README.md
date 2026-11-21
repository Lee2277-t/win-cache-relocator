# win-cache-relocator

> 把 C 盘上**会一直长回来**的缓存目录搬到其他盘，原路径留一个目录联接（Junction）。
> 软件照常访问原来的路径，字节落在别的盘，新产生的数据也不再回 C 盘。
>
> A zero-dependency PowerShell tool that relocates cache directories off the system
> drive with NTFS junctions — verifies every byte before deleting, and can undo everything.

---

## 为什么不是「清理」

清理只能把问题推迟。真实机器的实测（13 天）：

| 处理方式 | 清理时 | 13 天后 |
|---|---|---|
| 只删除 `%LOCALAPPDATA%\Temp` | 0 GB | **10.94 GB 又回到 C 盘** |
| 用联接搬到 D 盘 | 3.69 GB | 9.45 GB，**其中 5.76 GB 全在 D 盘** |

也就是说：删除是消耗品，大约两周就失效一次；联接是改道，程序仍然访问原路径，只是字节不再落在 C 盘。

（这组数字来自 [drivekeeper](https://github.com/linad3d/drivekeeper) 的 README，不是本项目测的。）

---

## 它做四件事

```
scan    量一量哪些目录值得搬，按大小排序，标注安全等级
locks   查清楚是谁锁着——包括你在任务管理器里看不到的系统服务
move    复制 → 逐字节校验 → 建联接 → 删旧目录；任何一步失败自动还原
undo    按台账一键搬回去
```

### 跟同类工具的三个区别

**1. 占用检测能看见系统服务。**
用的是 Windows Restart Manager（同样是被 Office/安装程序用来查"谁占着文件"的那套 API），
所以能报出 `codex-windows-sandbox-service` 这类以 LocalSystem 身份运行的服务——
普通 `Stop-Process` 杀不掉它，任务管理器里也未必看得见，但文件确实是它锁着的。

**2. 复制时不跟随联接（`/XJ`）。**
一个目录里如果已经有子目录被做成了联接，普通复制会**顺着联接把目标盘的数据再抄一遍**，
凭空多出几 GB。本项目踩过这个坑（一次多出 7 GB），所以复制固定带 `/XJ`，
统计体积时也跳过所有 reparse point。

**3. 知道有些软件不接受联接作为数据目录。**
比如 DSH（DeepSeek Harness）启动时会校验数据目录"必须是真实目录"，见到联接直接报
`Expected a real directory`。遇到这类目录，工具会自动改用 `move-only` 模式：
只搬数据、不建联接，然后告诉你该改哪个环境变量或配置文件。

---

## 快速开始

```powershell
# 0. 下载后解压，在解压目录里打开 PowerShell
#    （或者直接用 relocator.cmd，它帮你绕过执行策略）

# 1. 看看能搬什么
.\relocator.ps1 scan

# 2. 查一个目录是谁锁着
.\relocator.ps1 locks -Source "$env:LOCALAPPDATA\Kingsoft"

# 3. 先预演，不动文件
.\relocator.ps1 move -Name Kingsoft -Target D:\Moved -DryRun

# 4. 正式搬（会问一次确认）
.\relocator.ps1 move -Name Kingsoft -Target D:\Moved

# 5. 看搬过哪些
.\relocator.ps1 list

# 6. 后悔了，搬回去
.\relocator.ps1 undo -Name Kingsoft
```

`scan` 的输出长这样：

```
目录                                 大小      等级      说明
.codex                            5.79 GB   close     Codex 数据；有系统服务时需先停服务
.dsh                              5.58 GB   close     DeepSeek Harness 数据
Kingsoft                          1.49 GB   close     WPS 缓存
.cache                            2.96 GB   safe      Python/uv/HF 等通用缓存
```

- `safe` —— 纯缓存，删了也能重建，随时可搬
- `close` —— 应用数据，**先关掉对应软件**再搬
- `caution` —— 能搬但建议用环境变量代替（比如 Temp）

---

## 安全模型

**受保护清单**（一律拒绝搬移，防止手滑搬掉系统目录）：

```
%LOCALAPPDATA%\Packages          %LOCALAPPDATA%\Microsoft
%APPDATA%\Microsoft              %LOCALAPPDATA%\Programs
C:\Windows\*                     C:\Program Files*
C:\ProgramData\*                 任何 .git 目录
盘根目录、用户目录本身、AppData 本身
```

**搬移的五步**，任何一步失败都还原：

| 步骤 | 做什么 | 失败时 |
|---|---|---|
| 1 | `robocopy /E /XJ` 复制 | 中止，源目录未动 |
| 2 | 比对**文件数 + 总字节数** | 中止，源目录未动（目标目录保留给你查） |
| 3 | 源目录改名为 `.moving` | 还原名字 |
| 4 | 建联接，**经联接再读一遍**校验 | 删联接、还原名字 |
| 5 | 删除 `.moving` | 残留会提示路径，可手动删 |

**台账**：每次搬移记录到 `%LOCALAPPDATA%\WinCacheRelocator\ledger.json`，
`undo` 按它还原。台账丢了也不影响数据——`cmd /c rmdir <原路径>` 删掉联接，
再把 D 盘目录移回去即可。

---

## 命令参考

| 命令 | 作用 |
|---|---|
| `scan` | 扫描用户目录 / AppData\Local / AppData\Roaming，列出 ≥50 MB 的目录 |
| `locks -Source <路径>` | 列出占用该目录的进程与服务 |
| `move -Name <名字> -Target <根目录>` | 搬移（按名字在用户目录与 AppData 下查找） |
| `move -Source <绝对路径> -Target <根目录>` | 搬移任意目录 |
| `undo -Name <名字>` / `undo -All` | 按台账还原 |
| `list` | 列出已搬移的项 |
| `env -Target <根目录>` | 设置工具链缓存环境变量（见下） |

**选项**：

| 选项 | 说明 |
|---|---|
| `-DryRun` | 只检查、只打印计划，不动任何文件 |
| `-Yes` | 跳过确认提示（脚本化时用） |
| `-Mode move-only` | 只搬数据、不建联接（给拒绝联接的软件用） |
| `-Force` | 占用检查不通过也继续（**不建议**） |

### `env` 会设置什么

把工具链的缓存指到新盘，这样连搬都不用搬——新数据直接落过去：

```
TEMP / TMP                pip        UV_CACHE_DIR     npm_config_cache
YARN_CACHE_FOLDER         GRADLE_USER_HOME            NUGET_PACKAGES
PLAYWRIGHT_BROWSERS_PATH  HF_HOME    TORCH_HOME       CARGO_HOME  RUSTUP_HOME
```

设的是**用户级**环境变量，重新打开终端生效。想撤回就在「系统属性 → 环境变量」里改回去。

---

## 已知限制

**1. 拒绝联接的软件。** 目前已知：

| 软件 | 表现 | 正确做法 |
|---|---|---|
| DSH（DeepSeek Harness） | 启动报 `Expected a real directory` | 用 `-Mode move-only`，再设 `DSH_HOME` 环境变量指向新目录 |

其他软件如果启动后读不到数据、报"数据目录无效"，多半也是这个问题——
改用 `move-only` 并在它的设置里指定新位置。发现新的请提 Issue。

**2. Docker / WSL 不要用本工具。** 它们的虚拟磁盘要走官方导出/导入流程。

**3. `AppData\Local\Packages` 不碰。** 系统应用数据，搬了会出各种怪问题。

**4. 联接只在本机有效。** 备份工具、同步盘、虚拟机共享目录可能不认联接。
如果你用 OneDrive 同步桌面/文档，别把这些目录搬走。

**5. 需要 Windows 10/11。** 依赖 NTFS 联接与 Restart Manager。

---

## 常见问题

**Q：搬完软件打不开了怎么办？**

先 `undo` 搬回去，确认软件正常，再想想是不是"拒绝联接"那一类（见上）。
数据不会丢——`undo` 只是删联接、把目录移回原位。

**Q：`locks` 说被占用，但我找不到那个进程。**

看输出里有没有 `[服务: xxx]`。那是系统服务，需要在**管理员** PowerShell 里
`Stop-Service xxx -Force`；有些服务停了会自动重启，那就先 `Set-Service xxx -StartupType Manual`。

**Q：能搬程序安装目录吗？**

不能，也不该。本工具只搬数据目录。装到 D 盘请用软件自己的安装程序。

**Q：搬完之后 C 盘还会长吗？**

会，但慢得多。剩下的增长来自：仍在 C 盘的小缓存、系统更新、以及硬编码了 C 盘路径的软件。
定期跑一次 `scan` 就能看到新的"大头"。

**Q：`relocator.ps1` 双击没反应 / 报"禁止运行脚本"。**

用同目录的 `relocator.cmd`，它带了 `-ExecutionPolicy Bypass`。
或者一次性放开：`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`。

**Q：为什么不做成 exe？**

零依赖、可审计。你可以打开这个 `.ps1` 从头读到尾，确认它没有偷偷删你的东西——
一个 700 行的明文脚本比一个 20 MB 的 exe 更值得信任。

---

## 开发

```powershell
# 自测（在临时目录里造数据 -> 搬 -> 校验 -> 撤销）
.\tests\selftest.ps1

# 语法检查
powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('$PWD\relocator.ps1',[ref]$null,[ref]$e); if($e){$e;exit 1}"
```

代码结构：`relocator.ps1` 单文件，按 `常量 → 基础工具 → 台账 → 扫描 → 占用检测 → 搬移 → 撤销 → 环境变量` 分段。
占用检测的 P/Invoke 在 `Initialize-RestartManager` 里，是唯一一块 C# 内嵌代码。

---

## 许可

[AGPL-3.0-only](LICENSE)。

用出问题欢迎提 Issue，附上 `scan` 输出和 `locks` 结果，一般能直接定位。
