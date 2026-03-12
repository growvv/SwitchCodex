#!/usr/bin/env bash
set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
PROFILES_DIR="${CLAUDE_PROFILES_DIR:-$CLAUDE_HOME/profiles}"
SETTINGS_FILE="$CLAUDE_HOME/settings.json"
BACKUP_ROOT="$PROFILES_DIR/_backup"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANAGED_BEGIN="# >>> SwitchClaude >>>"
MANAGED_END="# <<< SwitchClaude <<<"

CHECK_STATUS=""
CHECK_DETAIL=""
CHECK_LATENCY="-"
CHECK_HTTP_CODE="-"
CHECK_TIME="-"

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
  $(basename "$0")
  $(basename "$0") list
  $(basename "$0") status
  $(basename "$0") save <profile>
  $(basename "$0") import <profile> <settings-file>
  $(basename "$0") use <profile>
  $(basename "$0") install [rc-file]
  $(basename "$0") uninstall [rc-file]
  $(basename "$0") <profile>
  $(basename "$0") help

Profile layout:
  $PROFILES_DIR/<profile>/settings.json

Examples:
  $(basename "$0")
  $(basename "$0") save openrouter
  $(basename "$0") import lxy ~/.claude/settings_lxy.json
  $(basename "$0") list
  $(basename "$0") status
  $(basename "$0") use openrouter
  $(basename "$0") install ~/.zshrc
  $(basename "$0") openrouter
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

color_for_state() {
  case "$1" in
    online|active|ready)
      printf '%s' "$CLR_GREEN"
      ;;
    auth-failed|missing-key|endpoint-mismatch|rate-limited)
      printf '%s' "$CLR_YELLOW"
      ;;
    timeout|unreachable|server-error|curl-error|invalid|broken|no-base-url|missing)
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

profile_settings() {
  echo "$PROFILES_DIR/$1/settings.json"
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || err "Missing file: $file"
}

copy_resolved() {
  local source_file="$1"
  local target_file="$2"
  local temp_file
  mkdir -p "$(dirname "$target_file")"
  temp_file="$target_file.tmp.$$"
  cp -fL "$source_file" "$temp_file"
  mv -f "$temp_file" "$target_file"
}

active_profile() {
  if [[ -L "$SETTINGS_FILE" ]]; then
    local target resolved
    target="$(readlink "$SETTINGS_FILE")"
    if [[ "$target" != /* ]]; then
      resolved="$(cd -- "$(dirname -- "$SETTINGS_FILE")" && cd -- "$(dirname -- "$target")" && pwd)/$(basename -- "$target")"
    else
      resolved="$target"
    fi

    if [[ "$resolved" == "$PROFILES_DIR"/*/settings.json ]]; then
      basename "$(dirname "$resolved")"
      return 0
    fi
  fi

  return 1
}

backup_current_top_level_file() {
  local timestamp backup_dir
  if [[ -f "$SETTINGS_FILE" && ! -L "$SETTINGS_FILE" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$BACKUP_ROOT/$timestamp"
    mkdir -p "$backup_dir"
    cp -fp "$SETTINGS_FILE" "$backup_dir/settings.json"
    echo "$backup_dir"
  fi
}

default_rc_file() {
  case "$(basename "${SHELL:-}")" in
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
export SWITCH_CLAUDE_HOME="$SCRIPT_DIR"
case ":\$PATH:" in
  *":\$SWITCH_CLAUDE_HOME:"*) ;;
  *) export PATH="\$SWITCH_CLAUDE_HOME:\$PATH" ;;
esac
spcc() {
  switch-claude.sh "\$@"
}
$MANAGED_END
EOF2
}

write_managed_shell_block() {
  local rc_file="$1"
  local tmp_file

  mkdir -p "$(dirname "$rc_file")"
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

json_fields() {
  local settings_path="$1"
  python3 - "$settings_path" <<'PY'
import json
import sys

path = sys.argv[1]
state = "ready"
model = ""
base_url = ""
token_state = "missing"
api_key = ""

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("root must be object")
    model = str(data.get("model") or "")
    env = data.get("env") or {}
    if isinstance(env, dict):
        base_url = str(env.get("ANTHROPIC_BASE_URL") or "")
        token = env.get("ANTHROPIC_AUTH_TOKEN")
        if token not in (None, ""):
            token_state = "present"
            api_key = str(token)
except FileNotFoundError:
    state = "missing"
except Exception:
    state = "invalid"

print(f"state\t{state}")
print(f"model\t{model}")
print(f"base_url\t{base_url}")
print(f"token\t{token_state}")
print(f"api_key\t{api_key}")
PY
}

check_connection_quick() {
  local base_url="${1:-}"
  local api_key="${2:-}"
  local request_timeout="${3:-${SPCC_PROBE_MAX_TIME:-${SPC_TIMEOUT:-3}}}"
  local connect_timeout="${SPCC_PROBE_CONNECT_TIMEOUT:-0.8}"

  CHECK_STATUS="skipped"
  CHECK_DETAIL="-"
  CHECK_LATENCY="-"
  CHECK_HTTP_CODE="-"
  CHECK_TIME="$(date '+%Y-%m-%d %H:%M:%S %z')"

  if [[ -z "$base_url" ]]; then
    CHECK_STATUS="no-base-url"
    CHECK_DETAIL="base_url missing"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    CHECK_STATUS="curl-error"
    CHECK_DETAIL="curl not found"
    return 0
  fi

  local request_url raw exit_code http_code time_total err_msg="" err_file
  local -a curl_args
  request_url="${base_url%/}/models"
  err_file="$(mktemp "${TMPDIR:-/tmp}/switchclaude-curl-stderr.XXXXXX")"
  curl_args=(
    -sS
    -o /dev/null
    --connect-timeout "$connect_timeout"
    --max-time "$request_timeout"
    -w $'%{http_code}\t%{time_total}'
  )
  if [[ -n "$api_key" ]]; then
    curl_args+=(-H "Authorization: Bearer $api_key")
  fi
  curl_args+=("$request_url")

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
  CHECK_HTTP_CODE="$http_code"

  if [[ -n "$time_total" ]]; then
    CHECK_LATENCY="$(awk -v t="$time_total" 'BEGIN { printf "%.0fms", t * 1000 }')"
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    case "$exit_code" in
      28)
        CHECK_STATUS="timeout"
        CHECK_DETAIL="request timeout"
        ;;
      6|7)
        CHECK_STATUS="unreachable"
        CHECK_DETAIL="dns/connect failed"
        ;;
      *)
        CHECK_STATUS="curl-error"
        CHECK_DETAIL="curl exit $exit_code"
        ;;
    esac
    [[ -n "$err_msg" ]] && CHECK_DETAIL="$err_msg"
    return 0
  fi

  case "$http_code" in
    2??|3??)
      CHECK_STATUS="online"
      CHECK_DETAIL="HTTP $http_code"
      ;;
    401|403)
      if [[ -z "$api_key" ]]; then
        CHECK_STATUS="missing-key"
        CHECK_DETAIL="HTTP $http_code (no key)"
      else
        CHECK_STATUS="auth-failed"
        CHECK_DETAIL="HTTP $http_code"
      fi
      ;;
    404)
      CHECK_STATUS="endpoint-mismatch"
      CHECK_DETAIL="HTTP 404 /models"
      ;;
    429)
      CHECK_STATUS="rate-limited"
      CHECK_DETAIL="HTTP 429"
      ;;
    5??)
      CHECK_STATUS="server-error"
      CHECK_DETAIL="HTTP $http_code"
      ;;
    *)
      CHECK_STATUS="http-$http_code"
      CHECK_DETAIL="HTTP $http_code"
      ;;
  esac
}

current_settings_target() {
  if [[ -L "$SETTINGS_FILE" ]]; then
    local target
    target="$(readlink "$SETTINGS_FILE")"
    if [[ "$target" == /* ]]; then
      printf '%s\n' "$target"
    else
      (
        cd -- "$(dirname -- "$SETTINGS_FILE")"
        cd -- "$(dirname -- "$target")"
        printf '%s/%s\n' "$(pwd)" "$(basename -- "$target")"
      )
    fi
  else
    printf '%s\n' "$SETTINGS_FILE"
  fi
}

print_status_row() {
  local name="$1"
  local state="$2"
  local model="$3"
  local latency="$4"
  local active="$5"
  local w_profile="$6"
  local w_state="$7"
  local w_model="$8"
  local w_latency="$9"

  local name_label="$name"
  if [[ "$active" == "yes" ]]; then
    name_label="$name*"
  fi

  print_plain_padded "$name_label" "$w_profile"
  printf '  '
  print_colored_padded "$(color_for_state "$state")" "$state" "$w_state"
  printf '  '
  print_plain_padded "${model:--}" "$w_model"
  printf '  '
  print_colored_padded "$CLR_BLUE" "${latency:--}" "$w_latency"
  printf '\n'
}

print_list_header() {
  local w_profile="$1"
  local w_state="$2"
  local w_model="$3"
  local w_latency="$4"
  local header_line

  header_line="$(printf "%-*s  %-*s  %-*s  %-*s" \
    "$w_profile" "PROFILE" \
    "$w_state" "STATE" \
    "$w_model" "MODEL" \
    "$w_latency" "LATENCY")"

  if [[ "$COLOR_ENABLED" -eq 1 ]]; then
    paint "${CLR_BOLD}${CLR_CYAN}" "$header_line"
    printf '\n'
  else
    echo "$header_line"
  fi
}

collect_list_row() {
  local profile="$1"
  local active="$2"
  local settings_path file_state="" state="" model="" base_url="" api_key="" latency="-"

  settings_path="$(profile_settings "$profile")"
  while IFS=$'\t' read -r key value; do
    case "$key" in
      state) file_state="$value" ;;
      model) model="$value" ;;
      base_url) base_url="$value" ;;
      api_key) api_key="$value" ;;
    esac
  done < <(json_fields "$settings_path")

  if [[ "$file_state" == "ready" ]]; then
    check_connection_quick "$base_url" "$api_key"
    state="$CHECK_STATUS"
    latency="$CHECK_LATENCY"
  else
    state="$file_state"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$profile" "$state" "$model" "$latency" "$active"
}

command_list() {
  ensure_profiles_dir
  init_colors

  local active profiles=() line profile
  local h_profile="PROFILE"
  local h_state="STATE"
  local h_model="MODEL"
  local h_latency="LATENCY"
  local w_profile=${#h_profile}
  local w_state=${#h_state}
  local w_model=${#h_model}
  local w_latency=${#h_latency}
  local state_name model_preview settings_path

  if active="$(active_profile)"; then
    :
  else
    active=""
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    profiles+=("$line")
  done < <(find "$PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '_backup' -exec basename {} \; | sort)

  if [[ "${#profiles[@]}" -eq 0 ]]; then
    echo "No profiles found in $PROFILES_DIR"
    return 0
  fi

  for profile in "${profiles[@]}"; do
    (( ${#profile} > w_profile )) && w_profile=${#profile}
    settings_path="$(profile_settings "$profile")"
    model_preview="-"
    while IFS=$'\t' read -r key value; do
      case "$key" in
        model)
          [[ -n "$value" ]] && model_preview="$value"
          ;;
      esac
    done < <(json_fields "$settings_path")
    (( ${#model_preview} > w_model )) && w_model=${#model_preview}
  done

  for state_name in online auth-failed missing-key endpoint-mismatch rate-limited timeout unreachable server-error curl-error invalid broken no-base-url missing; do
    (( ${#state_name} > w_state )) && w_state=${#state_name}
  done
  (( 7 > w_latency )) && w_latency=7

  print_list_header "$w_profile" "$w_state" "$w_model" "$w_latency"

  local tmp_root fifo_path remaining=0 idx=0
  local -a pids=()
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/switchclaude-list.XXXXXX")"
  fifo_path="$tmp_root/results.fifo"
  mkfifo "$fifo_path"
  exec 3<>"$fifo_path"

  for profile in "${profiles[@]}"; do
    local active_flag
    active_flag="no"
    [[ "$profile" == "$active" ]] && active_flag="yes"

    (
      collect_list_row "$profile" "$active_flag" >&3
    ) &
    pids+=("$!")
    idx=$((idx + 1))
    remaining=$((remaining + 1))
  done

  while (( remaining > 0 )); do
    local row_profile state model latency active_flag
    if IFS=$'\t' read -r row_profile state model latency active_flag <&3; then
      print_status_row "$row_profile" "$state" "$model" "$latency" "$active_flag" "$w_profile" "$w_state" "$w_model" "$w_latency"
      remaining=$((remaining - 1))
    fi
  done

  for idx in "${!pids[@]}"; do
    wait "${pids[$idx]}" || true
  done

  exec 3>&-
  exec 3<&-
  rm -rf "$tmp_root"
}

command_status() {
  init_colors

  local active current_path file_state="" state="" model="" base_url="" api_key="" latency="-" checked_at="-"
  if active="$(active_profile)"; then
    current_path="$(profile_settings "$active")"
  else
    active=""
    current_path="$(current_settings_target)"
  fi

  while IFS=$'\t' read -r key value; do
    case "$key" in
      state) file_state="$value" ;;
      model) model="$value" ;;
      base_url) base_url="$value" ;;
      api_key) api_key="$value" ;;
    esac
  done < <(json_fields "$current_path")

  if [[ -L "$SETTINGS_FILE" && ! -e "$SETTINGS_FILE" ]]; then
    state="broken"
  elif [[ "$file_state" != "ready" ]]; then
    state="$file_state"
  else
    check_connection_quick "$base_url" "$api_key"
    state="$CHECK_STATUS"
    latency="$CHECK_LATENCY"
    checked_at="$CHECK_TIME"
  fi

  if [[ -n "$active" ]]; then
    paint "${CLR_BOLD}${CLR_CYAN}" "profile"
    echo ": $active"
  else
    paint "${CLR_BOLD}${CLR_CYAN}" "profile"
    echo ": (direct file)"
  fi
  paint "${CLR_BOLD}${CLR_CYAN}" "status"
  printf ': '
  paint "$(color_for_state "$state")" "$state"
  printf '\n'
  paint "${CLR_BOLD}${CLR_CYAN}" "latency"
  printf ': '
  paint "$CLR_BLUE" "${latency:--}"
  printf '\n'
  paint "${CLR_BOLD}${CLR_CYAN}" "model"
  echo ": ${model:--}"
  paint "${CLR_BOLD}${CLR_CYAN}" "base_url"
  echo ": ${base_url:--}"
  paint "${CLR_BOLD}${CLR_CYAN}" "time"
  echo ": ${checked_at:--}"
}

command_save() {
  local profile="$1"
  validate_profile_name "$profile"
  ensure_profiles_dir

  [[ -e "$SETTINGS_FILE" || -L "$SETTINGS_FILE" ]] || err "Current settings file not found: $SETTINGS_FILE"
  copy_resolved "$SETTINGS_FILE" "$(profile_settings "$profile")"
  note "Saved current settings to profile: $profile"
}

command_import() {
  local profile="$1"
  local source_settings="$2"
  validate_profile_name "$profile"
  require_file "$source_settings"
  ensure_profiles_dir

  copy_resolved "$source_settings" "$(profile_settings "$profile")"
  note "Imported profile $profile from $source_settings"
}

command_use() {
  local profile="$1"
  local target_file tmp_link backup_dir
  validate_profile_name "$profile"
  ensure_profiles_dir

  target_file="$(profile_settings "$profile")"
  require_file "$target_file"

  if [[ -e "$SETTINGS_FILE" && ! -f "$SETTINGS_FILE" && ! -L "$SETTINGS_FILE" ]]; then
    err "$SETTINGS_FILE exists and is not a regular file/symlink"
  fi

  backup_dir="$(backup_current_top_level_file || true)"

  mkdir -p "$CLAUDE_HOME"
  tmp_link="$SETTINGS_FILE.tmp.$$"
  rm -f "$tmp_link"
  ln -s "$target_file" "$tmp_link"
  mv -f "$tmp_link" "$SETTINGS_FILE"

  note "Switched Claude Code settings to profile: $profile"
  if [[ -n "$backup_dir" ]]; then
    note "Backed up previous direct settings to: $backup_dir/settings.json"
  fi
}

command_install() {
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
  echo "  command -> spcc"
  paint "$CLR_CYAN" "Run: source $(shell_quote "$rc_file")"
  printf '\n'
}

command_uninstall() {
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
  paint "$CLR_CYAN" "Run: source $(shell_quote "$rc_file")"
  printf '\n'
}

main() {
  local cmd="${1:-}"

  if [[ $# -eq 0 ]]; then
    command_status
    return 0
  fi

  case "$cmd" in
    help|-h|--help)
      usage
      ;;
    list)
      shift
      [[ $# -eq 0 ]] || err "list takes no arguments"
      command_list
      ;;
    status)
      shift
      [[ $# -eq 0 ]] || err "status takes no arguments"
      command_status
      ;;
    save)
      shift
      [[ $# -eq 1 ]] || err "Usage: $(basename "$0") save <profile>"
      command_save "$1"
      ;;
    import)
      shift
      [[ $# -eq 2 ]] || err "Usage: $(basename "$0") import <profile> <settings-file>"
      command_import "$1" "$2"
      ;;
    use)
      shift
      [[ $# -eq 1 ]] || err "Usage: $(basename "$0") use <profile>"
      command_use "$1"
      ;;
    install)
      shift
      [[ $# -le 1 ]] || err "Usage: $(basename "$0") install [rc-file]"
      command_install "${1:-}"
      ;;
    uninstall)
      shift
      [[ $# -le 1 ]] || err "Usage: $(basename "$0") uninstall [rc-file]"
      command_uninstall "${1:-}"
      ;;
    *)
      [[ $# -eq 1 ]] || err "Unknown command: $cmd"
      command_use "$cmd"
      ;;
  esac
}

main "$@"
