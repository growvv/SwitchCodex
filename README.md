# SwitchCodex

一个简单的 provider/profile 切换脚本：

- 把不同 provider 的配置放到 `~/.codex/config/<profile>/`
- 每个 profile 下固定两个文件：`auth.json` 和 `config.toml`
- 切换时把 `~/.codex/auth.json` 和 `~/.codex/config.toml` 指向对应 profile

## 文件结构

```text
~/.codex/
├── auth.json
├── config.toml
└── config/
    ├── api111/
    │   ├── auth.json
    │   └── config.toml
    └── cliproxy/
        ├── auth.json
        └── config.toml
```

## 用法

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

# 切换到某个 profile
./switch-provider.sh use cliproxy

# 也支持直接把 profile 名作为参数
./switch-provider.sh api111
```

## 说明

- `use <profile>` 默认使用软链接切换，便于直接维护各 profile 下的真实文件。
- 首次从根目录普通文件切到 profile 时，会把原来的 `~/.codex/auth.json` 和 `~/.codex/config.toml` 备份到 `~/.codex/config/_backup/<timestamp>/`。
- 新增 provider 时，只要准备好 `~/.codex/config/<profile>/auth.json` 和 `~/.codex/config/<profile>/config.toml`，然后执行 `./switch-provider.sh <profile>` 即可。
