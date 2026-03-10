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
PROBE_STATUS=""
PROBE_DETAIL=""
PROBE_LATENCY=""
PROBE_HTTP_CODE=""

COLOR_ENABLED=0
CLR_RESET=""
CLR_BOLD=""
CLR_DIM=""
CLR_RED=""
CLR_GREEN=""
CLR_YELLOW=""
CLR_BLUE=""
CLR_CYAN=""

usage() {
  cat <<EOF2
Usage:
  $(basename "$0") list
  $(basename "$0") status
  $(basename "$0") save <profile>
  $(basename "$0") import <profile> <auth-file> <config-file>
  $(basename "$0") use <profile>
  $(basename "$0") install [rc-file]
  $(basename "$0") uninstall [rc-file]
  $(basename "$0") <profile>
  $(basename "$0") help

Profile layout:
  $PROFILES_DIR/<profile>/auth.json
  $PROFILES_DIR/<profile>/config.toml

Examples:
  $(basename "$0") save api111
  $(basename "$0") import cliproxy ~/.codex/auth_cliproxy.json ~/.codex/config_cliproxy.toml
  $(basename "$0") install ~/.zshrc
  $(basename "$0") uninstall ~/.zshrc
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

init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    COLOR_ENABLED=1
    CLR_RESET=$'\033[0m'
    CLR_BOLD=$'\033[1m'
    CLR_DIM=$'\033[2m'
    CLR_RED=$'\033[31m'
    CLR_GREEN=$'\033[32m'
    CLR_YELLOW=$'\033[33m'
    CLR_BLUE=$'\033[34m'
    CLR_CYAN=$'\033[36m'
  fi
}

paint() {
  local color="$1"
  local text="$2"
  if [[ "$COLOR_ENABLED" -eq 1 ]]; then
    printf '%b%s%b' "$color" "$text" "$CLR_RESET"
  else
    printf '%s' "$text"
  fi
}

print_plain_padded() {
  local text="$1"
  local width="$2"
  printf '%s' "$text"
  if (( width > ${#text} )); then
    printf '%*s' "$((width - ${#text}))" ""
  fi
}

print_colored_padded() {
  local color="$1"
  local text="$2"
  local width="$3"
  paint "$color" "$text"
  if (( width > ${#text} )); then
    printf '%*s' "$((width - ${#text}))" ""
  fi
}

color_for_file_state() {
  case "$1" in
    active|ready)
      printf '%s' "$CLR_GREEN"
      ;;
    missing-auth|missing-config)
      printf '%s' "$CLR_YELLOW"
      ;;
    empty)
      printf '%s' "$CLR_RED"
      ;;
    *)
      printf '%s' "$CLR_DIM"
      ;;
  esac
}

color_for_probe_state() {
  case "$1" in
    online)
      printf '%s' "$CLR_GREEN"
      ;;
    auth-failed|missing-key|endpoint-mismatch|rate-limited)
      printf '%s' "$CLR_YELLOW"
      ;;
    timeout|unreachable|server-error|curl-error|no-base-url)
      printf '%s' "$CLR_RED"
      ;;
    *)
      printf '%s' "$CLR_DIM"
      ;;
  esac
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

read_connection_fields() {
  local config_path="$1"
  local auth_path="$2"
  python3 - "$config_path" "$auth_path" <<'PY'
import json
import re
import sys

try:
    import tomllib  # py311+
except Exception:
    tomllib = None

config_path, auth_path = sys.argv[1:3]
provider = ""
base_url = ""
api_key = ""

try:
    if tomllib is not None:
        with open(config_path, "rb") as f:
            config = tomllib.load(f)
        provider = config.get("model_provider") or ""
        provider_cfg = (config.get("model_providers") or {}).get(provider, {}) if provider else {}
        if isinstance(provider_cfg, dict):
            base_url = str(provider_cfg.get("base_url") or "")
    else:
        with open(config_path, "r", encoding="utf-8") as f:
            text = f.read()
        provider_match = re.search(r'^\s*model_provider\s*=\s*"([^"]+)"', text, re.MULTILINE)
        if provider_match:
            provider = provider_match.group(1)
        if provider:
            in_section = False
            section = f"[model_providers.{provider}]"
            for raw_line in text.splitlines():
                line = raw_line.strip()
                if line.startswith("[") and line.endswith("]"):
                    in_section = (line == section)
                    continue
                if in_section:
                    base_match = re.match(r'^\s*base_url\s*=\s*"([^"]+)"', raw_line)
                    if base_match:
                        base_url = base_match.group(1)
                        break
except Exception:
    pass

try:
    with open(auth_path, "r", encoding="utf-8") as f:
        auth = json.load(f)
    value = auth.get("OPENAI_API_KEY")
    api_key = "" if value in (None, "") else str(value)
except Exception:
    pass

print(f"provider\t{provider}")
print(f"base_url\t{base_url}")
print(f"api_key\t{api_key}")
PY
}

probe_connection_quick() {
  local base_url="${1:-}"
  local api_key="${2:-}"
  local probe_max_time_override="${3:-}"
  local probe_connect_timeout="${SP_PROBE_CONNECT_TIMEOUT:-0.8}"
  local probe_max_time="${probe_max_time_override:-${SP_PROBE_MAX_TIME:-3}}"

  PROBE_STATUS="skipped"
  PROBE_DETAIL="-"
  PROBE_LATENCY="-"
  PROBE_HTTP_CODE="-"

  if [[ -z "$base_url" ]]; then
    PROBE_STATUS="no-base-url"
    PROBE_DETAIL="base_url missing"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    PROBE_STATUS="curl-error"
    PROBE_DETAIL="curl not found"
    return 0
  fi

  local probe_url raw exit_code http_code time_total err_msg err_file
  local -a curl_args
  probe_url="${base_url%/}/models"
  err_file="$(mktemp "${TMPDIR:-/tmp}/switchcodex-curl-stderr.XXXXXX")"
  curl_args=(
    -sS
    -o /dev/null
    --connect-timeout "$probe_connect_timeout"
    --max-time "$probe_max_time"
    -w $'%{http_code}\t%{time_total}'
  )
  if [[ -n "$api_key" ]]; then
    curl_args+=(-H "Authorization: Bearer $api_key")
  fi
  curl_args+=("$probe_url")

  set +e
  raw="$(curl "${curl_args[@]}" 2>"$err_file")"
  exit_code=$?
  set -e

  if [[ -s "$err_file" ]]; then
    err_msg="$(tr '\r\n' '  ' < "$err_file" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  fi
  rm -f "$err_file"

  IFS=$'\t' read -r http_code time_total <<< "$raw"
  http_code="${http_code:-000}"
  PROBE_HTTP_CODE="$http_code"

  if [[ -n "$time_total" ]]; then
    PROBE_LATENCY="$(awk -v t="$time_total" 'BEGIN { printf "%.0fms", t * 1000 }')"
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    case "$exit_code" in
      28)
        PROBE_STATUS="timeout"
        PROBE_DETAIL="probe timeout"
        ;;
      6|7)
        PROBE_STATUS="unreachable"
        PROBE_DETAIL="dns/connect failed"
        ;;
      *)
        PROBE_STATUS="curl-error"
        PROBE_DETAIL="curl exit $exit_code"
        ;;
    esac
    [[ -n "$err_msg" ]] && PROBE_DETAIL="$err_msg"
    return 0
  fi

  case "$http_code" in
    2??|3??)
      PROBE_STATUS="online"
      PROBE_DETAIL="HTTP $http_code"
      ;;
    401|403)
      if [[ -z "$api_key" ]]; then
        PROBE_STATUS="missing-key"
        PROBE_DETAIL="HTTP $http_code (no key)"
      else
        PROBE_STATUS="auth-failed"
        PROBE_DETAIL="HTTP $http_code"
      fi
      ;;
    404)
      PROBE_STATUS="endpoint-mismatch"
      PROBE_DETAIL="HTTP 404 /models"
      ;;
    429)
      PROBE_STATUS="rate-limited"
      PROBE_DETAIL="HTTP 429"
      ;;
    5??)
      PROBE_STATUS="server-error"
      PROBE_DETAIL="HTTP $http_code"
      ;;
    *)
      PROBE_STATUS="http-$http_code"
      PROBE_DETAIL="HTTP $http_code"
      ;;
  esac
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

remove_managed_shell_block() {
  local rc_file="$1"
  local tmp_file
  [[ -f "$rc_file" ]] || return 0
  tmp_file="$rc_file.tmp.$$"

  awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
    $0 == begin { skipping = 1; next }
    $0 == end { skipping = 0; next }
    !skipping { print }
  ' "$rc_file" > "$tmp_file"
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
import re
import sys

try:
    import tomllib  # py311+
except Exception:
    tomllib = None

config_path, auth_path = sys.argv[1:3]
config = {}
if tomllib is not None:
    with open(config_path, 'rb') as config_file:
        config = tomllib.load(config_file)
else:
    with open(config_path, 'r', encoding='utf-8') as config_file:
        text = config_file.read()
    provider_match = re.search(r'^\s*model_provider\s*=\s*"([^"]+)"', text, re.MULTILINE)
    provider = provider_match.group(1) if provider_match else ''
    provider_cfg = {}
    if provider:
        in_section = False
        section = f"[model_providers.{provider}]"
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if line.startswith("[") and line.endswith("]"):
                in_section = (line == section)
                continue
            if in_section:
                base_match = re.match(r'^\s*base_url\s*=\s*"([^"]+)"', raw_line)
                if base_match:
                    provider_cfg["base_url"] = base_match.group(1)
                    break
    config = {
        'model_provider': provider,
        'model_providers': {provider: provider_cfg} if provider else {}
    }
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
  init_colors

  local current_profile=""
  current_profile="$(active_profile || true)"

  local found=0
  local dir base provider state probe_status probe_detail probe_latency row
  local base_url="" api_key=""
  local has_auth=0 has_config=0
  local -a normal_rows=()
  local active_row=""

  local h_profile="PROFILE"
  local h_provider="PROVIDER"
  local h_state="FILE_STATE"
  local h_connect="CONNECT"
  local h_latency="LATENCY"
  local h_detail="DETAIL"
  local w_profile=${#h_profile}
  local w_provider=${#h_provider}
  local w_state=${#h_state}
  local w_connect=${#h_connect}
  local w_latency=${#h_latency}

  for dir in "$PROFILES_DIR"/*; do
    [[ -d "$dir" ]] || continue
    base="$(basename "$dir")"
    [[ "$base" == "_backup" ]] && continue
    found=1

    state="ready"
    has_auth=0
    has_config=0
    [[ -f "$dir/auth.json" ]] && has_auth=1
    [[ -f "$dir/config.toml" ]] && has_config=1
    [[ "$has_auth" -eq 1 ]] || state="missing-auth"
    [[ "$has_config" -eq 1 ]] || state="missing-config"
    if [[ "$has_auth" -eq 0 && "$has_config" -eq 0 ]]; then
      state="empty"
    fi
    if [[ "$base" == "$current_profile" ]]; then
      state="active"
    fi

    provider="$(read_provider "$dir/config.toml")"
    base_url=""
    api_key=""
    probe_status="skipped"
    probe_detail="-"
    probe_latency="-"

    if [[ "$has_auth" -eq 1 && "$has_config" -eq 1 ]]; then
      while IFS=$'\t' read -r key value; do
        case "$key" in
          base_url)
            base_url="$value"
            ;;
          api_key)
            api_key="$value"
            ;;
        esac
      done < <(read_connection_fields "$dir/config.toml" "$dir/auth.json")

      probe_connection_quick "$base_url" "$api_key" "3"
      probe_status="$PROBE_STATUS"
      probe_detail="$PROBE_DETAIL"
      probe_latency="$PROBE_LATENCY"
    fi

    row="${base}"$'\t'"${provider}"$'\t'"${state}"$'\t'"${probe_status}"$'\t'"${probe_latency}"$'\t'"${probe_detail}"
    if [[ "$state" == "active" ]]; then
      active_row="$row"
    else
      normal_rows+=("$row")
    fi

    (( ${#base} > w_profile )) && w_profile=${#base}
    (( ${#provider} > w_provider )) && w_provider=${#provider}
    (( ${#state} > w_state )) && w_state=${#state}
    (( ${#probe_status} > w_connect )) && w_connect=${#probe_status}
    (( ${#probe_latency} > w_latency )) && w_latency=${#probe_latency}
  done

  if [[ "$found" -eq 0 ]]; then
    echo "(no profiles under $PROFILES_DIR)"
    return 0
  fi

  local header_line=""
  header_line="$(printf "%-*s  %-*s  %-*s  %-*s  %-*s  %s" \
    "$w_profile" "$h_profile" \
    "$w_provider" "$h_provider" \
    "$w_state" "$h_state" \
    "$w_connect" "$h_connect" \
    "$w_latency" "$h_latency" \
    "$h_detail")"
  if [[ "$COLOR_ENABLED" -eq 1 ]]; then
    paint "${CLR_BOLD}${CLR_CYAN}" "$header_line"
    printf '\n'
  else
    echo "$header_line"
  fi

  local -a rows=()
  if [[ -n "$active_row" ]]; then
    rows+=("$active_row")
  fi
  for row in "${normal_rows[@]}"; do
    rows+=("$row")
  done

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r base provider state probe_status probe_latency probe_detail <<< "$row"
    print_plain_padded "$base" "$w_profile"
    printf '  '
    print_plain_padded "$provider" "$w_provider"
    printf '  '
    print_colored_padded "$(color_for_file_state "$state")" "$state" "$w_state"
    printf '  '
    print_colored_padded "$(color_for_probe_state "$probe_status")" "$probe_status" "$w_connect"
    printf '  '
    print_colored_padded "$CLR_BLUE" "$probe_latency" "$w_latency"
    printf '  '
    paint "$CLR_DIM" "$probe_detail"
    printf '\n'
  done
}

cmd_status() {
  init_colors

  local current_provider
  local current_base_url="" current_api_key=""
  local probe_status="missing-files"
  local probe_latency="-"
  current_provider="$(read_provider "$CONFIG_FILE")"

  if [[ -f "$CONFIG_FILE" && -f "$AUTH_FILE" ]]; then
    while IFS=$'\t' read -r key value; do
      case "$key" in
        base_url)
          current_base_url="$value"
          ;;
        api_key)
          current_api_key="$value"
          ;;
      esac
    done < <(read_connection_fields "$CONFIG_FILE" "$AUTH_FILE")
    probe_connection_quick "$current_base_url" "$current_api_key"
    probe_status="$PROBE_STATUS"
    probe_latency="$PROBE_LATENCY"
  fi

  paint "${CLR_BOLD}${CLR_CYAN}" "status"
  printf ': '
  paint "$(color_for_probe_state "$probe_status")" "$probe_status"
  printf '\n'
  paint "${CLR_BOLD}${CLR_CYAN}" "latency"
  printf ': '
  paint "$CLR_BLUE" "$probe_latency"
  printf '\n'
  paint "${CLR_BOLD}${CLR_CYAN}" "provider"
  echo ": $current_provider"
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

cmd_install() {
  local rc_file="${1:-$(default_rc_file)}"
  init_colors
  write_managed_shell_block "$rc_file"

  if grep -Fq "$MANAGED_BEGIN" "$rc_file" && grep -Fq "$MANAGED_END" "$rc_file"; then
    paint "$CLR_GREEN" "Install success"
    printf '\n'
  else
    paint "$CLR_RED" "Install failed"
    printf '\n'
    return 1
  fi

  echo "  rc_file -> $rc_file"
  echo "  path    -> $SCRIPT_DIR"
  echo "  command -> sp"
  paint "$CLR_CYAN" "Run: source $rc_file"
  printf '\n'
}

cmd_uninstall() {
  local rc_file="${1:-$(default_rc_file)}"
  init_colors
  remove_managed_shell_block "$rc_file"

  if [[ -f "$rc_file" ]] && (grep -Fq "$MANAGED_BEGIN" "$rc_file" || grep -Fq "$MANAGED_END" "$rc_file"); then
    paint "$CLR_RED" "Uninstall failed"
    printf '\n'
    return 1
  fi

  paint "$CLR_GREEN" "Uninstall success"
  printf '\n'
  echo "  rc_file -> $rc_file"
  paint "$CLR_CYAN" "Run: source $rc_file"
  printf '\n'
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
    install)
      [[ $# -le 2 ]] || err "Usage: $(basename "$0") install [rc-file]"
      cmd_install "${2:-}"
      ;;
    uninstall)
      [[ $# -le 2 ]] || err "Usage: $(basename "$0") uninstall [rc-file]"
      cmd_uninstall "${2:-}"
      ;;
    set|unset)
      err "Command '$command' has been removed"
      ;;
    *)
      [[ $# -eq 1 ]] || err "Unknown command: $command"
      cmd_use "$command"
      ;;
  esac
}

main "$@"
