# Codex Profiles

**注意：`install` 会把当前脚本目录加入 `PATH`，因此安装后需要继续保留这个仓库，不能随意删除、移动或改名。**

一个给 Codex 用的 provider/profile 切换脚本。

- 当前生效配置：`~/.codex/auth.json`、`~/.codex/config.toml`
- 各 profile 配置：`~/.codex/profiles/<profile>/auth.json`、`~/.codex/profiles/<profile>/config.toml`
- 切换时把根目录文件指向对应 profile
- 安装后命令为 `sp`

## 文件结构

```text
~/.codex/
├── auth.json
├── config.toml
└── profiles/
    ├── api111/
    │   ├── auth.json
    │   └── config.toml
    ├── cliproxy/
    │   ├── auth.json
    │   └── config.toml
    └── _backup/
        └── 20260312-210000/
            ├── auth.json
            └── config.toml
```

## 用法

### Bash / Zsh

```bash
cd /path/to/SwitchCodex/codex
chmod +x switch-provider.sh

# 查看当前状态
./switch-provider.sh status

# 列出所有 profile
./switch-provider.sh list

# 保存当前 auth/config 为一个 profile
./switch-provider.sh save api111

# 从已有文件导入一个 profile
./switch-provider.sh import cliproxy ~/.codex/auth_cliproxy.json ~/.codex/config_cliproxy.toml

# 安装 shell 快捷命令
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
Set-Location /path/to/SwitchCodex/codex

# 查看当前状态
pwsh -NoProfile -File .\switch-provider.ps1 status

# 列出所有 profile
pwsh -NoProfile -File .\switch-provider.ps1 list

# 保存当前 auth/config 为一个 profile
pwsh -NoProfile -File .\switch-provider.ps1 save api111

# 从已有文件导入一个 profile
pwsh -NoProfile -File .\switch-provider.ps1 import cliproxy ~/.codex/auth_cliproxy.json ~/.codex/config_cliproxy.toml

# 安装 PowerShell 快捷命令
pwsh -NoProfile -File .\switch-provider.ps1 install

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
- 如果本机还在使用旧目录 `~/.codex/config/`，脚本会在首次运行时自动迁移到 `~/.codex/profiles/`。
- 首次从根目录普通文件切到 profile 时，会把原来的 `~/.codex/auth.json` 和 `~/.codex/config.toml` 备份到 `~/.codex/profiles/_backup/<timestamp>/`。
- `install [rc-file]` 会把脚本目录写入 `PATH`，并安装 `sp` shell 函数。
- `switch-provider.ps1 install [profile-file]` 会写入 `sp` PowerShell 函数。
- `sp` 和 `sp status` 会输出：`profile`、`status`、`latency`、`model`、`base_url`、`time`。
- `sp list` / `sp status` 会对 endpoint 做快速连接探测，并在 TTY 终端下彩色显示表头、状态和延迟。

## 可选环境变量

- `CODEX_HOME`：默认 `~/.codex`
- `CODEX_PROFILES_DIR`：默认 `~/.codex/profiles`
- `SP_PROBE_CONNECT_TIMEOUT`：默认 `0.8` 秒
- `SP_PROBE_MAX_TIME`：默认 `3` 秒
