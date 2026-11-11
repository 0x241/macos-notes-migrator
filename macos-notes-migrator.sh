#!/bin/bash
# Migrate Apple Notes' local store from Time Machine or an extracted backup.
# Compatible with Apple's system Bash 3.2 (no nounset on initially empty arrays).
set -eo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage:
  bash macos-notes-migrator.sh
  bash macos-notes-migrator.sh --backup-root "/path/to/one/Time Machine/snapshot"
  bash macos-notes-migrator.sh --source "/path/to/old/group.com.apple.notes"
  bash macos-notes-migrator.sh --mount-time-machine --dry-run
  bash macos-notes-migrator.sh --import-flashnote --dry-run
  bash macos-notes-migrator.sh --import-flashnote --flashnote-db "/path/to/notes2.db"
  bash macos-notes-migrator.sh --import-flashnote --flashnote-format enex --flashnote-limit 1
  bash macos-notes-migrator.sh --import-flashnote --flashnote-format enex --notes-account local

Options:
  --backup-root DIR  Search only this snapshot or extracted backup directory.
  --source DIR       Use an exact saved Notes folder containing NoteStore.sqlite.
  --backup-dir DIR   Parent folder for safety backups (default: ~/Documents/NotesMigratorBackups).
  --dry-run          Show the detected source and planned destination; change nothing.
  --mount-time-machine
                     Offer to mount APFS Time Machine backup snapshots via sudo tmutil.
                     Requires Terminal Full Disk Access; may mount many snapshots.
                     Even with --dry-run, mounting changes system mount state.
  --import-flashnote   Convert a Flashnote notes2.db tree to files for Notes import.
  --flashnote-db FILE  Use the exact Flashnote notes2.db or dated backup .db.
  --flashnote-root DIR Search this extracted Windows Flashnote/AppData directory.
  --flashnote-output DIR
                     Parent folder for converted notes (default: safety backup folder).
  --flashnote-format txt|enex
                     txt (default): folder tree, new import dates.
                     enex: original creation/edit dates embedded (Apple Notes support varies).
  --flashnote-limit N  ENEX only: make a small test before importing all notes.
  --notes-account local|icloud|ask
                     For Flashnote import: choose intended Apple Notes account.
                     Default: ask interactively after EXPORT. The user must
                     select that account in Notes before importing the files.
  --no-open          Do not automatically open Notes after restoring.
  -h, --help         Show this help.

Without options, the script searches ~/Desktop, ~/Downloads and accessible
Time Machine snapshot paths. If only unmounted Time Machine snapshots are
found, it offers to mount them (requires explicit MOUNT confirmation and sudo).
If several old stores are found, YOU choose one.
It backs up today's entire Notes folder, makes a verified staging copy, then
replaces the folder only after you type MIGRATE. Do not run with sudo.
Flashnote conversion is separate: it NEVER replaces your current Notes store.
After conversion, use Notes > File > Import to Notes, keeping folder structure.
USAGE
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

source_hint=''
backup_root=''
# Tests use a dedicated fake home; never overwrite HOME or touch the real one.
user_home=${NOTES_MIGRATOR_TEST_HOME:-$HOME}
backup_base="$user_home/Documents/NotesMigratorBackups"
dry_run=0
no_open=0
mount_time_machine=0
flashnote_mode=0
flashnote_db=''
flashnote_root=''
flashnote_output=''
flashnote_format='txt'
flashnote_limit=''
flashnote_format_explicit=0
notes_account=

while (( $# > 0 )); do
  case "$1" in
    --source|--backup-root|--backup-dir|--flashnote-db|--flashnote-root|--flashnote-output|--flashnote-format|--flashnote-limit|--notes-account)
      (( $# >= 2 )) || fail "Missing value for $1"
      case "$1" in
        --source) source_hint=$2 ;;
        --backup-root) backup_root=$2 ;;
        --backup-dir) backup_base=$2 ;;
        --flashnote-db) flashnote_db=$2 ;;
        --flashnote-root) flashnote_root=$2 ;;
        --flashnote-output) flashnote_output=$2 ;;
        --flashnote-format) flashnote_format=$2; flashnote_format_explicit=1 ;;
        --flashnote-limit) flashnote_limit=$2 ;;
        --notes-account) notes_account=$2 ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=1; shift ;;
    --mount-time-machine) mount_time_machine=1; shift ;;
    --import-flashnote) flashnote_mode=1; shift ;;
    --no-open) no_open=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || fail 'This tool requires macOS.'
[[ "$(id -u)" != 0 ]] || fail 'Do not run this tool with sudo or as root.'
if (( flashnote_mode )); then
  if [[ -n "$source_hint" || -n "$backup_root" ]] || (( mount_time_machine )); then
    fail 'Flashnote import is separate from Apple Notes folder migration or Time Machine mounting.'
  fi
  [[ -z "$flashnote_db" || -z "$flashnote_root" ]] || \
    fail 'Use --flashnote-db OR --flashnote-root, not both.'
  command -v python3 >/dev/null 2>&1 || fail 'Flashnote import needs Python 3 (the standard sqlite3 module).'
  helper_dir=$(cd "$(dirname "$0")" && pwd -P)
  flashnote_args=(--home "$user_home")
  flashnote_args+=(--format "$flashnote_format")
  [[ -z "$notes_account" ]] || flashnote_args+=(--notes-account "$notes_account")
  [[ -z "$flashnote_limit" ]] || flashnote_args+=(--limit "$flashnote_limit")
  if [[ -n "$flashnote_output" ]]; then
    flashnote_args+=(--output-base "$flashnote_output")
  else
    flashnote_args+=(--output-base "$backup_base/FlashnoteExports")
  fi
  [[ -z "$flashnote_db" ]] || flashnote_args+=(--db "$flashnote_db")
  [[ -z "$flashnote_root" ]] || flashnote_args+=(--root "$flashnote_root")
  (( ! dry_run )) || flashnote_args+=(--dry-run)
  (( ! no_open )) || flashnote_args+=(--no-open)
  exec python3 "$helper_dir/flashnote-to-notes.py" "${flashnote_args[@]}"
fi
[[ -z "$flashnote_db" && -z "$flashnote_root" && -z "$flashnote_output" && \
   -z "$flashnote_limit" && -z "$notes_account" && "$flashnote_format_explicit" == 0 ]] || \
  fail '--flashnote-* options require --import-flashnote.'
[[ -z "$source_hint" || -z "$backup_root" ]] || fail 'Use --source OR --backup-root, not both.'
if (( mount_time_machine )) && [[ -n "$source_hint" || -n "$backup_root" ]]; then
  fail 'Use --mount-time-machine only with automatic discovery, not --source or --backup-root.'
fi
for tool in find mktemp ditto sqlite3 mv pgrep osascript; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required macOS tool missing: $tool"
done

target_parent="$user_home/Library/Group Containers"
target="$target_parent/group.com.apple.notes"
[[ -d "$target_parent" ]] || fail "Missing current user Group Containers folder: $target_parent"
[[ ! -L "$target" ]] || fail 'Current Notes folder is a symlink. Refusing an ambiguous destination.'
target_real=''
[[ ! -d "$target" ]] || target_real=$(cd "$target" && pwd -P)

candidates=()
add_candidate() {
  local path=$1 canonical existing
  [[ -d "$path" && -s "$path/NoteStore.sqlite" ]] || return 0
  canonical=$(cd "$path" && pwd -P) || return 0
  [[ "$canonical" != "$target_real" ]] || return 0
  for existing in "${candidates[@]}"; do
    [[ "$existing" != "$canonical" ]] || return 0
  done
  candidates+=("$canonical")
}

scan_tree() {
  local root=$1 found
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' found; do
    add_candidate "$found"
  done < <(find "$root" -type d -name group.com.apple.notes -prune -print0 2>/dev/null)
}

scan_snapshot_path() {
  local snapshot=$1 candidate
  [[ "$snapshot" == /* && -d "$snapshot" ]] || return 0
  # Typical APFS Time Machine layouts have one or two volume-store levels.
  for candidate in \
    "$snapshot"/Users/*/Library/'Group Containers'/group.com.apple.notes \
    "$snapshot"/*/Users/*/Library/'Group Containers'/group.com.apple.notes \
    "$snapshot"/*/*/Users/*/Library/'Group Containers'/group.com.apple.notes; do
    add_candidate "$candidate"
  done
}

# Present large Time Machine histories without dumping dozens of full paths.
# Menus use stable visible numbers; a selection always resolves to the exact
# candidate path and is printed again before any write is offered.
menu_choice=0
select_paged_menu() {
  local title=$1 reply count page=0 first last i selected_number
  shift
  local labels=("$@")
  count=${#labels[@]}
  (( count > 0 )) || fail 'There are no items to select.'
  if (( count == 1 )); then
    menu_choice=0
    return 0
  fi
  while :; do
    first=$((page * 10))
    last=$((first + 10))
    (( last < count )) || last=$count
    printf '\n%s (page %d/%d):\n' "$title" "$((page + 1))" "$(((count + 9) / 10))"
    for (( i=first; i<last; i++ )); do
      printf '  %d) %s\n' "$((i + 1))" "${labels[i]}"
    done
    printf 'Enter a visible number, n=next, p=previous, 0=cancel: '
    IFS= read -r reply || fail 'Selection cancelled (end of input).'
    case "$reply" in
      n|N)
        if (( last < count )); then page=$((page + 1)); else printf 'Already on the last page.\n'; fi
        ;;
      p|P)
        if (( page > 0 )); then page=$((page - 1)); else printf 'Already on the first page.\n'; fi
        ;;
      0) fail 'Cancelled.' ;;
      *)
        if [[ "$reply" =~ ^[0-9]+$ && ${#reply} -le 6 ]]; then
          selected_number=$((10#$reply))
          if (( selected_number > first && selected_number <= last )); then
            menu_choice=$((selected_number - 1))
            return 0
          fi
        fi
        printf 'Select a number displayed on this page.\n'
        ;;
    esac
  done
}

describe_candidate() {
  local path=$1 parent stamp volume_name
  described_user='Extracted / unknown user'
  described_month='Undated / extracted'
  described_label=''
  case "$path" in
    */Users/*/Library/'Group Containers'/group.com.apple.notes)
      parent=${path%/Library/'Group Containers'/group.com.apple.notes}
      described_user=${parent##*/}
      ;;
  esac
  if [[ "$path" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})\.backup ]]; then
    stamp=${BASH_REMATCH[1]}
    described_month=${stamp:0:7}
    described_label="${stamp:0:10} ${stamp:11:2}:${stamp:13:2}:${stamp:15:2} (Time Machine)"
    case "$path" in
      */Users/*)
        parent=${path%/Users/*}
        volume_name=${parent##*/}
        case "$volume_name" in
          ''|*.backup) ;;
          *) described_label+=" — $volume_name" ;;
        esac
        ;;
    esac
  else
    case "$path" in
      "$user_home"/Desktop/*)
        described_label="Desktop/${path#"$user_home"/Desktop/}" ;;
      "$user_home"/Downloads/*)
        described_label="Downloads/${path#"$user_home"/Downloads/}" ;;
      *) described_label="Extracted: ${path%/group.com.apple.notes}" ;;
    esac
  fi
}

choose_source() {
  local i j found chosen_user chosen_month index total
  local users=() user_counts=() user_labels=()
  local months=() month_counts=() month_labels=()
  local matching_indices=() snapshot_labels=()
  local described_user described_month described_label
  local candidate_users=() candidate_months=() candidate_labels=()
  total=${#candidates[@]}
  if (( total == 1 )); then
    source_dir=${candidates[0]}
    return 0
  fi

  for (( i=0; i<total; i++ )); do
    describe_candidate "${candidates[i]}"
    candidate_users+=("$described_user")
    candidate_months+=("$described_month")
    candidate_labels+=("$described_label")
  done

  # Reverse discovery order: recent Time Machine snapshots are typically last.
  for (( i=total-1; i>=0; i-- )); do
    found=0
    for (( j=0; j<${#users[@]}; j++ )); do
      if [[ "${users[j]}" == "${candidate_users[i]}" ]]; then
        (( user_counts[j] += 1 ))
        found=1
        break
      fi
    done
    if (( ! found )); then
      users+=("${candidate_users[i]}")
      user_counts+=(1)
    fi
  done

  printf '\nFound %d old Notes stores, grouped by macOS user and snapshot month.\n' "$total"
  for (( i=0; i<${#users[@]}; i++ )); do
    user_labels+=("${users[i]} — ${user_counts[i]} copies")
  done
  select_paged_menu 'Choose the original macOS user' "${user_labels[@]}"
  chosen_user=${users[menu_choice]}

  for (( i=total-1; i>=0; i-- )); do
    [[ "${candidate_users[i]}" == "$chosen_user" ]] || continue
    found=0
    for (( j=0; j<${#months[@]}; j++ )); do
      if [[ "${months[j]}" == "${candidate_months[i]}" ]]; then
        (( month_counts[j] += 1 ))
        found=1
        break
      fi
    done
    if (( ! found )); then
      months+=("${candidate_months[i]}")
      month_counts+=(1)
    fi
  done

  for (( i=0; i<${#months[@]}; i++ )); do
    month_labels+=("${months[i]} — ${month_counts[i]} copies")
  done
  select_paged_menu "User: $chosen_user — choose snapshot month" "${month_labels[@]}"
  chosen_month=${months[menu_choice]}

  for (( i=total-1; i>=0; i-- )); do
    if [[ "${candidate_users[i]}" == "$chosen_user" && "${candidate_months[i]}" == "$chosen_month" ]]; then
      matching_indices+=("$i")
      snapshot_labels+=("${candidate_labels[i]}")
    fi
  done
  select_paged_menu "User: $chosen_user | $chosen_month — choose Notes copy" "${snapshot_labels[@]}"
  index=${matching_indices[menu_choice]}
  source_dir=${candidates[index]}
}

mount_time_machine_backups() {
  local line mount_point mounted_output mounted_any=0
  local destinations=() previous
  command -v sudo >/dev/null 2>&1 || fail 'sudo is unavailable; cannot mount Time Machine snapshots.'
  command -v tmutil >/dev/null 2>&1 || fail 'tmutil is unavailable; cannot mount Time Machine snapshots.'

  printf '\nAPFS backup snapshots are currently unmounted.\n'
  printf 'Terminal needs Full Disk Access (System Settings > Privacy & Security).\n'
  printf 'Mounting with sudo tmutil may mount MANY read-only backup snapshots.\n'
  printf 'This does not alter the contents of Time Machine, but changes mount state.\n'
  printf 'Type MOUNT to approve the administrator prompt (anything else skips): '
  IFS= read -r mount_answer || mount_answer=''
  [[ "$mount_answer" == MOUNT ]] || { printf 'Skipped mounting Time Machine.\n'; return 0; }

  # tmutil -m needs the destination volume's mount point, not the .timemachine
  # UUID path printed by tmutil listbackups without -m.
  while IFS= read -r line; do
    case "$line" in
      *'Mount Point'*:*)
        mount_point=${line#*:}
        mount_point=${mount_point#"${mount_point%%[![:space:]]*}"}
        mount_point=${mount_point%"${mount_point##*[![:space:]]}"}
        [[ "$mount_point" == /* && -d "$mount_point" ]] || continue
        for previous in "${destinations[@]}"; do
          [[ "$previous" != "$mount_point" ]] || continue 2
        done
        destinations+=("$mount_point")
        ;;
    esac
  done < <(tmutil destinationinfo 2>/dev/null)

  if (( ${#destinations[@]} == 0 )); then
    printf 'No mounted Time Machine destination found (check tmutil destinationinfo).\n' >&2
    return 0
  fi

  for mount_point in "${destinations[@]}"; do
    printf 'Requesting mounted backup paths from: %s\n' "$mount_point"
    if mounted_output=$(sudo tmutil listbackups -d "$mount_point" -m); then
      mounted_any=1
      while IFS= read -r line; do
        scan_snapshot_path "$line"
      done <<< "$mounted_output"
    else
      printf 'Could not mount snapshots on %s; check Terminal Full Disk Access.\n' "$mount_point" >&2
    fi
  done
  (( mounted_any )) || printf 'No Time Machine destinations could be mounted.\n' >&2
}

if [[ -n "$source_hint" ]]; then
  [[ -d "$source_hint" && -s "$source_hint/NoteStore.sqlite" ]] || \
    fail 'The --source directory does not contain a nonempty NoteStore.sqlite.'
  add_candidate "$source_hint"
elif [[ -n "$backup_root" ]]; then
  [[ -d "$backup_root" ]] || fail "Backup root not found: $backup_root"
  case "$backup_root" in
    /|/Users|/Volumes|/System|/Library|/Applications|/private)
      fail 'Choose ONE snapshot or extracted backup, not a system/volume root.' ;;
  esac
  backup_root=$(cd "$backup_root" && pwd -P)
  [[ "${backup_root%/*}" != '/Volumes' ]] || \
    fail 'Select an individual Time Machine snapshot, not the entire backup volume.'
  [[ "$backup_root" != "$user_home" && "$backup_root" != "$user_home/Library" ]] || \
    fail 'Do not scan the live home folder as a backup.'
  printf 'Searching the selected backup for Notes stores...\n'
  scan_tree "$backup_root"
else
  printf 'Searching extracted copies on Desktop and in Downloads...\n'
  scan_tree "$user_home/Desktop"
  scan_tree "$user_home/Downloads"

  unmounted_snapshots=0
  if command -v tmutil >/dev/null 2>&1; then
    printf 'Checking Time Machine snapshots...\n'
    if snapshots_output=$(tmutil listbackups 2>&1); then
      while IFS= read -r snapshot; do
        [[ "$snapshot" == /* ]] || continue
        if [[ -d "$snapshot" ]]; then
          scan_snapshot_path "$snapshot"
        else
          (( unmounted_snapshots += 1 ))
        fi
      done <<< "$snapshots_output"
    else
      printf 'Time Machine listing failed: %s\n' "$snapshots_output" >&2
      printf 'Check Terminal Full Disk Access, then quit and reopen Terminal.\n' >&2
    fi
  fi

  if (( unmounted_snapshots > 0 )); then
    printf 'Time Machine lists %d snapshots whose paths are not mounted.\n' "$unmounted_snapshots"
  fi
  if (( mount_time_machine )) || (( unmounted_snapshots > 0 && ${#candidates[@]} == 0 && ! dry_run )); then
    mount_time_machine_backups
  elif (( unmounted_snapshots > 0 && dry_run )); then
    printf 'To include unmounted snapshots, rerun with --mount-time-machine --dry-run.\n'
  fi
fi

(( ${#candidates[@]} > 0 )) || fail 'No saved Notes store found. Use --mount-time-machine for unmounted Time Machine snapshots, or --backup-root / --source for an extracted copy.'

choose_source

[[ "$source_dir" != "$target_real" ]] || fail 'Source and current Notes folder are the same.'
if [[ -n "$target_real" ]]; then
  case "$source_dir" in
    "$target_real"/*) fail 'Source is inside the current Notes folder.' ;;
  esac
fi
case "$backup_base" in
  /|/Users|/Volumes|/System|/Library)
    fail 'Choose a specific writable backup folder, not a system or disk root.' ;;
  "$target"|"$target"/*|"$source_dir"|"$source_dir"/*)
    fail 'Safety backups cannot be stored inside source/current Notes.' ;;
esac
[[ "$backup_base" == /* ]] || fail '--backup-dir must be an absolute directory.'
if [[ -d "$backup_base" ]]; then
  backup_base_real=$(cd "$backup_base" && pwd -P)
  case "$backup_base_real" in
    "$source_dir"|"$source_dir"/*)
      fail 'Safety-backup directory resolves inside a Notes source/target.' ;;
  esac
  if [[ -n "$target_real" ]]; then
    case "$backup_base_real" in
      "$target_real"|"$target_real"/*)
        fail 'Safety-backup directory resolves inside the current Notes folder.' ;;
    esac
  fi
fi

printf '\nOld Notes source: %s\n' "$source_dir"
printf 'Current Notes target: %s\n' "$target"
printf 'Safety backup parent: %s\n' "$backup_base"
printf 'This will REPLACE the full Notes group container, not merge individual notes.\n'
printf 'It may affect accounts synchronized through iCloud. If those notes matter,\n'
printf 'go offline and confirm you have a separate backup before continuing.\n'

if (( dry_run )); then
  printf '\nDRY RUN: no Notes data copied, deleted, moved, or opened.\n'
  exit 0
fi

printf '\nType MIGRATE to back up your current Notes and install the old copy: '
IFS= read -r confirmation
[[ "$confirmation" == MIGRATE ]] || { printf 'Cancelled without changes.\n'; exit 0; }

if pgrep -x Notes >/dev/null 2>&1; then
  printf 'Requesting Notes to quit gracefully...\n'
  osascript -e 'tell application "Notes" to quit' || fail 'Could not ask Notes to quit.'
  for (( wait_count=0; wait_count<10; wait_count++ )); do
    if ! pgrep -x Notes >/dev/null 2>&1; then break; fi
    sleep 1
  done
fi
pgrep -x Notes >/dev/null 2>&1 && fail 'Notes is still running. Quit it manually and retry.'

# The Notes background agent may hold SQLite WAL files open after the app quits.
if pgrep -x notesd >/dev/null 2>&1; then
  printf 'Stopping the Notes background agent after the app has quit...\n'
  killall -TERM notesd 2>/dev/null || fail 'Could not stop notesd; aborting before replacing data.'
fi

[[ -d "$backup_base" ]] || mkdir -p "$backup_base"
backup_dir=$(mktemp -d "${backup_base%/}/notes-$(date +%Y%m%d-%H%M%S).XXXXXX") || \
  fail 'Could not create a safety-backup directory.'
stage_dir=''
stage_workspace=''
previous_dir=''
moved_old=0
installed_new=0

cleanup() {
  local status
  status=$1
  trap - EXIT
  if (( moved_old && ! installed_new )); then
    if [[ ! -e "$target" && -d "$previous_dir" ]]; then
      if mv "$previous_dir" "$target"; then
        printf '\nROLLBACK: the original Notes folder was restored.\n' >&2
      else
        printf '\nCRITICAL: rollback failed. Original Notes folder remains at: %s\n' "$previous_dir" >&2
      fi
    fi
  fi
  if [[ -n "$stage_workspace" && -d "$stage_workspace" ]]; then
    case "$stage_workspace" in
      "$target_parent"/.notes-migrator-stage.*) rm -rf "$stage_workspace" ;;
    esac
  fi
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Work only on a copy. SQLite may need to read its WAL and create an SHM file.
stage_workspace=$(mktemp -d "$target_parent/.notes-migrator-stage.XXXXXX") || \
  fail 'Could not make a staging directory beside Notes.'
stage_dir="$stage_workspace/group.com.apple.notes"
printf 'Copying old Notes into an isolated staging directory...\n'
ditto --rsrc "$source_dir" "$stage_dir" || fail 'Could not copy the old Notes folder.'
[[ -s "$stage_dir/NoteStore.sqlite" ]] || fail 'Staged Notes database is missing.'
check=$(sqlite3 -readonly "$stage_dir/NoteStore.sqlite" 'PRAGMA quick_check;' 2>&1) || \
  fail "Staged database failed SQLite validation: $check"
[[ "$check" == ok ]] || fail "Staged database failed SQLite validation: $check"

if [[ -d "$target" ]]; then
  printf 'Backing up the current Notes folder...\n'
  ditto --rsrc "$target" "$backup_dir/current-group.com.apple.notes" || \
    fail 'Could not complete the current Notes backup. No replacement attempted.'
  [[ -d "$backup_dir/current-group.com.apple.notes" ]] || fail 'Safety backup did not appear.'
else
  printf 'No current Notes folder exists; recording a fresh restore.\n'
fi

previous_dir="$target_parent/.group.com.apple.notes.pre-migration-$(date +%Y%m%d-%H%M%S)-$$"
[[ ! -e "$previous_dir" ]] || fail "Temporary previous-folder path already exists: $previous_dir"
if [[ -d "$target" ]]; then
  mv "$target" "$previous_dir" || fail 'Could not move the current Notes folder aside.'
  moved_old=1
fi
mv "$stage_dir" "$target" || fail 'Could not install the staged Notes folder.'
stage_dir=''
installed_new=1

printf '\nMIGRATION COMPLETE.\n'
printf 'Safety backup: %s\n' "$backup_dir"
if (( moved_old )); then
  printf 'Original folder also preserved at: %s\n' "$previous_dir"
fi
printf 'Check the On My Mac notes, folders and attachments before removing backups.\n'
if (( ! no_open )); then
  open -a Notes || printf 'Could not open Notes automatically; open it manually.\n' >&2
fi
