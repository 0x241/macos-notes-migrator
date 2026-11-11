#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$project_dir"

files=(README.md LICENSE CHANGELOG.md SECURITY.md .gitignore macos-notes-migrator.sh flashnote-to-notes.py .github/workflows/*.yml tests/*.sh tests/*.py tests/mocks/*)
for file in "${files[@]}"; do
  [[ -f "$file" && ! -L "$file" ]] || { printf 'Bad source file: %s\n' "$file" >&2; exit 1; }
done

path_regex='(/User'
path_regex+='s/[A-Za-z0-9_.-]+/|/ho'
path_regex+='me/[A-Za-z0-9_.-]+/|/work'
path_regex+='space/scratch/)'
if grep -nE "$path_regex" "${files[@]}"; then
  printf 'ERROR: private absolute path in public source.\n' >&2
  exit 1
fi

if find . -type f \( -name 'NoteStore.sqlite*' -o -name '*.keychain-db' \
  -o -name '*.p12' -o -name '*.pem' -o -name '*.enex' -o -name 'notes2*.db' \) -print | grep -q .; then
  printf 'ERROR: private database/credential file found in project.\n' >&2
  exit 1
fi
printf 'PASS: no private Notes database, Keychain, or absolute user path.\n'
