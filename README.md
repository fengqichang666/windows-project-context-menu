# Windows 项目右键菜单

在文件资源管理器的文件夹空白处右键，添加两个独立菜单项：

- `RUN`：在当前文件夹打开 PowerShell，运行 `yarn start`。
- `Claude`：在当前文件夹打开 PowerShell，运行 `claude --dangerously-skip-permissions`。

命令执行后 PowerShell 窗口会保持打开。

## 安装

按需双击以下入口，并允许管理员权限：

- `install-run.cmd`：只安装 `RUN`。
- `install-claude.cmd`：只安装 `Claude`。

菜单项写入系统级注册表，对这台电脑上的所有用户生效。

## 卸载

按需双击以下入口，并允许管理员权限：

- `uninstall-run.cmd`：只删除 `RUN`。
- `uninstall-claude.cmd`：只删除 `Claude`。

卸载只删除对应菜单项的注册表键，不影响另一项或其他右键菜单。

Windows 11 默认可能将自定义菜单项放在“显示更多选项”中。
