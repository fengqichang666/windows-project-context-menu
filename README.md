# Windows 项目右键菜单

在文件资源管理器的文件夹空白处右键，添加两个独立菜单项：

- `RUN`：在当前文件夹打开 PowerShell，运行 `yarn start`。
- `Claude`：在当前文件夹打开 PowerShell，运行 `claude --dangerously-skip-permissions`。

命令执行后 PowerShell 窗口会保持打开。

选中文件、文件夹或驱动器后右键，添加一个菜单项：

- `Force Delete`：强制删除选中项，详见下方说明。

## 安装

按需双击以下入口，并允许管理员权限：

- `install-run.cmd`：只安装 `RUN`。
- `install-claude.cmd`：只安装 `Claude`。
- `install-force-delete.cmd`：只安装 `Force Delete`。

菜单项写入系统级注册表，对这台电脑上的所有用户生效。

`Force Delete` 的注册表命令里写的是 `force-delete.ps1` 的绝对路径，所以移动或重命名这个仓库目录后，需要重新执行一次 `install-force-delete.cmd`。

## 用哪个 PowerShell

`RUN` 和 `Claude` 优先用 PowerShell 7，安装时按顺序探测这两个位置：

1. `%ProgramFiles%\PowerShell\7\pwsh.exe`（winget / MSI 版，全机器共用）
2. `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`（应用商店版的执行别名）

都找不到才回落到 Windows PowerShell 5.1。实际选中的是哪个，安装时会打印出来。

这个判断只在安装时做一次，路径直接写进注册表，所以之后才装 PowerShell 7 的话，需要重新执行一次 `install-run.cmd` / `install-claude.cmd`。另外命中第 2 条时写进去的是当前用户目录下的路径，这台电脑上的其他账号如果没有注册过商店版 PowerShell，这两个菜单项对他们是无效的——装 winget / MSI 版可以避免。

`Force Delete` 固定用 Windows PowerShell 5.1：它是非交互的执行脚本，`force-delete.ps1` 是按 5.1 写和验证的，而 5.1 在任何 Windows 上都一定存在。

## 卸载

按需双击以下入口，并允许管理员权限：

- `uninstall-run.cmd`：只删除 `RUN`。
- `uninstall-claude.cmd`：只删除 `Claude`。
- `uninstall-force-delete.cmd`：只删除 `Force Delete`。

卸载只删除对应菜单项的注册表键，不影响其他项或其他右键菜单。

Windows 11 默认可能将自定义菜单项放在“显示更多选项”中。

## Force Delete

删除前会先打印目标路径和类型，需要输入 `y` 确认。**不进回收站，删掉不可恢复。**

### 删除方式

- 文件夹：`rd /s /q`。
- 文件：直接删除。
- 符号链接和 junction：只删链接本身，不动链接指向的内容。pnpm 的 `node_modules` 大量是指向全局 store 的链接，跟进去删会把 store 删掉。

这里原本用的是 `robocopy /MIR /MT` 镜像空目录，也就是网上普遍推荐的做法，但在本机实测后换掉了。24005 个文件、400 个嵌套目录的树，取两轮最快值：

| 方式 | 耗时 |
| --- | --- |
| `[IO.Directory]::Delete(recursive)` | 2.14s |
| `rd /s /q` | 2.17s |
| `del /f/s/q` + `rd /s /q` | 2.25s |
| PowerShell `Remove-Item -Recurse` | 3.76s |
| `robocopy /MIR /MT:8` | 6.72s |
| `robocopy /MIR /MT:32` | 6.72s |
| `robocopy /MIR`（不带 `/MT`） | 6.80s |

robocopy 比 `rd /s /q` 慢 3 倍，而且 `/MT:8`、`/MT:32`、不加 `/MT` 三者没有区别。NTFS 的删除元数据操作在卷级别是串行的，多线程换不来吞吐，robocopy 每个文件的记账开销则是净增加。选 `rd` 而不是更快一点的 `.NET` 递归删除，是因为 `.NET` 遇到 junction 会抛 `Access denied` 直接中断（它不会删穿，但也删不掉）。

另外两个原本选 robocopy 的理由也不成立：`rd /s /q` 实测能删掉 473 字符的深层路径，也能正确处理 junction。

### 文件被占用时

删完发现还有残留，就按下面顺序处理，每一步都会重新尝试删除：

1. 清掉 `只读`/`隐藏`/`系统` 属性后重试。这三个属性本身就会挡住删除，跟占用无关。
2. 用 Restart Manager（`rstrtmgr.dll`，系统自带，不需要装 handle.exe）查出占用进程，列出 PID 和进程名，确认后结束进程再重试。这一步能覆盖绝大多数实际情况：VS Code、TS server、还在跑的 dev server、文件监听。
3. 仍然删不掉的，可以选择加入重启删除队列（`MoveFileEx` + `MOVEFILE_DELAY_UNTIL_REBOOT`）。这些条目由 Session Manager 在开机时、占用它们的进程启动之前处理掉。这一步需要管理员权限，脚本会自行申请提权。

被标记为关键进程、以及以服务形式运行的占用者不会被结束——服务需要通过服务管理器停止，直接 kill 会被 SCM 重新拉起。占用者是资源管理器时会明确提示，结束后桌面会重启。

### 不做的事

- 不改 ACL、不执行 `takeown`。「拒绝访问」是权限问题而不是占用问题，需要时请手动处理。
- 拒绝删除驱动器根目录，以及 `Windows`、`Program Files`、`ProgramData`、`Users`、当前用户目录，包括这些路径的任何上级目录。

