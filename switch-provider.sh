#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PROFILES_DIR="${CODEX_PROFILES_DIR:-$CODEX_HOME/config}"
AUTH_FILE="$CODEX_HOME/auth.json"
CONFIG_FILE="$CODEX_HOME/config.toml"
BACKUP_ROOT="$PROFILES_DIR/_backup"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANAGED_BEGIN="# >>> SwitchCodex >>>"
MANAGED_END="# <<< SwitchCodex <<<"

ENV_PROFILE=""
ENV_PROVIDER=""
ENV_MODEL=""
ENV_BASE_URL=""
ENV_API_KEY=""
ENV_AUTH_MODE=""

usage() {
  cat <<EOF2
Usage:
  $(basename "$0") list
  $(basename "$0") status
  $(basename "$0") save <profile>
  $(basename "$0") import <profile> <auth-file> <config-file>
  $(basename "$0") use <profile>
  $(basename "$0") set [profile]
  $(basename "$0") unset
  $(basename "$0") install-shell [rc-file]
  $(basename "$0") <profile>
  $(basename "$0") help

Profile layout:
  $PROFILES_DIR/<profile>/auth.json
  $PROFILES_DIR/<profile>/config.toml

Examples:
  $(basename "$0") save api111
  $(basename "$0") import cliproxy ~/.codex/auth_cliproxy.json ~/.codex/config_cliproxy.toml
  $(basename "$0") install-shell ~/.zshrc
  $(basename "$0") set cliproxy
  $(basename "$0") unset
  $(basename "$0") list
  $(basename "$0") cliproxy
EOF2
}

err() {
  echo "Error: $*" >&2
  exit 1
}

note() {
  echo "$*" >&2
}

validate_profile_name() {
  local profile="$1"
  [[ -n "$profile" ]] || err "Profile name cannot be empty"
  [[ "$profile" =~ ^[A-Za-z0-9._-]+$ ]] || err "Invalid profile name: $profile"
  [[ "$profile" != _backup ]] || err "Profile name _backup is reserved"
}

ensure_profiles_dir() {
  mkdir -p "$PROFILES_DIR"
}

profile_dir() {
  echo "$PROFILES_DIR/$1"
}

profile_auth() {
  echo "$PROFILES_DIR/$1/auth.json"
}

profile_config() {
  echo "$PROFILES_DIR/$1/config.toml"
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || err "Missing file: $file"
}

read_provider() {
  local config_path="$1"
  if [[ ! -f "$config_path" ]]; then
    echo "missing"
    return 0
  fi

  local provider
  provider="$(sed -nE 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' "$config_path" | head -n 1)"
  echo "${provider:-unknown}"
}

copy_resolved() {
  local source_file="$1"
  local target_file="$2"
  local target_dir
  local temp_file

  target_dir="$(dirname "$target_file")"
  mkdir -p "$target_dir"
  temp_file="$target_file.tmp.$$"

  cp -fL "$source_file" "$temp_file"
  mv -f "$temp_file" "$target_file"
}

active_profile() {
  if [[ -L "$AUTH_FILE" && -L "$CONFIG_FILE" ]]; then
    local auth_target config_target auth_dir config_dir
    auth_target="$(readlink "$AUTH_FILE")"
    config_target="$(readlink "$CONFIG_FILE")"
    auth_dir="$(dirname "$auth_target")"
    config_dir="$(dirname "$config_target")"

    if [[ "$auth_dir" == "$config_dir" && "$auth_dir" == "$PROFILES_DIR"/* ]]; then
      basename "$auth_dir"
      return 0
    fi
  fi

  return 1
}

backup_current_top_level_files() {
  local timestamp backup_dir backed_up=0
  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$BACKUP_ROOT/$timestamp"

  if [[ -f "$AUTH_FILE" && ! -L "$AUTH_FILE" ]]; then
    mkdir -p "$backup_dir"
    cp -fp "$AUTH_FILE" "$backup_dir/auth.json"
    backed_up=1
  fi

  if [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]]; then
    mkdir -p "$backup_dir"
    cp -fp "$CONFIG_FILE" "$backup_dir/config.toml"
    backed_up=1
  fi

  if [[ "$backed_up" -eq 1 ]]; then
    echo "$backup_dir"
  fi
}

default_rc_file() {
  local shell_name
  shell_name="$(basename "${SHELL:-}")"

  case "$shell_name" in
    zsh)
      echo "$HOME/.zshrc"
      ;;
    bash)
      echo "$HOME/.bashrc"
      ;;
    *)
      echo "$HOME/.profile"
      ;;
  esac
}

shell_block() {
  cat <<EOF2
$MANAGED_BEGIN
export SWITCH_CODEX_HOME="$SCRIPT_DIR"
case ":\$PATH:" in
  *":\$SWITCH_CODEX_HOME:"*) ;;
  *) export PATH="\$SWITCH_CODEX_HOME:\$PATH" ;;
esac
sp() {
  local output exit_code subcommand
  subcommand="\${1:-status}"
  if [ "\$subcommand" = "set" ] || [ "\$subcommand" = "unset" ]; then
    output="\$(switch-provider.sh "\$@")"
    exit_code=\$?
    if [ \$exit_code -eq 0 ] && [ -n "\$output" ]; then
      eval "\$output"
    fi
    return \$exit_code
  fi
  switch-provider.sh "\$@"
}
$MANAGED_END
EOF2
}

write_managed_shell_block() {
  local rc_file="$1"
  local tmp_file
  local rc_dir

  rc_dir="$(dirname "$rc_file")"
  mkdir -p "$rc_dir"
  tmp_file="$rc_file.tmp.$$"

  if [[ -f "$rc_file" ]]; then
    awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
      $0 == begin { skipping = 1; next }
      $0 == end { skipping = 0; next }
      !skipping { print }
    ' "$rc_file" > "$tmp_file"
  else
    : > "$tmp_file"
  fi

  if [[ -s "$tmp_file" ]]; then
    printf '\n' >> "$tmp_file"
  fi

  shell_block >> "$tmp_file"
  mv -f "$tmp_file" "$rc_file"
}

shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys
print(shlex.quote(sys.argv[1]))
PY
}

prompt_yes_no() {
  local prompt="$1"
  local answer normalized

  while true; do
    printf '%s [yes/no]: ' "$prompt" >&2
    if ! IFS= read -r answer; then
      echo "Cancelled." >&2
      return 1
    fi

    normalized="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
      y|yes)
        return 0
        ;;
      n|no|'')
        echo "Cancelled." >&2
        return 1
        ;;
      *)
        echo "Please answer yes or no." >&2
        ;;
    esac
  done
}

resolve_profile_for_env() {
  local profile="${1:-}"
  local current_profile_value=""

  if [[ -n "$profile" ]]; then
    validate_profile_name "$profile"
    echo "$profile"
    return 0
  fi

  current_profile_value="$(active_profile || true)"
  [[ -n "$current_profile_value" ]] || err "No profile specified and current auth/config are not linked to a profile"
  echo "$current_profile_value"
}

load_profile_env() {
  local profile="$1"
  local auth_path config_path

  validate_profile_name "$profile"
  auth_path="$(profile_auth "$profile")"
  config_path="$(profile_config "$profile")"
  require_file "$auth_path"
  require_file "$config_path"

  ENV_PROFILE="$profile"
  ENV_PROVIDER=""
  ENV_MODEL=""
  ENV_BASE_URL=""
  ENV_API_KEY=""
  ENV_AUTH_MODE=""

  while IFS=$'\t' read -r key value; do
    case "$key" in
      provider)
        ENV_PROVIDER="$value"
        ;;
      model)
        ENV_MODEL="$value"
        ;;
      base_url)
        ENV_BASE_URL="$value"
        ;;
      api_key)
        ENV_API_KEY="$value"
        ;;
      auth_mode)
        ENV_AUTH_MODE="$value"
        ;;
    esac
  done < <(
    python3 - "$config_path" "$auth_path" <<'PY'
import json
import sys
import tomllib

config_path, auth_path = sys.argv[1:3]
with open(config_path, 'rb') as config_file:
    config = tomllib.load(config_file)
with open(auth_path, 'r', encoding='utf-8') as auth_file:
    auth = json.load(auth_file)

provider = config.get('model_provider') or ''
model = config.get('model') or ''
provider_cfg = (config.get('model_providers') or {}).get(provider, {}) if provider else {}
base_url = provider_cfg.get('base_url') or ''
api_key = auth.get('OPENAI_API_KEY')
auth_mode = auth.get('auth_mode') or ''

items = {
    'provider': provider,
    'model': model,
    'base_url': base_url,
    'api_key': '' if api_key in (None, '') else str(api_key),
    'auth_mode': auth_mode,
}
for key, value in items.items():
    print(f"{key}\t{value}")
PY
  )

  [[ -n "$ENV_PROVIDER" ]] || err "Could not read model_provider from $config_path"
}

emit_backup_var() {
  local var_name="$1"
  cat <<EOF2
if [ "\${$var_name+x}" = x ]; then
  export SWITCH_CODEX_PREV_${var_name}_SET=1
  export SWITCH_CODEX_PREV_${var_name}="\${$var_name}"
else
  export SWITCH_CODEX_PREV_${var_name}_SET=0
  unset SWITCH_CODEX_PREV_${var_name}
fi
EOF2
}

emit_restore_var() {
  local var_name="$1"
  cat <<EOF2
if [ "\${SWITCH_CODEX_PREV_${var_name}_SET:-0}" = 1 ]; then
  export ${var_name}="\${SWITCH_CODEX_PREV_${var_name}}"
else
  unset ${var_name}
fi
unset SWITCH_CODEX_PREV_${var_name}
unset SWITCH_CODEX_PREV_${var_name}_SET
EOF2
}

emit_export_or_unset() {
  local var_name="$1"
  local value="${2:-}"

  if [[ -n "$value" ]]; then
    printf 'export %s=%s\n' "$var_name" "$(shell_quote "$value")"
  else
    printf 'unset %s\n' "$var_name"
  fi
}

emit_set_shell() {
  emit_backup_var "OPENAI_API_KEY"
  emit_backup_var "OPENAI_BASE_URL"
  emit_backup_var "OPENAI_MODEL"

  echo "export SWITCH_CODEX_ENV_ACTIVE=1"
  printf 'export SWITCH_CODEX_ACTIVE_PROFILE=%s\n' "$(shell_quote "$ENV_PROFILE")"
  printf 'export SWITCH_CODEX_ACTIVE_PROVIDER=%s\n' "$(shell_quote "$ENV_PROVIDER")"
  printf 'export SWITCH_CODEX_ACTIVE_MODEL=%s\n' "$(shell_quote "$ENV_MODEL")"
  printf 'export SWITCH_CODEX_ACTIVE_BASE_URL=%s\n' "$(shell_quote "$ENV_BASE_URL")"
  printf 'export SWITCH_CODEX_ACTIVE_AUTH_MODE=%s\n' "$(shell_quote "$ENV_AUTH_MODE")"

  emit_export_or_unset "OPENAI_API_KEY" "$ENV_API_KEY"
  emit_export_or_unset "OPENAI_BASE_URL" "$ENV_BASE_URL"
  emit_export_or_unset "OPENAI_MODEL" "$ENV_MODEL"
}

emit_unset_shell() {
  emit_restore_var "OPENAI_API_KEY"
  emit_restore_var "OPENAI_BASE_URL"
  emit_restore_var "OPENAI_MODEL"
  echo "unset SWITCH_CODEX_ENV_ACTIVE"
  echo "unset SWITCH_CODEX_ACTIVE_PROFILE"
  echo "unset SWITCH_CODEX_ACTIVE_PROVIDER"
  echo "unset SWITCH_CODEX_ACTIVE_MODEL"
  echo "unset SWITCH_CODEX_ACTIVE_BASE_URL"
  echo "unset SWITCH_CODEX_ACTIVE_AUTH_MODE"
}

cmd_list() {
  ensure_profiles_dir

  local current_profile=""
  current_profile="$(active_profile || true)"

  printf '%-18s %-14s %s\n' 'PROFILE' 'PROVIDER' 'STATE'

  local found=0
  local dir base provider state
  for dir in "$PROFILES_DIR"/*; do
    [[ -d "$dir" ]] || continue
    base="$(basename "$dir")"
    [[ "$base" == "_backup" ]] && continue
    found=1

    state="ready"
    [[ -f "$dir/auth.json" ]] || state="missing-auth"
    [[ -f "$dir/config.toml" ]] || state="missing-config"
    if [[ ! -f "$dir/auth.json" && ! -f "$dir/config.toml" ]]; then
      state="empty"
    fi
    if [[ "$base" == "$current_profile" ]]; then
      state="active"
    fi

    provider="$(read_provider "$dir/config.toml")"
    printf '%-18s %-14s %s\n' "$base" "$provider" "$state"
  done

  if [[ "$found" -eq 0 ]]; then
    echo "(no profiles under $PROFILES_DIR)"
  fi
}

cmd_status() {
  local current_provider current_profile_value
  current_provider="$(read_provider "$CONFIG_FILE")"

  echo "codex_home: $CODEX_HOME"
  echo "profiles_dir: $PROFILES_DIR"
  echo "current_provider: $current_provider"

  current_profile_value="$(active_profile || true)"
  if [[ -n "$current_profile_value" ]]; then
    echo "active_profile: $current_profile_value"
    echo "auth_source: $(readlink "$AUTH_FILE")"
    echo "config_source: $(readlink "$CONFIG_FILE")"
  else
    echo "active_profile: manual"
    echo "auth_source: $AUTH_FILE"
    echo "config_source: $CONFIG_FILE"
  fi
}

cmd_save() {
  local profile="$1"
  validate_profile_name "$profile"
  ensure_profiles_dir
  require_file "$AUTH_FILE"
  require_file "$CONFIG_FILE"

  local dir
  dir="$(profile_dir "$profile")"
  mkdir -p "$dir"

  copy_resolved "$AUTH_FILE" "$dir/auth.json"
  copy_resolved "$CONFIG_FILE" "$dir/config.toml"
  chmod 600 "$dir/auth.json" "$dir/config.toml" 2>/dev/null || true

  echo "Saved current auth/config to profile '$profile'"
  echo "  $dir/auth.json"
  echo "  $dir/config.toml"
}

cmd_import() {
  local profile="$1"
  local source_auth="$2"
  local source_config="$3"

  validate_profile_name "$profile"
  ensure_profiles_dir
  require_file "$source_auth"
  require_file "$source_config"

  local dir
  dir="$(profile_dir "$profile")"
  mkdir -p "$dir"

  copy_resolved "$source_auth" "$dir/auth.json"
  copy_resolved "$source_config" "$dir/config.toml"
  chmod 600 "$dir/auth.json" "$dir/config.toml" 2>/dev/null || true

  echo "Imported profile '$profile'"
  echo "  auth   <- $source_auth"
  echo "  config <- $source_config"
}

cmd_use() {
  local profile="$1"
  validate_profile_name "$profile"
  ensure_profiles_dir

  local target_auth target_config backup_dir current_profile_value
  target_auth="$(profile_auth "$profile")"
  target_config="$(profile_config "$profile")"
  require_file "$target_auth"
  require_file "$target_config"

  current_profile_value="$(active_profile || true)"
  if [[ "$current_profile_value" == "$profile" ]]; then
    echo "Profile '$profile' is already active"
    return 0
  fi

  backup_dir="$(backup_current_top_level_files || true)"

  ln -sfn "$target_auth" "$AUTH_FILE"
  ln -sfn "$target_config" "$CONFIG_FILE"

  echo "Switched to profile '$profile'"
  echo "  auth   -> $target_auth"
  echo "  config -> $target_config"
  if [[ -n "$backup_dir" ]]; then
    echo "Backed up previous top-level files to $backup_dir"
  fi
}

cmd_set() {
  local requested_profile="${1:-}"
  local profile
  profile="$(resolve_profile_for_env "$requested_profile")"
  load_profile_env "$profile"

  if ! prompt_yes_no "Set env for profile '$ENV_PROFILE' (provider=$ENV_PROVIDER, model=${ENV_MODEL:-unset}, OPENAI_API_KEY=$([[ -n "$ENV_API_KEY" ]] && echo present || echo unset))?"; then
    return 1
  fi

  emit_set_shell
  note "Prepared environment exports for '$ENV_PROFILE'."
}

cmd_unset() {
  if ! prompt_yes_no "Restore or unset the SwitchCodex environment variables?"; then
    return 1
  fi

  emit_unset_shell
  note "Prepared environment cleanup."
}

cmd_install_shell() {
  local rc_file="${1:-$(default_rc_file)}"
  write_managed_shell_block "$rc_file"

  echo "Installed shell integration"
  echo "  rc_file  -> $rc_file"
  echo "  path     -> $SCRIPT_DIR"
  echo "  command  -> sp"
  echo "  env flow -> sp set [profile] / sp unset"
  echo "Run: source $rc_file"
}

main() {
  local command="${1:-status}"

  case "$command" in
    help|-h|--help)
      usage
      ;;
    list)
      cmd_list
      ;;
    status)
      cmd_status
      ;;
    save)
      [[ $# -eq 2 ]] || err "Usage: $(basename "$0") save <profile>"
      cmd_save "$2"
      ;;
    import)
      [[ $# -eq 4 ]] || err "Usage: $(basename "$0") import <profile> <auth-file> <config-file>"
      cmd_import "$2" "$3" "$4"
      ;;
    use)
      [[ $# -eq 2 ]] || err "Usage: $(basename "$0") use <profile>"
      cmd_use "$2"
      ;;
    set)
      [[ $# -le 2 ]] || err "Usage: $(basename "$0") set [profile]"
      cmd_set "${2:-}"
      ;;
    unset)
      [[ $# -eq 1 ]] || err "Usage: $(basename "$0") unset"
      cmd_unset
      ;;
    install-shell)
      [[ $# -le 2 ]] || err "Usage: $(basename "$0") install-shell [rc-file]"
      cmd_install_shell "${2:-}"
      ;;
    *)
      [[ $# -eq 1 ]] || err "Unknown command: $command"
      cmd_use "$command"
      ;;
  esac
}

main "$@"
