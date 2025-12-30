#!/bin/bash

CHAT_MAIN="chat-main"
CHAT_PRESENCE="chat-presence"
CHAT_USER_PREFIX="chat-user-"
CHAT_FILE_PREFIX="chat-file-"
NTFY_BASE="https://ntfy.sh"

USER_NAME="${USER:-$(whoami)}"
HOST="$(hostname)"
ID="$USER_NAME@$HOST"
MY_TOPIC="${CHAT_USER_PREFIX}${USER_NAME}"

HEARTBEAT_INTERVAL=15
USER_TIMEOUT=30

declare -A USERS
declare -A USER_LAST_SEEN

now() { date +%s; }

say() {
  echo "$@"
}

send() {
  local topic="$1"
  shift
  curl -s -X POST "$NTFY_BASE/$topic" -d "$*" > /dev/null
}

allowed_dir() {
  [[ "$1" == "Downloads" || "$1" == "Documents" ]]
}

presence_loop() {
  while true; do
    send "$CHAT_PRESENCE" "ONLINE:$ID"
    sleep "$HEARTBEAT_INTERVAL"
  done
}

expire_users() {
  local t
  t=$(now)
  for u in "${!USER_LAST_SEEN[@]}"; do
    (( t - USER_LAST_SEEN["$u"] > USER_TIMEOUT )) && unset USERS["$u"] USER_LAST_SEEN["$u"]
  done
}

handle_presence() {
  local msg="$1"
  if [[ "$msg" =~ ^ONLINE:(.+)$ ]]; then
    local who="${BASH_REMATCH[1]}"
    USERS["$who"]=1
    USER_LAST_SEEN["$who"]="$(now)"
  fi
}

handle_private() {
  local msg="$1"

  if [[ "$msg" =~ ^PM\ from\ (.+)\ (.+)$ ]]; then
    say "[PM][$1] ${BASH_REMATCH[2]}"
    return
  fi

  if [[ "$msg" =~ ^BROWSE_REQ\ from=(.+)\ dir=(.+)$ ]]; then
    local from="${BASH_REMATCH[1]}"
    local dir="${BASH_REMATCH[2]}"

    if ! allowed_dir "$dir"; then
      send "${CHAT_USER_PREFIX}${from%%@*}" "BROWSE_RESP to=$from files=DENIED"
      return
    fi

    files=$(ls "$HOME/$dir" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    send "${CHAT_USER_PREFIX}${from%%@*}" "BROWSE_RESP to=$from files=$files"
    return
  fi

  if [[ "$msg" =~ ^BROWSE_RESP\ to=$ID\ files=(.+)$ ]]; then
    say "[browse] ${BASH_REMATCH[1]}"
    return
  fi

  if [[ "$msg" =~ ^FILE_REQ\ from=(.+)\ file=(.+)$ ]]; then
    local from="${BASH_REMATCH[1]}"
    local file="${BASH_REMATCH[2]}"

    say "File request from $from: $file"
    read -rp "Allow? [y/N] " ans
    [[ "$ans" != "y" ]] && return

    local full="$HOME/$file"
    [[ ! -f "$full" ]] && say "File missing." && return

    topic="${CHAT_FILE_PREFIX}${USER_NAME}-${from%%@*}"
    curl -s -T "$full" "$NTFY_BASE/$topic" > /dev/null
    send "${CHAT_USER_PREFIX}${from%%@*}" "FILE_OK topic=$topic file=$(basename "$file")"
    return
  fi

  if [[ "$msg" =~ ^FILE_OK\ topic=(.+)\ file=(.+)$ ]]; then
    local topic="${BASH_REMATCH[1]}"
    local file="${BASH_REMATCH[2]}"
    say "Receiving $file ..."
    curl -s "$NTFY_BASE/$topic/raw" -o "$file"
    say "Saved as ./$file"
    return
  fi
}

handle_main() {
  say "$1"
}

listener() {
  curl -sN "$NTFY_BASE/$CHAT_PRESENCE/raw" | while read -r line; do
    handle_presence "$line"
    expire_users
  done &

  curl -sN "$NTFY_BASE/$MY_TOPIC/raw" | while read -r line; do
    handle_private "$line"
  done &

  curl -sN "$NTFY_BASE/$CHAT_MAIN/raw" | while read -r line; do
    handle_main "$line"
  done &
}

cmd_list() {
  expire_users
  say "Active users:"
  for u in "${!USERS[@]}"; do
    say " - $u"
  done
}

cmd_browse() {
  [[ "$1" =~ -u\ ([^ ]+)\ -d\ ([^ ]+) ]] || return
  send "${CHAT_USER_PREFIX}${BASH_REMATCH[1]}" \
    "BROWSE_REQ from=$ID dir=${BASH_REMATCH[2]}"
}

cmd_request() {
  [[ "$1" =~ -u\ ([^ ]+)\ -f\ (.+) ]] || return
  send "${CHAT_USER_PREFIX}${BASH_REMATCH[1]}" \
    "FILE_REQ from=$ID file=${BASH_REMATCH[2]}"
}

cmd_pm() {
  local target="${1#/msg}"
  target="$(echo "$target" | tr 'A-Z' 'a-z')"
  local msg="${2:-}"
  send "${CHAT_USER_PREFIX}$target" "PM from $ID $msg"
}

send_public() {
  send "$CHAT_MAIN" "[$ID] $*"
}

handle_input() {
  case "$1" in
    /list) cmd_list ;;
    /browse*) cmd_browse "$1" ;;
    /request*) cmd_request "$1" ;;
    /msg[A-Z]*) cmd_pm "$1" "${@:2}" ;;
    *) send_public "$*" ;;
  esac
}

clear
say "Connected as $ID"
say "Available commands: /list /browse /request /msg "
say "-------------------"

presence_loop &
listener &

while read -r line; do
  [[ -z "$line" ]] && continue
  handle_input $line
done
