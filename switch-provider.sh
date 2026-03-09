#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PROFILES_DIR="${CODEX_PROFILES_DIR:-$CODEX_HOME/config}"
AUTH_FILE="$CODEX_HOME/auth.json"
CONFIG_FILE="$CODEX_HOME/config.toml"
BACKUP_ROOT="$PROFILES_DIR/_backup"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") list
  $(basename "$0") status
  $(basename "$0") save <profile>
  $(basename "$0") import <profile> <auth-file> <config-file>
  $(basename "$0") use <profile>
  $(basename "$0") <profile>
  $(basename "$0") help

Profile layout:
  $PROFILES_DIR/<profile>/auth.json
  $PROFILES_DIR/<profile>/config.toml

Examples:
  $(basename "$0") save api111
  $(basename "$0") import cliproxy ~/.codex/auth_cliproxy.json ~/.codex/config_cliproxy.toml
  $(basename "$0") list
  $(basename "$0") cliproxy
EOF
}

err() {
  echo "Error: $*" >&2
  exit 1
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
    *)
      [[ $# -eq 1 ]] || err "Unknown command: $command"
      cmd_use "$command"
      ;;
  esac
}

main "$@"
