#!/usr/bin/env bash
# =============================================================================
#  env_loader.sh  –  Read .env as data, never execute it
#
#  `source .env` runs every line as bash, so an unquoted value with spaces
#  (e.g. SYNC_CRON_OVERRIDE=30 1,4,7 * * *) becomes a command and kills the
#  script. load_env_file parses KEY=VALUE lines instead:
#    KEY=value with spaces        → taken literally (trailing " # comment" dropped)
#    KEY="double quoted \$x"      → \$ \" \` \\ unescaped, no $VAR expansion
#    KEY='single quoted'          → literal; may span several lines (JSON)
#
#  Usage:  source "${SCRIPT_DIR}/env_loader.sh"; load_env_file "${SCRIPT_DIR}/.env"
# =============================================================================

_env_assign() {   # $1 = key, $2 = raw value, $3 = quote char ('' for none)
  local v="$2"
  if [[ "$3" != "'" ]]; then
    v="${v//\\\$/\$}"
    v="${v//\\\"/\"}"
    v="${v//\\\`/\`}"
    v="${v//\\\\/\\}"
  fi
  printf -v "$1" '%s' "$v"
}

load_env_file() {
  local file="$1" line key val q rest
  local pend_key="" pend_val="" pend_q=""
  [[ -f "$file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    # Continuation of a multi-line quoted value
    if [[ -n "$pend_key" ]]; then
      if [[ "$line" == *"$pend_q"* ]]; then
        _env_assign "$pend_key" "${pend_val}"$'\n'"${line%"$pend_q"*}" "$pend_q"
        pend_key=""
      else
        pend_val+=$'\n'"$line"
      fi
      continue
    fi

    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    val="${BASH_REMATCH[3]}"
    q="${val:0:1}"

    if [[ "$q" == '"' || "$q" == "'" ]]; then
      rest="${val:1}"
      if [[ "$rest" == *"$q"* ]]; then
        _env_assign "$key" "${rest%"$q"*}" "$q"
      else
        pend_key="$key"; pend_val="$rest"; pend_q="$q"
      fi
    else
      val="${val%%[[:space:]]#*}"                 # drop trailing " # comment"
      val="${val%"${val##*[![:space:]]}"}"        # trim trailing whitespace
      _env_assign "$key" "$val" ""
    fi
  done < "$file"
}
