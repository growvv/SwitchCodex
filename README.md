# SwitchCodex

一个简单的 provider/profile 切换脚本：

- 把不同 provider 的配置放到 `~/.codex/config/<profile>/`
- 每个 profile 下固定两个文件：`auth.json` 和 `config.toml`
- 切换时把 `~/.codex/auth.json` 和 `~/.codex/config.toml` 指向对应 profile
- 支持安装/卸载 `sp` shell 命令

## 文件结构

```text
~/.codex/
├── auth.json
├── config.toml
└── config/
    ├── api111/
    │   ├── auth.json
    │   └── config.toml
    ├── cliproxy/
    │   ├── auth.json
    │   └── config.toml
    └── cliproxy_school/
        ├── auth.json
        └── config.toml
```

## 用法

### Bash / Zsh

```bash
cd ~/.codex/SwitchCodex
chmod +x switch-provider.sh

# 看当前状态
./switch-provider.sh status

# 列出所有 profile
./switch-provider.sh list

# 保存当前正在使用的 auth/config 为一个 profile
./switch-provider.sh save api111

# 从已有文件导入一个 profile
./switch-provider.sh import cliproxy ~/.codex/auth_cliproxy.json ~/.codex/config_cliproxy.toml

# 安装 shell 快捷命令：加入 PATH，并安装 sp 命令
./switch-provider.sh install

# 卸载 shell 快捷命令
./switch-provider.sh uninstall

# 切换到某个 profile
./switch-provider.sh use cliproxy

# 也支持直接把 profile 名作为参数
./switch-provider.sh api111
```

### PowerShell

```powershell
Set-Location ~/.codex/SwitchCodex

# 看当前状态
pwsh -NoProfile -File .\switch-provider.ps1 status

# 列出所有 profile
pwsh -NoProfile -File .\switch-provider.ps1 list

# 保存当前正在使用的 auth/config 为一个 profile
pwsh -NoProfile -File .\switch-provider.ps1 save api111

# 从已有文件导入一个 profile
pwsh -NoProfile -File .\switch-provider.ps1 import cliproxy ~/.codex/auth_cliproxy.json ~/.codex/config_cliproxy.toml

# 安装 PowerShell 快捷命令：写入 PowerShell profile，并安装 sp 函数
pwsh -NoProfile -File .\switch-provider.ps1 install

# 也可以指定 profile 文件
pwsh -NoProfile -File .\switch-provider.ps1 install $PROFILE.CurrentUserCurrentHost

# 卸载 PowerShell 快捷命令
pwsh -NoProfile -File .\switch-provider.ps1 uninstall

# 切换到某个 profile
pwsh -NoProfile -File .\switch-provider.ps1 use cliproxy

# 也支持直接把 profile 名作为参数
pwsh -NoProfile -File .\switch-provider.ps1 api111

# 安装/卸载后重新加载当前 PowerShell profile
. $PROFILE.CurrentUserCurrentHost
```

## 说明

- `use <profile>` 默认使用软链接切换，便于直接维护各 profile 下的真实文件。
- 首次从根目录普通文件切到 profile 时，会把原来的 `~/.codex/auth.json` 和 `~/.codex/config.toml` 备份到 `~/.codex/config/_backup/<timestamp>/`。
- 新增 provider 时，只要准备好 `~/.codex/config/<profile>/auth.json` 和 `~/.codex/config/<profile>/config.toml`，然后执行 `./switch-provider.sh <profile>` 即可。
- `install [rc-file]` 会把脚本目录写入 `PATH`，并安装 `sp` shell 函数；默认写入当前 shell 对应的 `~/.zshrc` / `~/.bashrc` / `~/.profile`。
- `uninstall [rc-file]` 会移除安装时写入的 shell block。
- `switch-provider.ps1 install [profile-file]` 会把脚本目录写入 `PATH`，并安装 `sp` PowerShell 函数；默认写入 `$PROFILE.CurrentUserCurrentHost`。
- `switch-provider.ps1 uninstall [profile-file]` 会移除安装时写入的 PowerShell block。
- `sp list` / `sp status` 会对 endpoint 做快速连接探测（默认探测 `<base_url>/models`）；在 TTY 终端下会彩色显示表头和状态。
- `sp status` 展示三项：`status`、`latency` 和 `provider`。
- `sp list` 会把当前 active profile 放在第一行，并按内容自适应列宽。
- `sp list` / `sp status` 的连接探测总超时默认按 `3` 秒执行。
- 可选环境变量：`SP_PROBE_CONNECT_TIMEOUT`（默认 `0.8` 秒）、`SP_PROBE_MAX_TIME`（默认 `3` 秒）。
