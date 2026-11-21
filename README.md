# win-cache-relocator

把 C 盘上**会一直长回来**的缓存搬到其他盘，原路径留一个重定向点。
程序照常访问原来的路径，字节落在别的盘，新产生的数据也不再回 C 盘。

零依赖，只用 Windows 自带的 PowerShell 5.1、robocopy 和 Restart Manager。

```
.\relocator.cmd          交互菜单（推荐给不熟悉命令行的）
.\relocator.ps1 scan     先看看哪些目录占地方
```

---

## 为什么不是「清理」

清理只能把问题推迟。同一台机器上间隔 13 天的对比：

| 处理方式 | 清理时 | 13 天后 |
|---|---|---|
| 只删除 `%LOCALAPPDATA%\Temp` | 0 GB | **10.94 GB 又回到 C 盘** |
| 用重定向搬走 | 3.69 GB | 9.45 GB，**其中 5.76 GB 全在 D 盘** |

删除是消耗品，两周失效一次；重定向是改道。

> 这组数字来自 [drivekeeper](https://github.com/linad3d/drivekeeper) 的实测记录，不是本项目测的。
> 本站自己的验证只有一条：`.dsh` 目录搬走后，DSH 重启、日志恢复写入、新数据全部落在 D 盘。

---

## 三种重定向机制

按可靠性排序，能用前面的就不要用后面的：

| 优先级 | 机制 | 适用 | 代价 |
|---|---|---|---|
| 1 | **应用自己的设置** | 应用提供「数据目录」选项 | 需要手动点一下 |
| 2 | **环境变量** | 工具链、Agent（`CODEX_HOME`、`HF_HOME`、`NUGET_PACKAGES`…） | 只对该变量生效，需重开终端 |
| 3 | **NTFS 目录联接** | 其余所有情况（通用兜底） | 个别应用会拒绝；备份工具可能不认 |

本工具的 `env` 子命令做第 2 种，`move` 默认做第 3 种，遇到已知拒绝联接的应用会自动改用第 2 种。

**为什么不能一律用联接**：DSH（DeepSeek Harness）启动时校验数据目录「必须是真实目录」，
见到联接直接报 `Expected a real directory`。这类应用只能靠环境变量或它自己的设置。
反过来，环境变量也不能滥用——同一软件的多个版本共用一个变量时，两份数据会被指到同一个目录互相踩。

---

## 命令

| 命令 | 作用 |
|---|---|
| `scan` | 量体积、分类（只读）。加 `-Json` 输出机器可读格式 |
| `locks -Source <路径>` | 查占用，**包含系统服务** |
| `move -Name <名字> [-Target <根目录>]` | 搬移。加 `-DryRun` 只预演；不指定目标时自动选剩余空间最大的非系统盘 |
| `move -AllSafe` | 批量搬走所有已收录的安全缓存（不需要逐个判断） |
| `move -Source <绝对路径> …` | 搬任意目录（不在库里的需加 `-AllowUnknown`） |
| `resume` | 继续/收尾一次未完成的搬移 |
| `undo -Name <名字>` / `-All` | 撤销 |
| `repair` | 重建断掉的联接，不动数据 |
| `doctor` | 体检：断链、目标丢失、未完成的搬移 |
| `env -Target <根目录>` | 设置工具链缓存环境变量（改前备份旧值） |
| `undo-env` | 还原上一次 `env` 的修改 |
| `list` | 已搬移清单 |

常用选项：`-DryRun` 预演 · `-Yes` 跳过确认 · `-Hash` 逐文件 SHA-256 · `-Mode` 强制指定机制。

---

## 不知道搬哪个？用批量模式

`scan` 会列出几十个目录，逐个判断对普通人太难。收录库已经替你做了一次判断，
`-AllSafe` 直接把「已收录 + 分类为安全」的一批搬走：

```
> .\relocator.ps1 move -AllSafe -DryRun

=== 批量搬移 8 个已收录的安全缓存 ===
  @opencodedesktop-updater      510 MB
  qoder-cn-updater              458 MB
  dsh-desktop-next-updater      319 MB
  agents-anywhere-desktop-workb… 295 MB
  qoder-updater                 256 MB
  mojie-updater                 139 MB
  blockbench-updater            111 MB
  uv                            347 B

  合计 2.04 GB
  注意 目标未指定，自动选择 D:\Moved
```

**只搬 `safe` 这一档**。`close`（应用数据）和 `caution`（临时文件）都不会被批量带走，
因为它们需要你先关掉对应软件，或者本来就该用环境变量处理。

批量模式仍然逐个走完整流程：每个目录都有独立的状态机、独立校验、独立台账。
中途某个失败不会影响别的，最后汇总「成功几个、失败几个」。
## 搬移是一个状态机

不是「复制、删掉、建链接」三步糊在一起，而是每步都落盘：

```
pending → copying → verified → renamed → linked → done
              ↘ 任一步失败：状态留在 pending.json
```

失败的下一步不是猜，是运行 `resume`：

```
=== 未完成的搬移 ===
  源:   C:\Users\你\AppData\Local\Something
  目标: D:\Moved\AppData\Local\Something
  停在: link-failed-unrestored
  快照: C:\Users\你\AppData\Local\Something.moved-20261121-160342-a1b2c3
```

它会告诉你三个路径各自现在是什么状态、原始数据在哪、有哪两条路可选。

---

## 校验到底做了什么

说清楚，因为这里是同类工具最容易夸大的地方：

| 阶段 | 检查内容 |
|---|---|
| 复制后 | **逐个文件比对**相对路径、大小；再比总文件数、总字节数 |
| 建联接后 | 经联接再读一遍，比对文件数与字节数 |
| `-Hash` | 额外对每个文件算 SHA-256 并比对 |

**默认不校验文件内容**——只保证「结构一致、大小一致」。位翻转这类损坏检测不出来，
要更严就加 `-Hash`（慢，大目录可能几十分钟）。

复制用 `robocopy /E /XJ /COPY:DAT /DCOPY:DAT`：
- `/XJ` 不跟随源目录里已有的联接，否则会把别处的数据重复复制一遍（实测一次多出 7 GB）
- `/DCOPY:DAT` 保留目录时间戳
- 退出码 `< 8` 才算成功（robocopy 是位掩码，`1` 表示「有文件被复制」不是失败）

---

## 安全模型

**用户数据永远不搬。** 这一条是硬编码的，`scan` 不把它们计入「可搬」，`move` 直接拒绝：

```
Documents  Desktop  Downloads  Pictures  Music  Videos  Saved Games
OneDrive  Dropbox  Google Drive  Contacts  Favorites  Links  Public
```

**系统与安装目录也不搬：**

```
C:\Windows  C:\Program Files  C:\Program Files (x86)  C:\ProgramData
%LOCALAPPDATA%\Packages  %LOCALAPPDATA%\Microsoft  %LOCALAPPDATA%\Programs
%APPDATA%\Microsoft  %USERPROFILE%\AppData 及以下各级
任何 .git / .ssh / .gnupg
```

判断基于**归一化后的绝对路径**逐段比较，不用结尾正则——`C:\Users\你\AppData\`（带尾随反斜杠）
这种写法绕不过去。

**未收录的目录默认不搬。** 目录库只收录已知的缓存与应用数据；不认识的目录必须显式 `-AllowUnknown`。

**其他护栏：**

- 源和目标在同一个盘 → 拒绝（省不了空间，还多一份风险），除非 `-AllowSameVolume`
- 目标在源目录内部（或反之）→ 拒绝，否则 robocopy 会自我复制到路径爆炸
- 目标卷不是 NTFS → 拒绝（exFAT 保不住属性和 ACL）
- 目标剩余空间不足 → 拒绝，预留 5% + 64 MB
- 发现上次留下的快照目录 → **拒绝搬移并报出路径**，绝不自动删除
- 所有路径判断都用 `-LiteralPath`，`cache[1]` 这种名字不会被当成通配符

---

## 已知限制

**1. 个别应用拒绝联接。** 目前确认：DSH。表现为启动报错或读不到数据，
改用 `-Mode env` 或 `-Mode move-only`。发现新的欢迎提 Issue。

**2. 跨卷撤销要完整复制一遍。** 数据在 D 盘、要搬回 C 盘，本质是一次完整复制，
没有「秒回」的办法。`undo` 会先复制到临时名、校验、再切换，所以中途失败不会留下残缺目录。

**3. `scan` 在文件很多的机器上要跑一两分钟。** 它要真实遍历每个候选目录，
没有便宜的估算办法（Windows 不提供「目录总大小」的系统接口）。

**4. 嵌套联接不会被复制。** 源目录里如果有子目录是联接，`/XJ` 会跳过它，
搬完后那个链接就没了。工具会提前列出来并警告，但需要你自己决定怎么处理。

**5. 硬链接会被当成独立文件。** 统计和复制都按普通文件处理，目标会多占一份空间。

**6. 只对当前用户有效。** 系统级缓存（`C:\Windows\Temp`、`C:\ProgramData`）不碰。

**7. 不做 GUI。** 一个 1500 行的明文脚本，你可以从头读到尾。

---

## 和同类工具的关系

这个领域不算空，动手前查过一圈，明确吸收了几家的经验：

| 项目 | 借鉴了什么 |
|---|---|
| [agent-cache-migrator](https://github.com/cv-superding/agent-cache-migrator) | `RmRegisterResources` 只接受文件路径、混入目录会让整个注册失败；展开成文件要设上限并跳过联接；用「最新修改时间」辅助判断应用是否还在写 |
| [drivekeeper](https://github.com/linad3d/drivekeeper) | 机制优先级「应用设置 > 环境变量 > 联接」；复制后独立重数，不信复制工具自己的汇总；逐子目录判断而不是整个应用一刀切 |
| [AppDataMover](https://github.com/zennos0609-dotcom/AppDataMover) | Restart Manager 做精确占用检测；迁移建议分级 |
| [FreeMove](https://github.com/imDema/FreeMove) | 更早的通用「搬目录 + 建链接」实现，GUI 友好 |

本工具的差异点：**搬移过程是可恢复的状态机**，以及**把「用户数据永不搬」写成硬约束**。
同类工具多数是「选中就搬」，对普通用户来说少了这一层。

---

## 开发

```powershell
# 自测：在临时目录里造数据、跑真实搬移、逐项断言
# 台账隔离到临时目录，不会碰你的真实记录
.\tests\selftest.ps1
```

覆盖：正常搬移与撤销、move-only 的撤销、尾随反斜杠绕过、用户数据保护、
未收录目录拒绝、目标在源内部、预存快照不被删、方括号路径、子联接不复制、退出码、台账唯一 Id。

`move -AllSafe -DryRun` 可以拿来验证分类是否符合预期，它不会动任何文件。

CI 在 GitHub Actions 的 `windows-latest` 上跑同一套（`.github/workflows/test.yml`）。

---

## 许可

[AGPL-3.0-only](LICENSE)。
