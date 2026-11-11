#!/bin/bash
# The transaction must leave the original destination intact on failure.
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd -P)
temp_parent=${TMPDIR:-/tmp}
[[ -d "$temp_parent" && -w "$temp_parent" ]] || temp_parent=$project_dir
fixture_root=$(mktemp -d "${temp_parent%/}/notes-migrator-test.XXXXXX")
fixture_root=$(cd "$fixture_root" && pwd -P)
trap 'rm -rf "$fixture_root"' EXIT
mock_bin="$project_dir/tests/mocks"

fake_home="$fixture_root/home"
current="$fake_home/Library/Group Containers/group.com.apple.notes"
source_dir="$fake_home/Desktop/old/group.com.apple.notes"
mkdir -p "$current" "$source_dir"
printf 'CURRENT DATABASE\n' > "$current/NoteStore.sqlite"
printf 'OLD DATABASE\n' > "$source_dir/NoteStore.sqlite"
export MOCK_FAIL_MARKER="$fixture_root/mv-failed-once"
export MOCK_OPEN_LOG="$fixture_root/open.log"
export MOCK_TM_BACKUPS="$fixture_root/tm-list.txt"
: > "$MOCK_OPEN_LOG"
: > "$MOCK_TM_BACKUPS"

run_migrator() {
  env PATH="$mock_bin:$PATH" NOTES_MIGRATOR_TEST_HOME="$fake_home" \
    MOCK_FAIL_MARKER="$MOCK_FAIL_MARKER" MOCK_OPEN_LOG="$MOCK_OPEN_LOG" \
    MOCK_TM_BACKUPS="$MOCK_TM_BACKUPS" "$@" \
    bash "$project_dir/macos-notes-migrator.sh" --source "$source_dir"
}

# Wrong confirmation does nothing.
output=$(printf 'NO\n' | run_migrator env 2>&1)
[[ "$output" == *'Cancelled without changes'* ]] || exit 1
grep -q '^CURRENT DATABASE$' "$current/NoteStore.sqlite"
[[ ! -d "$fake_home/Documents/NotesMigratorBackups" ]] || exit 1

# A corrupt source copy must fail without moving the current Notes folder.
if output=$(printf 'MIGRATE\n' | run_migrator env MOCK_BAD_SQLITE=1 2>&1); then
  printf 'Corrupt SQLite was unexpectedly accepted.\n' >&2
  exit 1
fi
grep -q '^CURRENT DATABASE$' "$current/NoteStore.sqlite"

# Simulate failure of the exact staging-directory rename; EXIT must roll back.
if output=$(printf 'MIGRATE\n' | run_migrator env MOCK_FAIL_INSTALL=1 2>&1); then
  printf 'Simulated install failure unexpectedly succeeded.\n' >&2
  exit 1
fi
grep -q '^CURRENT DATABASE$' "$current/NoteStore.sqlite" || {
  printf 'Original Notes not restored after rename failure.\n' >&2
  exit 1
}
[[ "$output" == *'ROLLBACK'* ]] || {
  printf 'Rollback was not reported.\n' >&2
  exit 1
}
[[ ! -s "$MOCK_OPEN_LOG" ]] || { printf 'Notes opened after a failed transaction.\n' >&2; exit 1; }

printf 'PASS: cancelled run, invalid SQLite refusal, and transactional rename rollback.\n'
