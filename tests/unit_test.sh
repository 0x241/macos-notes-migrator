#!/bin/bash
# End-to-end simulation. No real Notes account, backup or SQLite data is read.
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd -P)
temp_parent=${TMPDIR:-/tmp}
[[ -d "$temp_parent" && -w "$temp_parent" ]] || temp_parent=$project_dir
fixture_root=$(mktemp -d "${temp_parent%/}/notes-migrator-test.XXXXXX")
fixture_root=$(cd "$fixture_root" && pwd -P)
trap 'rm -rf "$fixture_root"' EXIT

mock_bin="$project_dir/tests/mocks"
export MOCK_OPEN_LOG="$fixture_root/open.log"
export MOCK_TM_BACKUPS="$fixture_root/tm-list.txt"
export MOCK_TM_SUDO_LOG="$fixture_root/tm-sudo.log"
: > "$MOCK_OPEN_LOG"
: > "$MOCK_TM_BACKUPS"
: > "$MOCK_TM_SUDO_LOG"

make_case() {
  local name=$1 fake_home current saved
  fake_home="$fixture_root/$name/home"
  current="$fake_home/Library/Group Containers/group.com.apple.notes"
  saved="$fake_home/Desktop/old/group.com.apple.notes"
  mkdir -p "$current/Accounts/LocalAccount" "$saved/Accounts/LocalAccount"
  printf 'CURRENT DATABASE\n' > "$current/NoteStore.sqlite"
  printf 'CURRENT ATTACHMENT\n' > "$current/Accounts/LocalAccount/current.txt"
  printf 'OLD DATABASE\n' > "$saved/NoteStore.sqlite"
  printf 'OLD WAL\n' > "$saved/NoteStore.sqlite-wal"
  printf 'OLD ATTACHMENT\n' > "$saved/Accounts/LocalAccount/old.txt"
}

run_migrator() {
  local fake_home=$1
  shift
  env PATH="$mock_bin:$PATH" NOTES_MIGRATOR_TEST_HOME="$fake_home" \
    MOCK_OPEN_LOG="$MOCK_OPEN_LOG" MOCK_TM_BACKUPS="$MOCK_TM_BACKUPS" \
    MOCK_TM_SUDO_LOG="$MOCK_TM_SUDO_LOG" \
    bash "$project_dir/macos-notes-migrator.sh" "$@"
}

# Dry run must never create a backup or change either database.
make_case dry
dry_home="$fixture_root/dry/home"
dry_output=$(run_migrator "$dry_home" --dry-run)
[[ "$dry_output" == *'DRY RUN'* ]] || exit 1
grep -q '^CURRENT DATABASE$' "$dry_home/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
[[ ! -e "$dry_home/Documents/NotesMigratorBackups" ]] || exit 1

# One command, one source, explicit confirmation, full backup and installation.
make_case success
success_home="$fixture_root/success/home"
if ! output=$(printf 'MIGRATE\n' | run_migrator "$success_home" 2>&1); then
  printf 'Unexpected migration failure:\n%s\n' "$output" >&2
  exit 1
fi
target="$success_home/Library/Group Containers/group.com.apple.notes"
grep -q '^OLD DATABASE$' "$target/NoteStore.sqlite"
grep -q '^OLD WAL$' "$target/NoteStore.sqlite-wal"
grep -q '^OLD ATTACHMENT$' "$target/Accounts/LocalAccount/old.txt"

backup_files=("$success_home"/Documents/NotesMigratorBackups/notes-*/current-group.com.apple.notes/NoteStore.sqlite)
[[ -f "${backup_files[0]}" ]] || { printf 'Current Notes backup missing.\n' >&2; exit 1; }
grep -q '^CURRENT DATABASE$' "${backup_files[0]}"
previous_files=("$success_home"/Library/'Group Containers'/.group.com.apple.notes.pre-migration-*/NoteStore.sqlite)
[[ -f "${previous_files[0]}" ]] || { printf 'Original Notes folder not preserved.\n' >&2; exit 1; }
[[ -s "$MOCK_OPEN_LOG" ]] || { printf 'Expected Notes to open after success.\n' >&2; exit 1; }

# A source picked from a snapshot root must also be found, without moving files.
make_case snapshot
snapshot_home="$fixture_root/snapshot/home"
snapshot_root="$fixture_root/Time Machine/one snapshot"
snapshot_store="$snapshot_root/System Volume/Users/${USER:-sample-account}/Library/Group Containers/group.com.apple.notes"
mkdir -p "$snapshot_store"
printf 'SNAPSHOT DATABASE\n' > "$snapshot_store/NoteStore.sqlite"
snapshot_output=$(run_migrator "$snapshot_home" --backup-root "$snapshot_root" --dry-run)
[[ "$snapshot_output" == *"$snapshot_store"* ]] || exit 1

# The no-argument command should find accessible paths from tmutil too.
tm_home="$fixture_root/tm/home"
mkdir -p "$tm_home/Library/Group Containers"
printf '%s\n' "$snapshot_root" > "$MOCK_TM_BACKUPS"
tm_output=$(run_migrator "$tm_home" --dry-run)
[[ "$tm_output" == *"Old Notes source: $snapshot_store"* ]] || exit 1
: > "$MOCK_TM_BACKUPS"

# tmutil can list APFS snapshots that are not mounted at their listed paths.
# Explicit mounting must ask for consent and only then invoke sudo tmutil -m.
unmounted_home="$fixture_root/unmounted/home"
mkdir -p "$unmounted_home/Library/Group Containers"
fake_tm_volume="$fixture_root/Test Backup Disk"
mkdir -p "$fake_tm_volume"
printf '%s\n' '/Volumes/.timemachine/missing-uuid/2025-03-05.backup/2025-03-05.backup' > "$MOCK_TM_BACKUPS"
if run_migrator "$unmounted_home" --dry-run > "$fixture_root/unmounted-dry.txt" 2>&1; then
  printf 'Expected dry run without mounting to refuse unmounted snapshots.\n' >&2
  exit 1
fi
[[ ! -s "$MOCK_TM_SUDO_LOG" ]] || exit 1
grep -q -- '--mount-time-machine' "$fixture_root/unmounted-dry.txt"
mounted_result=$(printf 'MOUNT\n' | env MOCK_TM_MOUNT_POINT="$fake_tm_volume" \
  MOCK_TM_MOUNTED_BACKUPS="$snapshot_root" \
  PATH="$mock_bin:$PATH" NOTES_MIGRATOR_TEST_HOME="$unmounted_home" \
  bash "$project_dir/macos-notes-migrator.sh" --mount-time-machine --dry-run)
[[ "$mounted_result" == *"Old Notes source: $snapshot_store"* ]] || exit 1
[[ "$mounted_result" == *'DRY RUN'* ]] || exit 1
grep -q 'listbackups.*-m' "$MOCK_TM_SUDO_LOG"
: > "$MOCK_TM_BACKUPS"

# Multiple copies must require a choice, rather than guessing the latest one.
make_case choices
choices_home="$fixture_root/choices/home"
second_store="$choices_home/Downloads/another/group.com.apple.notes"
mkdir -p "$second_store"
printf 'SECOND DATABASE\n' > "$second_store/NoteStore.sqlite"
choices_output=$(printf '01\n' | run_migrator "$choices_home" --dry-run)
[[ "$choices_output" == *'Found 2 old Notes stores'* ]] || exit 1
[[ "$choices_output" == *"Old Notes source: $second_store"* ]] || exit 1

# A 27-snapshot history should be grouped by user, then month, with ten
# compact dated entries per page. Selecting page two must resolve the true path.
history_home="$fixture_root/history/home"
mkdir -p "$history_home/Library/Group Containers"
expected_snapshot=''
fake_users_dir=Users
for month in 2025-03 2026-10; do
  case "$month" in
    2025-03) end_day=14 ;;
    2026-10) end_day=12 ;;
  esac
  for (( day=1; day<=end_day; day++ )); do
    printf -v two_digit_day '%02d' "$day"
    snapshot_stamp="${month}-${two_digit_day}-010101"
    dated_root="$fixture_root/Time Machine/${snapshot_stamp}.backup/${snapshot_stamp}.backup/Macintosh HD - Data"
    dated_store="$dated_root/$fake_users_dir/old-user/Library/Group Containers/group.com.apple.notes"
    mkdir -p "$dated_store"
    printf 'HISTORY DATABASE\n' > "$dated_store/NoteStore.sqlite"
    printf '%s\n' "${dated_root%/Macintosh HD - Data}" >> "$MOCK_TM_BACKUPS"
    if [[ "$snapshot_stamp" == 2026-10-02-010101 ]]; then
      expected_snapshot=$dated_store
    fi
  done
done
second_user_root="$fixture_root/Time Machine/2026-11-01-010101.backup/2026-11-01-010101.backup/Data"
second_user_store="$second_user_root/$fake_users_dir/second-user/Library/Group Containers/group.com.apple.notes"
mkdir -p "$second_user_store"
printf 'SECOND USER DATABASE\n' > "$second_user_store/NoteStore.sqlite"
printf '%s\n' "${second_user_root%/Data}" >> "$MOCK_TM_BACKUPS"

history_output=$(printf '2\n1\nn\np\nn\n11\n' | run_migrator "$history_home" --dry-run)
[[ "$history_output" == *'Found 27 old Notes stores'* ]] || exit 1
[[ "$history_output" == *'old-user — 26 copies'* ]] || exit 1
[[ "$history_output" == *'2026-10 — 12 copies'* ]] || exit 1
[[ "$history_output" == *'(page 2/2)'* ]] || exit 1
[[ "$history_output" == *"Old Notes source: $expected_snapshot"* ]] || exit 1
if printf '0\n' | run_migrator "$history_home" --dry-run > "$fixture_root/history-cancel.txt" 2>&1; then
  printf 'Group selection cancellation should never select a source.\n' >&2
  exit 1
fi
grep -q 'Cancelled' "$fixture_root/history-cancel.txt"
: > "$MOCK_TM_BACKUPS"

# A brand-new Notes account may have a Group Containers parent, but no store.
empty_home="$fixture_root/empty/home"
empty_source="$empty_home/Desktop/old/group.com.apple.notes"
mkdir -p "$empty_home/Library/Group Containers" "$empty_source"
printf 'OLDER DATABASE\n' > "$empty_source/NoteStore.sqlite"
empty_output=$(run_migrator "$empty_home" --dry-run)
[[ "$empty_output" == *'DRY RUN'* ]] || exit 1

printf 'PASS: APFS discovery, consent, grouped/paged selection, dry run, backup, migration and attachments.\n'
