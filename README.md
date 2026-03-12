# SwitchCodex

**注意：`install` 会把当前脚本目录加入 `PATH`，因此安装后需要继续保留这个仓库，不能随意删除、移动或改名。**

一个仓库，同时维护 Codex 和 Claude Code 的 profile 切换脚本。

## 仓库结构

```text
SwitchCodex/
├── codex/
│   ├── README.md
│   ├── switch-provider.sh
│   └── switch-provider.ps1
├── claude/
│   ├── README.md
│   └── switch-claude.sh
├── changlog.md
└── AGENTS.md
```

## 统一规范

- Codex profile 目录：`~/.codex/profiles/<profile>/`
- Claude profile 目录：`~/.claude/profiles/<profile>/`
- 两边都统一支持：`list`、`status`、`save`、`import`、`use`、`install`、`uninstall`
- 安装后的快捷命令：
  - Codex：`sp`
  - Claude Code：`spcc`

## 快速入口

### Codex

```bash
cd /path/to/SwitchCodex/codex
./switch-provider.sh status
./switch-provider.sh install
sp list
sp use cliproxy
```

Windows PowerShell:

```powershell
Set-Location /path/to/SwitchCodex/codex
pwsh -NoProfile -File .\switch-provider.ps1 status
pwsh -NoProfile -File .\switch-provider.ps1 install
sp list
```

### Claude Code

```bash
cd /path/to/SwitchCodex/claude
./switch-claude.sh status
./switch-claude.sh install
spcc list
spcc use openrouter
```

## 详细说明

- Codex 侧说明见 [codex/README.md](./codex/README.md)
- Claude 侧说明见 [claude/README.md](./claude/README.md)
- 仓库变更记录见 [changlog.md](./changlog.md)
