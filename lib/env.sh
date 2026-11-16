# Where things are: Dropbox folder, local home, data folder, Mac id and name, path <-> id.
GS_PROJECTS_DIR="hosts/devsite/projects"

GIT_SYNC_TRASH="${GIT_SYNC_TRASH:-trash}"

gs_die() {
  echo "git-sync: $*" >&2
  exit 1
}

# Print the physical path of an existing directory, or of a path whose parent exists.
gs__resolve() {
  local p="$1" d b
  if [ -d "$p" ]; then
    (cd "$p" && pwd -P)
    return
  fi
  d="$(dirname "$p")"
  b="$(basename "$p")"
  [ -d "$d" ] || return 1
  d="$(cd "$d" && pwd -P)" || return 1
  if [ "$d" = "/" ]; then echo "/$b"; else echo "$d/$b"; fi
}

gs_dropbox_root() {
  local raw="${GIT_SYNC_DROPBOX:-}" resolved
  if [ -z "$raw" ] && [ -r "$HOME/.dropbox/info.json" ]; then
    raw="$(/usr/bin/jq -r '.personal.path // empty' "$HOME/.dropbox/info.json" 2>/dev/null)"
  fi
  [ -n "$raw" ] || gs_die "cannot find the Dropbox folder (set GIT_SYNC_DROPBOX)"
  [ -d "$raw" ] || gs_die "Dropbox folder not found: $raw"
  resolved="$(cd "$raw" && pwd -P)" || gs_die "Dropbox folder not found: $raw"
  [ "$resolved" = "/" ] || resolved="${resolved%/}"
  echo "$resolved"
}

gs_home() { echo "${GIT_SYNC_HOME:-$HOME/.git-sync}"; }

gs_data_dir() { echo "${GIT_SYNC_DATA:-$GS_ROOT}"; }

gs_mac_id() {
  local home file id
  home="$(gs_home)"
  file="$home/mac-id"
  if [ ! -s "$file" ]; then
    mkdir -p "$home" || gs_die "cannot create $home"
    id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    [ -n "$id" ] || gs_die "cannot generate a Mac id"
    printf '%s\n' "$id" > "$file" || gs_die "cannot write $file"
  fi
  head -n 1 "$file"
}

gs_mac_name() {
  if [ -n "${GIT_SYNC_MAC_NAME:-}" ]; then
    echo "$GIT_SYNC_MAC_NAME"
  else
    scutil --get ComputerName
  fi
}

gs_rel_path() {
  local root abs
  root="$(gs_dropbox_root)" || exit 1
  abs="$(gs__resolve "$1")" || gs_die "not inside Dropbox: $1"
  case "$abs" in
    "$root"/?*) echo "${abs#"$root"/}" ;;
    *) gs_die "not inside Dropbox: $1" ;;
  esac
}

gs_abs_path() {
  local root
  root="$(gs_dropbox_root)" || exit 1
  echo "$root/$1"
}

gs_id_for() {
  local s="${1//\//--}"
  printf '%s' "$s" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
  echo
}

gs_store_for() { echo "$(gs_home)/repos/$1.git"; }

gs_display() { echo "${1#"$GS_PROJECTS_DIR"/}"; }
