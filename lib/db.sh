# Read and write repos.json and the per-Mac state files.

db_file() {
  local d
  d="$(gs_data_dir)" || exit 1
  echo "$d/repos.json"
}

# Die unless repos.json is missing or a valid JSON object.
db__check() {
  local f
  f="$(db_file)"
  [ -e "$f" ] || return 0
  /usr/bin/jq -e 'type == "object"' "$f" >/dev/null 2>&1 || gs_die "repos.json is not valid JSON; fix it by hand"
}

# Write stdin to $1 through a temp file in the same folder, then rename.
db__write() {
  local target="$1" tmp
  tmp="$(mktemp "$(dirname "$target")/.tmp.XXXXXX")" || gs_die "cannot write next to $target"
  if cat > "$tmp"; then
    mv "$tmp" "$target" || gs_die "cannot write $target"
  else
    gs_die "cannot write $target"
  fi
}

db_ids() {
  local f
  f="$(db_file)"
  db__check || exit 1
  [ -f "$f" ] || return 0
  /usr/bin/jq -r '(.repos // [])[].id' "$f"
}

db_path() {
  db__check || exit 1
  [ -f "$(db_file)" ] || return 0
  /usr/bin/jq -r --arg id "$1" '(.repos // [])[] | select(.id == $id) | .path' "$(db_file)"
}

db_remotes() {
  db__check || exit 1
  [ -f "$(db_file)" ] || return 0
  /usr/bin/jq -r --arg id "$1" '(.repos // [])[] | select(.id == $id) | (.remotes // {}) | to_entries[] | "\(.key)\t\(.value)"' "$(db_file)"
}

db_id_by_path() {
  local id
  db__check || exit 1
  [ -f "$(db_file)" ] || return 1
  id="$(/usr/bin/jq -r --arg p "$1" '[(.repos // [])[] | select(.path == $p) | .id][0] // empty' "$(db_file)")" || return 1
  [ -n "$id" ] || return 1
  echo "$id"
}

db_put() {
  local id="$1" rel="$2" remotes="$3" f current out
  db__check || exit 1
  f="$(db_file)"
  mkdir -p "$(dirname "$f")" || gs_die "cannot create $(dirname "$f")"
  if [ -f "$f" ]; then current="$(cat "$f")"; else current='{"version":1,"repos":[]}'; fi
  out="$(printf '%s' "$current" | /usr/bin/jq --arg id "$id" --arg p "$rel" --argjson r "$remotes" '
    .version = (.version // 1)
    | .repos = (.repos // [])
    | ({id: $id, path: $p, remotes: $r}) as $e
    | if any(.repos[]; .id == $id)
      then .repos |= map(if .id == $id then $e else . end)
      else .repos += [$e] end')" || gs_die "cannot update repos.json"
  printf '%s\n' "$out" | db__write "$f"
}

db_delete() {
  local f out
  db__check || exit 1
  f="$(db_file)"
  [ -f "$f" ] || return 0
  out="$(/usr/bin/jq --arg id "$1" '.repos = ((.repos // []) | map(select(.id != $id)))' "$f")" || gs_die "cannot update repos.json"
  printf '%s\n' "$out" | db__write "$f"
}

state_file() {
  local id
  id="$(gs_mac_id)" || exit 1
  echo "$(gs_data_dir)/state/$id.json"
}

state__now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

state_record() {
  local id="$1" branch="$2" head="$3" f name old cur out
  f="$(state_file)" || exit 1
  name="$(gs_mac_name)" || exit 1
  old=""
  if [ -f "$f" ]; then
    old="$(/usr/bin/jq -r --arg id "$id" '.repos[$id] | select(. != null) | "\(.branch)\t\(.head)"' "$f" 2>/dev/null)"
  fi
  cur="$(printf '%s\t%s' "$branch" "$head")"
  if [ "$old" = "$cur" ]; then
    bundle_publish "$id" "$branch" "$head"
    return 0
  fi
  mkdir -p "$(dirname "$f")" || gs_die "cannot create $(dirname "$f")"
  if [ -f "$f" ] && /usr/bin/jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    out="$(cat "$f")"
  else
    out='{}'
  fi
  out="$(printf '%s' "$out" | /usr/bin/jq --arg n "$name" --arg id "$id" --arg b "$branch" --arg h "$head" --arg at "$(state__now)" '
    .name = $n | .repos = (.repos // {}) | .repos[$id] = {branch: $b, head: $h, at: $at}')" || gs_die "cannot update state file"
  printf '%s\n' "$out" | db__write "$f"
  bundle_publish "$id" "$branch" "$head"
}

state_forget() {
  local f out
  f="$(state_file)" || exit 1
  [ -f "$f" ] || return 0
  /usr/bin/jq -e 'type == "object"' "$f" >/dev/null 2>&1 || return 0
  out="$(/usr/bin/jq --arg id "$1" 'del(.repos[$id])' "$f")" || return 0
  printf '%s\n' "$out" | db__write "$f"
}

state_own() {
  local f
  f="$(state_file)" || exit 1
  [ -f "$f" ] || return 0
  /usr/bin/jq -r --arg id "$1" '.repos[$id] | select(. != null) | "\(.branch)\t\(.head)\t\(.at)"' "$f" 2>/dev/null
  return 0
}

state_latest_other() {
  local id="$1" own dir f lines="" line
  own="$(state_file)" || exit 1
  dir="$(gs_data_dir)/state"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    [ "$f" = "$own" ] && continue
    line="$(/usr/bin/jq -r --arg id "$id" '.name as $n | .repos[$id] | select(. != null) | "\(.at)\t\($n)\t\(.branch)\t\(.head)"' "$f" 2>/dev/null)" || continue
    [ -z "$line" ] || line="$line$(printf '\t')$(basename "$f" .json)"
    [ -n "$line" ] || continue
    lines="$lines$line
"
  done
  [ -n "$lines" ] || return 0
  printf '%s' "$lines" | LC_ALL=C sort -t "$(printf '\t')" -k1,1r | head -n 1 | awk -F'\t' '{print $2 "\t" $3 "\t" $4 "\t" $1 "\t" $5}'
}
