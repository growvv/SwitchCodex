# SwitchClaude

**注意：`install` 会把当前脚本目录加入 `PATH`，因此安装后需要继续保留这个仓库，不能随意删除、移动或改名。**

一个给 Claude Code 用的快速配置切换脚本，思路参考 `~/.codex/SwitchCodex`，但只管理一个文件：

- 当前生效配置：`~/.claude/settings.json`
- 各 profile 配置：`~/.claude/profiles/<profile>/settings.json`
- 切换时把 `~/.claude/settings.json` 指向对应 profile 的 `settings.json`
- 先只支持 macOS / Linux shell 环境
- 安装后命令为 `spcc`
- `spcc` 默认等价于 `spcc status`

## 文件结构

```text
~/.claude/
├── settings.json
└── profiles/
    ├── openrouter/
    │   └── settings.json
    ├── lxy/
    │   └── settings.json
    └── _backup/
        └── 20260311-231500/
            └── settings.json
```

## 用法

```bash
cd /path/to/SwitchCodex/claude
chmod +x switch-claude.sh

# 查看当前状态
./switch-claude.sh status

# 不带参数时默认就是 status
./switch-claude.sh

# 列出所有 profile
./switch-claude.sh list

# 把当前 ~/.claude/settings.json 保存成 profile
./switch-claude.sh save openrouter

# 从已有 settings 文件导入 profile
./switch-claude.sh import lxy ~/.claude/settings_lxy.json

# 切换到某个 profile
./switch-claude.sh use openrouter

# 也支持直接把 profile 名作为参数
./switch-claude.sh openrouter
```

## 安装快捷命令

```bash
# 默认写入当前 shell 对应的 rc 文件
./switch-claude.sh install

# 也可以显式指定
./switch-claude.sh install ~/.zshrc
```

安装后会：

- 把当前目录加入 `PATH`
- 注入一个 `spcc` 函数，等价于 `switch-claude.sh`

重新加载 shell：

```bash
source ~/.zshrc
```

之后可直接使用：

```bash
spcc list
spcc status
spcc openrouter
```

卸载：

```bash
./switch-claude.sh uninstall
```

## 说明

- `use <profile>` 默认使用软链接切换，这样 profile 文件本身就是实际配置源。
- 如果首次从普通文件 `~/.claude/settings.json` 切到 profile，旧文件会自动备份到 `~/.claude/profiles/_backup/<timestamp>/settings.json`。
- `spcc` 和 `spcc status` 等价，默认用于查看当前配置状态。
- `status` 会输出 `profile`、`status`、`latency`、`model`、`base_url`、`time`。
- `list` 会输出 `profile`、`state`、`model`、`latency`，当前 active profile 会加 `*`。
- `list` 采用流式输出，并发探测多个 profile，哪个先测完先展示哪个，避免长时间无输出。
- `list` / `status` / `install` / `uninstall` 的颜色高亮风格与 `codex/sp` 对齐。
- `list` / `status` 会对 `<base_url>/models` 发起一次请求，并按总超时判断结果，默认超时 `3` 秒。
- 可以直接把你现有的 `~/.claude/settings_*.json` 导入为 profile，例如：

```bash
./switch-claude.sh import yc ~/.claude/settings_yc.json
./switch-claude.sh import openrouter ~/.claude/settings_openrouter.json
./switch-claude.sh import lxy ~/.claude/settings_lxy.json
```

## 可选环境变量

- `CLAUDE_HOME`：默认 `~/.claude`
- `CLAUDE_PROFILES_DIR`：默认 `~/.claude/profiles`
- `SPCC_PROBE_CONNECT_TIMEOUT`：默认 `0.8` 秒
- `SPCC_PROBE_MAX_TIME`：默认 `3` 秒
- `SPC_TIMEOUT`：兼容旧变量名，默认 `3` 秒
