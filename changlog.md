# changlog

> 说明：
> - 本文件记录仓库内变更、仓库外执行操作、设置方法、已知问题与解决方法。
> - 已提交内容尽量带上 commit id；未提交的操作明确标注为“未入库操作”或“当前工作区变更”。
> - 时间使用北京时间（UTC+8）。

## 2026-03-09 初始化阶段（未入库操作）

### 1. 盘点现有 `~/.codex` 布局
- 操作：
  - 检查了 `~/.codex` 下现有的 `auth.json`、`config.toml`、`auth_cliproxy.json`、`auth_openai.json`、`auth_yc.json`、`config_cliproxy.toml`、`config.toml.bak` 等文件。
  - 确认仓库最初为空目录，尚未初始化 Git。
- 设置方法：
  - 约定 profile 结构为 `~/.codex/config/<profile>/auth.json` 和 `~/.codex/config/<profile>/config.toml`。
- 遇到的问题：
  - 原始配置散落在 `~/.codex` 根目录和若干历史文件中，不利于切换。
- 解决方法：
  - 设计为“profile 目录 + 根目录软链接切换”的统一方案。

### 2. 初始化 profile 目录并完成首次切换验证
- 操作：
  - 保存当前根配置到 `api111` profile。
  - 从已有文件导入 `cliproxy` profile。
  - 首次把 `~/.codex/auth.json` 和 `~/.codex/config.toml` 切换为指向 profile 的软链接。
  - 做了 `cliproxy -> api111` 来回切换验证。
- 设置方法：
  - `./switch-provider.sh save api111`
  - `./switch-provider.sh import cliproxy ~/.codex/auth_cliproxy.json ~/.codex/config_cliproxy.toml`
  - `./switch-provider.sh use api111`
  - `./switch-provider.sh cliproxy`
  - `./switch-provider.sh api111`
- 遇到的问题：
  - 根目录原先是普通文件，不是软链接；直接覆盖有风险。
- 解决方法：
  - 首次切换前自动备份到 `~/.codex/config/_backup/20260309-170407/`，再改为软链接。

### 3. 清理 provider 并整理学校代理 profile
- 操作：
  - 从 `~/.codex/config/api111/config.toml`、`~/.codex/config/cliproxy/config.toml`、`~/.codex/config_cliproxy.toml` 中移除了 `custom` 和 `crs` provider 段。
  - 复制 `cliproxy` profile，整理出 `cliproxy_school` profile。
- 设置方法：
  - `cliproxy_school` 目录为 `~/.codex/config/cliproxy_school/`
  - 其 `config.toml` 中主 provider 设置为 `model_provider = "cliproxy_school"`
- 遇到的问题：
  - 老配置里保留了不再使用的 `custom` / `crs`，后续再次导入时容易回流。
- 解决方法：
  - 同时清理 profile 配置和旧的 `config_cliproxy.toml`，减少未来污染。

### 4. GitHub 仓库初始化与首推
- 操作：
  - 初始化本地 Git 仓库。
  - 添加最小 `.gitignore`。
  - 创建 GitHub 私有仓库 `growvv/SwitchCodex`。
  - 推送 `main` 分支并建立跟踪。
- 设置方法：
  - 远端：`git@github.com:growvv/SwitchCodex.git`
  - 仓库地址：`https://github.com/growvv/SwitchCodex`
- 遇到的问题：
  - 项目最初不是 Git 仓库。
- 解决方法：
  - 使用 `git init -b main`、`gh repo create` 和 `git push -u origin main` 完成初始化。

### 5. 初始 shell 安装方式
- 操作：
  - 早期版本曾把脚本目录加入 `PATH`，并向 `~/.zshrc` 写入 `alias sp='switch-provider.sh'`。
- 设置方法：
  - 通过旧版本命令把块写入 shell 配置文件。
- 遇到的问题：
  - alias 只能转发命令，无法满足后续“需要影响当前 shell 环境”的能力扩展。
- 解决方法：
  - 后续将 `sp` 升级为 shell 函数，并继续迭代安装逻辑。

### 6. 工具使用过程中的一次告警
- 操作：
  - 首次修改时，曾经通过 `exec_command` 间接调用了 `apply_patch`。
- 遇到的问题：
  - 收到“应直接使用 `apply_patch` tool”的告警。
- 解决方法：
  - 后续文件编辑统一改为直接调用 `apply_patch`。

## 2026-03-09 17:42:12 +0800 — `b791a07` `Initial commit: add provider switch script`
- 操作：
  - 新增 `switch-provider.sh`。
  - 新增 `README.md`。
  - 新增 `.gitignore`。
- 设置方法：
  - 通过 `save`、`import`、`use`、`list`、`status` 等子命令维护 `~/.codex/config/<profile>/`。
- 遇到的问题：
  - 最初缺少统一入口脚本。
- 解决方法：
  - 用 Bash 脚本统一 profile 管理与切换。

## 2026-03-09 17:55:18 +0800 — `75f0a5a` `Add env set/unset flow for profiles`
- 操作：
  - 给脚本增加了 `set [profile]` / `unset`。
  - 把 `sp` 从 alias 升级为 shell 函数，以支持在当前 shell 中 `eval` 导出环境变量。
  - 更新了 `README.md` 的使用说明。
- 设置方法：
  - `sp set cliproxy`
  - `sp unset`
- 遇到的问题：
  - 需要把 profile 的 `OPENAI_API_KEY`、`OPENAI_BASE_URL`、`OPENAI_MODEL` 映射到当前终端。
  - zsh 中使用局部变量名 `status` 时，报错 `read-only variable: status`。
- 解决方法：
  - 改成 shell 函数执行导出逻辑。
  - 将变量名从 `status` 改为 `exit_code`。

## 2026-03-09 18:35:53 +0800 — `0fca3e7` `feat: simplify sp install flow and list/status output`
- 操作：
  - 简化 `sp` 的安装流程。
  - 重做 `list` / `status` 的展示逻辑。
  - 继续调整 README 说明。
- 设置方法：
  - 统一使用 `install` / `uninstall` 维护 shell block。
- 遇到的问题：
  - 之前的 shell 安装方式和命令行为逐步复杂化，不够稳定。
- 解决方法：
  - 统一 shell block 的安装与卸载入口，并收敛显示逻辑。

## 2026-03-10 00:03:01 +0800 — `026bcc4` `Fix ps1 parity and update shell behavior/docs`
- 操作：
  - 新增 `switch-provider.ps1`。
  - 新增 `.editorconfig`、`.gitattributes`。
  - 补齐 PowerShell 侧的安装、切换和文档说明。
- 设置方法：
  - `pwsh -NoProfile -File .\\switch-provider.ps1 status`
  - `pwsh -NoProfile -File .\\switch-provider.ps1 list`
  - `pwsh -NoProfile -File .\\switch-provider.ps1 install`
- 遇到的问题：
  - Bash/Zsh 和 PowerShell 之间存在功能不对齐。
- 解决方法：
  - 增加 PowerShell 实现，并把 README 改成双端文档。

## 2026-03-10 19:13:36 +0800 — `d5cf0be` `Fix curl probe compatibility and default timeout`
- 操作：
  - 调整 Bash 和 PowerShell 下的连通性探测细节。
  - 更新默认超时与探测兼容性说明。
- 设置方法：
  - 可选环境变量：`SP_PROBE_CONNECT_TIMEOUT`、`SP_PROBE_MAX_TIME`
- 遇到的问题：
  - 某些 provider 的探测在默认实现下兼容性一般，超时体验不稳定。
- 解决方法：
  - 修正 `curl` 探测参数与超时策略，并同步 README / PowerShell 行为。

## 2026-03-12 14:40:29 +0800 — `dc1c0f3` `Stream profile probes in list output`
- 操作：
  - `sp` / `sp status` 输出改为：`profile`、`status`、`latency`、`model`、`time`。
  - `sp list` 输出改为：`profile`、`state`、`model`、`latency`。
  - `sp list` 实现并发探测、按完成先后流式输出。
  - README 同步更新。
- 设置方法：
  - `sp`
  - `sp status`
  - `sp list`
- 遇到的问题：
  - 原 `list` 是串行输出，profile 多时可能长时间无响应。
  - 开发中出现 Bash 错误：`w_profile=${#"PROFILE"}: bad substitution`。
- 解决方法：
  - 用临时目录 + 后台任务 + 完成文件轮询做流式输出。
  - 将列宽初始化改为先定义 header 变量，再使用 `${#var}` 计算长度。

## 2026-03-12 当前工作区变更（未提交）
- 操作：
  - 新增 `changlog.md`，把仓库内外历史操作、设置方法、问题和解决方法汇总到一个文件。
  - 新增 `AGENTS.md`，要求之后每次修改都必须同步记录到 `changlog.md`。
- 设置方法：
  - 后续每次修改完成后，必须同步更新本文件。
- 遇到的问题：
  - 仓库之前没有持续性的过程记录规范，历史信息容易散落在会话或提交里。
- 解决方法：
  - 用 `changlog.md` 做统一变更台账，并在 `AGENTS.md` 固化要求。
