#!/usr/bin/env bash
# Shared local log and raw Telegram failure alert helpers for hermes-backup.
# Callers load secrets from the local chmod-600 env file before sourcing/using
# these helpers. Values are redacted before they are written to logs or alerts.

hb_timestamp_utc() {
  /usr/bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
}

hb_date_utc() {
  /usr/bin/date -u '+%Y-%m-%d'
}

hb_log_dir_default() {
  if [[ -n "${HERMES_BACKUP_LOG_DIR:-}" ]]; then
    printf '%s\n' "$HERMES_BACKUP_LOG_DIR"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/hermes-backup/logs\n' "$XDG_STATE_HOME"
  else
    [[ -n "${HOME:-}" ]] || return 1
    printf '%s/.local/state/hermes-backup/logs\n' "$HOME"
  fi
}

hb_escape_glob_pattern() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\*/\\*}
  value=${value//\?/\\?}
  value=${value//\[/\\[}
  value=${value//\]/\\]}
  printf '%s' "$value"
}

hb_redact_literal_values() {
  local line=$1 pattern tmp_name tmp_value
  local -a names=() values=()

  for tmp_name in \
    B2_ACCOUNT_KEY \
    B2_ACCOUNT_ID \
    RESTIC_REPOSITORY \
    RESTIC_PASSWORD_FILE \
    RESTIC_PASSWORD \
    TELEGRAM_BOT_TOKEN \
    TELEGRAM_CHAT_ID; do
    tmp_value=${!tmp_name:-}
    if [[ -n "$tmp_value" ]]; then
      names+=("$tmp_name")
      values+=("$tmp_value")
    fi
  done

  if [[ -n "${RESTIC_PASSWORD_VALUE:-}" ]]; then
    names+=("RESTIC_PASSWORD")
    values+=("$RESTIC_PASSWORD_VALUE")
  fi

  local i j extglob_was_on=0
  if shopt -q extglob 2>/dev/null; then
    extglob_was_on=1
    shopt -u extglob 2>/dev/null || true
  fi
  for ((i = 0; i < ${#values[@]}; i++)); do
    for ((j = i + 1; j < ${#values[@]}; j++)); do
      if (( ${#values[j]} > ${#values[i]} )); then
        tmp_value=${values[i]}; values[i]=${values[j]}; values[j]=$tmp_value
        tmp_name=${names[i]}; names[i]=${names[j]}; names[j]=$tmp_name
      fi
    done
  done

  for ((i = 0; i < ${#values[@]}; i++)); do
    pattern="$(hb_escape_glob_pattern "${values[i]}")"
    line=${line//$pattern/[redacted:${names[i]}]}
  done
  if [[ "$extglob_was_on" -eq 1 ]]; then
    shopt -s extglob 2>/dev/null || true
  fi
  printf '%s' "$line"
}

hb_redact_generic_patterns() {
  /usr/bin/sed -E \
    -e 's/(Authorization([[:space:]]*[:=])?[[:space:]]*).*/\1[redacted:credential]/Ig' \
    -e 's/("[^"]*(authorization|password|passwd|token|secret|credential(s)?|api[_-]?key|access[_-]?key|key)[^"]*"[[:space:]]*:[[:space:]]*")[^"]*"/\1[redacted:credential]"/Ig' \
    -e "s/('[^']*(authorization|password|passwd|token|secret|credential(s)?|api[_-]?key|access[_-]?key|key)[^']*'[[:space:]]*:[[:space:]]*')[^']*'/\\1[redacted:credential]'/Ig" \
    -e 's/(^|[^[:alnum:]_/-])(([[:alnum:]_-]*(password|passwd|token|secret|credential(s)?|api[_-]?key|access[_-]?key|key)[[:alnum:]_-]*)[[:space:]]*[:=][[:space:]]*).*/\1\2[redacted:credential]/Ig' \
    -e 's/([?&])(([[:alnum:]_-]*(password|passwd|token|secret|credential(s)?|api[_-]?key|access[_-]?key|key)[[:alnum:]_-]*)=)[^&]+/\1\2[redacted:credential]/Ig'
}

hb_redact_line() {
  local line
  line="$(printf '%s\n' "$1" | hb_redact_generic_patterns)"
  line="$(hb_redact_literal_values "$line")"
  printf '%s\n' "$line"
}

hb_redact_file() {
  local output_file=$1 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    hb_redact_line "$line"
  done <"$output_file"
}

hb_setup_logging() {
  local log_dir old_umask
  log_dir="$(hb_log_dir_default)" || return 1
  case "$log_dir" in
    "") return 1 ;;
    /*) ;;
    *) printf 'error: HERMES_BACKUP_LOG_DIR must be an absolute path\n' >&2; return 1 ;;
  esac
  old_umask=$(umask)
  umask 077
  if ! /usr/bin/mkdir -p -- "$log_dir"; then
    umask "$old_umask"
    return 1
  fi
  if ! /usr/bin/chmod 700 -- "$log_dir"; then
    umask "$old_umask"
    return 1
  fi
  HERMES_BACKUP_LOG_FILE="$log_dir/hermes-backup-$(hb_date_utc).log"
  if ! /usr/bin/touch -- "$HERMES_BACKUP_LOG_FILE"; then
    umask "$old_umask"
    return 1
  fi
  if ! /usr/bin/chmod 600 -- "$HERMES_BACKUP_LOG_FILE"; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  export HERMES_BACKUP_LOG_FILE
}

hb_append_log_line() {
  local line=$1
  [[ -n "${HERMES_BACKUP_LOG_FILE:-}" ]] || return 0
  hb_redact_line "$line" >>"$HERMES_BACKUP_LOG_FILE" || true
}

hb_log_event() {
  local command_name=$1 status=$2 exit_code=$3 summary=$4 details_file=${5:-}
  [[ -n "${HERMES_BACKUP_LOG_FILE:-}" ]] || return 0
  {
    printf '%s command=%s status=%s exit=%s\n' "$(hb_timestamp_utc)" "$command_name" "$status" "$exit_code"
    if [[ -n "$summary" ]]; then
      printf 'summary=%s\n' "$summary"
    fi
    if [[ -n "$details_file" && -s "$details_file" ]]; then
      printf 'details=begin\n'
      hb_redact_file "$details_file" | /usr/bin/sed -n '1,20p'
      printf 'details=end\n'
    fi
  } | while IFS= read -r line || [[ -n "$line" ]]; do
    hb_redact_line "$line"
  done >>"$HERMES_BACKUP_LOG_FILE" || true
}

hb_alert_message() {
  local command_name=$1 exit_code=$2 summary=$3 details_file=${4:-} rendered
  rendered="$({
    printf 'Hermes backup failure\n'
    printf 'command: %s\n' "$command_name"
    printf 'time: %s\n' "$(hb_timestamp_utc)"
    printf 'host: %s\n' "$(hostname 2>/dev/null || printf 'unknown')"
    printf 'exit: %s\n' "$exit_code"
    printf 'summary: %s\n' "$summary"
    if [[ -n "$details_file" && -s "$details_file" ]]; then
      printf 'details:\n'
      hb_redact_file "$details_file" | /usr/bin/sed -n '1,8p'
    fi
  } | while IFS= read -r line || [[ -n "$line" ]]; do
    hb_redact_line "$line"
  done)"
  printf '%s' "${rendered:0:1800}"
}

hb_send_failure_alert() {
  local command_name=$1 exit_code=$2 summary=$3 details_file=${4:-}
  local message curl_output curl_rc message_file
  local -a curl_env

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    hb_append_log_line "alert=skipped reason=missing_telegram_config command=$command_name"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    hb_append_log_line "alert=skipped reason=curl_missing command=$command_name"
    return 0
  fi

  message="$(hb_alert_message "$command_name" "$exit_code" "$summary" "$details_file")"
  message_file="$(/usr/bin/mktemp -t hermes-backup-telegram-message.XXXXXX)"
  printf '%s' "$message" >"$message_file"
  /usr/bin/chmod 600 -- "$message_file" 2>/dev/null || true
  curl_output="$(/usr/bin/mktemp -t hermes-backup-telegram-alert.XXXXXX)"
  curl_env=("PATH=$PATH")
  if [[ -n "${FAKE_CURL_LOG:-}" ]]; then
    curl_env+=("FAKE_CURL_LOG=$FAKE_CURL_LOG")
  fi
  if [[ -n "${FAKE_CURL_FAIL:-}" ]]; then
    curl_env+=("FAKE_CURL_FAIL=$FAKE_CURL_FAIL")
  fi
  set +e
  env -i "${curl_env[@]}" curl --fail --silent --show-error --max-time 20 --config - >"$curl_output" 2>&1 <<CURL_CONFIG
url = "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
request = "POST"
data-urlencode = "chat_id=${TELEGRAM_CHAT_ID}"
data-urlencode = "text@${message_file}"
data-urlencode = "disable_web_page_preview=true"
CURL_CONFIG
  curl_rc=$?
  set -e
  if [[ "$curl_rc" -eq 0 ]]; then
    hb_append_log_line "alert=sent command=$command_name transport=raw-telegram-api"
  else
    hb_append_log_line "alert=failed command=$command_name curl_exit=$curl_rc"
    if [[ -n "${HERMES_BACKUP_LOG_FILE:-}" ]]; then
      hb_redact_file "$curl_output" | /usr/bin/sed 's/^/alert_error=/' >>"$HERMES_BACKUP_LOG_FILE" || true
    fi
  fi
  rm -f -- "$curl_output" "$message_file"
  return 0
}

hb_log_and_alert_failure() {
  local command_name=$1 exit_code=$2 summary=$3 details_file=${4:-}
  HERMES_BACKUP_FAILURE_RECORDED=1
  export HERMES_BACKUP_FAILURE_RECORDED
  hb_log_event "$command_name" "failure" "$exit_code" "$summary" "$details_file" || true
  hb_send_failure_alert "$command_name" "$exit_code" "$summary" "$details_file" || true
}

hb_log_success() {
  local command_name=$1 summary=$2
  hb_log_event "$command_name" "success" "0" "$summary"
}
