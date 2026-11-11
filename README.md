# macOS Notes Migrator

**Move local Apple Notes from a macOS Time Machine backup (or an extracted copy) into the current Mac — with automatic source discovery, a full safety backup, and rollback protection.**

> **v1.0.0.** The underlying full-folder recovery method worked in one real Ventura → Tahoe migration, but these automated workflows have only been exercised with simulated macOS commands and test SQLite databases. Notes uses a private database format; success across different macOS versions and iCloud account configurations is **not guaranteed**. Not affiliated with Apple or Softvoile.

## One command

Unpack the ZIP and run from its parent directory:

```bash
bash macos-notes-migrator/macos-notes-migrator.sh
```

The script searches for complete `group.com.apple.notes` folders in:

- Extracted copies under `~/Desktop` and `~/Downloads`.
- Already mounted Time Machine snapshots returned by `tmutil listbackups`.

On APFS, `tmutil listbackups` may print a snapshot path that does **not yet exist** in `/Volumes/.timemachine/`. This is normal: the snapshot has not been mounted. If no extracted or mounted Notes copy is found, the script detects this and **offers to mount snapshots** using the supported `sudo tmutil listbackups -d <destination> -m` mechanism. It explicitly requires you to type `MOUNT` before the administrator-password prompt.

If it finds more than one, **you select the correct snapshot**. This matters when the latest backup belongs to the new OS rather than the older system containing the missing notes.

### Choosing from a long snapshot history

The source selector groups copies by **original macOS user → backup month → snapshot date/time**. For a large history (for example, 64 copies), the menu shows only **10 entries per page**:

- Enter a visible number to select an item.
- Enter `n` for the next page or `p` for the previous page.
- Enter `0` to cancel.

Single-choice user and month groups are selected automatically. Time Machine snapshots are shown with the newest discovered entries first; undated extracted copies are labeled by their Desktop/Downloads location. **After selecting a copy, the full original path is displayed** before `MIGRATE` can be entered. Neither the newest snapshot nor any other copy is installed automatically.

### Read unmounted Time Machine backups

1. Connect and unlock your Time Machine backup disk.
2. Open **System Settings → Privacy & Security → Full Disk Access**. Enable **Terminal** (or the terminal app you actually run). If it is missing, add it with `+`. Quit and reopen that app for the permission to apply.
3. Run this **single command** from the directory containing the unpacked ZIP:

   ```bash
   bash macos-notes-migrator/macos-notes-migrator.sh --mount-time-machine
   ```

4. Read the warning, type `MOUNT`, and enter the macOS administrator password at the system `sudo` prompt. Mounting can take a while when there are many snapshots.
5. Choose the Notes copy by path/date, then type `MIGRATE` only after reviewing the source, target, and planned backup.

**The script itself must not be run with `sudo`.** Only the Time Machine mounting step uses elevated privileges. Mounting snapshots can change their mount state but does not rewrite backup data; the tool never issues Time Machine deletion commands.

If `tmutil destinationinfo` shows no mounted destination, attach/mount your backup disk first. The script cannot safely invent the disk's mount point.

To search a particular snapshot or manually extracted backup instead:

```bash
bash macos-notes-migrator/macos-notes-migrator.sh --backup-root "/Volumes/Backup/selected-snapshot"
```

Or provide the exact saved directory:

```bash
bash macos-notes-migrator/macos-notes-migrator.sh --source "$HOME/Desktop/old/group.com.apple.notes"
```

You can inspect what would be transferred without changing anything:

```bash
bash macos-notes-migrator/macos-notes-migrator.sh --dry-run
```

To include **unmounted** Time Machine snapshots in the preview, use `--mount-time-machine --dry-run`. It still explicitly asks before mounting and may leave the read-only snapshots mounted, but **does not replace or copy any Notes data**.

## Import a Flashnote database (experimental)

This separate mode supports the Windows [Flashnote](https://softvoile.com/flashnote) SQLite database with a `notes3` table. The names visible in an extracted Windows backup are typically:

- `AppData/Roaming/Flashnote/notes2.db` — the current Flashnote database.
- `AppData/Roaming/Flashnote/backup/notes2 backup YYYY-MM-DD HH-MM.db` — dated Flashnote backups.

To **preview without writing files or altering Notes**, unpack the ZIP and run:

```bash
bash macos-notes-migrator/macos-notes-migrator.sh --import-flashnote --dry-run
```

By default the Flashnote mode searches for these filenames in:

- Your **home folder**, including Desktop, Downloads, Documents and other personal directories.
- **Mounted external volumes** beneath `/Volumes` (the system root and hidden housekeeping volumes are excluded).
- **Already-mounted Time Machine backup snapshots** returned by `tmutil listbackups`, concentrating on user Desktop, Downloads, Documents, AppData and Application Support locations. Unmounted snapshots are reported and skipped; **the Flashnote mode never mounts backups or invokes sudo**.

The search follows nested ordinary directories, even when `notes2.db` has been copied straight onto the Desktop and no `Flashnote` parent folder exists. It prunes system/cache/build directories, does not follow symlinked subdirectories, and stops after 40,000 inspected directories, 500,000 filenames or roughly 75 seconds. If the cap is reached, it explicitly warns that the results are incomplete. It offers a numbered source selector if multiple matches are found. Candidate SQLite files must have a valid Flashnote `notes3` schema before their contents can be exported.

For a faster or more exhaustive search of a specific location, specify its root folder:

```bash
bash macos-notes-migrator/macos-notes-migrator.sh --import-flashnote \
  --flashnote-root "/path/to/AppData/Roaming/Flashnote" --dry-run
```

Or use one exact historical database:

```bash
bash macos-notes-migrator/macos-notes-migrator.sh --import-flashnote \
  --flashnote-db "/path/to/notes2 backup 2015-08-03 03-38.db"
```

Without `--dry-run`, the importer asks you to type **`EXPORT`**. It makes a new *local* directory inside `~/Documents/NotesMigratorBackups/FlashnoteExports/`:

```text
flashnote-.../
  Import to Notes/
    Original folder/
      Child folder/
        Some note.txt
  flashnote-manifest.json
```

The source SQLite database is opened **read-only**. A row's `pid` defines its parent; rows with children become folders. If such a parent also contains text, its content becomes a note inside that folder. Leaf rows become text notes. Trashed nodes and their descendants are excluded. Names are preserved where possible, and name clashes receive a unique Flashnote ID suffix. The manifest records original IDs, types and timestamps for later auditing. Unresolved parent IDs become top-level entries and are counted in the preview.

**Final step in Apple Notes:** Open Notes, select a folder within the intended account (**On My Mac** or **iCloud**), use **File → Import to Notes**, choose the generated **Import to Notes** folder, and enable **Preserve folder structure on import**. Apple officially supports importing `.txt` folders while preserving folder structure. This step is intentionally manual for the experimental release: conversion does **not** write to, replace or delete your existing Apple Notes store.

### Choose the Apple Notes account (`--notes-account`)

The Flashnote conversion supports `--notes-account local`, `--notes-account icloud`, or `--notes-account ask` (the default, interactive). This **does not change the ENEX file** and **cannot force Apple Notes to select a destination account**. It gives clear instructions for choosing a folder in the requested account **before** using the native import menu. Apple documents this choice in [Import notes on Mac](https://support.apple.com/guide/notes/import-export-and-print-notes-not201900c07/mac).

To prepare the ENEX for **On My Mac**, with original Flashnote dates:

```bash
bash macos-notes-migrator/macos-notes-migrator.sh --import-flashnote \
  --flashnote-db "/path/to/notes2.db" --flashnote-format enex \
  --notes-account local
```

To prepare it for iCloud, change `local` to `icloud`. For interactive choice, omit the option. The script reveals (rather than opens) ENEX in Finder to avoid accidentally launching import under the previously selected account. **Select the correct folder in Notes yourself**; repeated imports create duplicates.

### Preserve Flashnote dates (ENEX)


**TXT import creates new Apple Notes entries with today's dates.** Flashnote's original `created` and `modified` fields are present in the source database, and the converter now offers a second output format, Evernote `.enex`, that embeds them in each imported note. Apple Notes officially accepts ENEX, and a Ventura → Tahoe user test confirmed that original dates were retained for an ENEX sample. Other Notes versions and source date conventions may behave differently.

If you've already imported 135 notes as TXT, **first test exactly one note** (this does not modify the previous import):

```bash
bash macos-notes-migrator/macos-notes-migrator.sh --import-flashnote \
  --flashnote-db "$HOME/Desktop/notes2.db" --flashnote-format enex --flashnote-limit 1
```

After typing `EXPORT`, use **Notes → File → Import to Notes** to select the generated `Flashnote-date-test.enex`. Open that new note, click the date displayed at the top, and check **Created** and **Edited** dates against the two timestamps printed in `flashnote-manifest.json`. The sample is always the first exportable record in the original tree ordering; it is not a random note. If the dates match, prepare all notes:

```bash
bash macos-notes-migrator/macos-notes-migrator.sh --import-flashnote \
  --flashnote-db "$HOME/Desktop/notes2.db" --flashnote-format enex
```

Select the newly generated `Flashnote.enex` for import. Importing does **not** update existing TXT-imported notes: it makes **new duplicates**. Keep the existing imported folder intact until you've checked the ENEX batch; only then, if appropriate, manually delete the old imported folder. The tool **never deletes or edits** existing Apple Notes entries.

ENEX cannot carry Flashnote's folder hierarchy. If your database has subfolders, the converter flattens them and puts ancestor folder names in the note titles; the default TXT mode still preserves folders. Flashnote's SQLite `CURRENT_TIMESTAMP` defaults to UTC, so naive timestamps are interpreted as UTC when encoding ENEX. A database produced with a different local-time convention may show a clock offset. The source timestamps are preserved verbatim in the manifest for verification. A malformed date aborts conversion instead of silently substituting today.

The `type` field's precise mapping to Flashnote folder/note kinds is not publicly documented. Therefore the converter follows the `id`/`pid` hierarchy rather than guessing `type` codes. Empty leaf rows are imported as empty notes; if your Flashnote database used empty leaf rows for empty folders, those require review. Original display order and creation/modification times may not carry over into Apple Notes, though timestamps are retained in the manifest and can optionally be embedded in an ENEX import (see above). Encrypted/proprietary `.db` files are refused rather than guessed at. Review the generated folder tree before importing and take a separate backup of existing Apple Notes if needed.

Flashnote conversion requires **Python 3.9+** with its standard `sqlite3` module. No third-party Python packages are needed. `--no-open` avoids opening Finder after preparing the export; `--flashnote-output DIR` sets a different export parent.

## What happens after confirmation

1. Prints the detected source and the current `~/Library/Group Containers/group.com.apple.notes` destination.
2. Warns that the operation **replaces the entire local Notes store**, rather than merging individual notes, and waits for `MIGRATE`.
3. Requests a graceful quit of Notes and stops its background agent.
4. Copies the entire old Notes folder into an isolated staging directory. Verifies the copied `NoteStore.sqlite` with SQLite `PRAGMA quick_check`.
5. Makes a **complete copy of your current Notes folder** in `~/Documents/NotesMigratorBackups/notes-.../current-group.com.apple.notes`.
6. Moves today's Notes folder aside (retained as `.group.com.apple.notes.pre-migration-...`) and atomically installs the old folder in its place.
7. Restores the moved-aside current folder if installation fails, then opens Notes.

All attachments and SQLite journal sidecars are copied with the entire folder. **Nothing is exported to a plaintext file or sent over the network by this tool.**

## Important safety limits

- **On My Mac notes** are local to the device and do not appear on other Apple devices. The migrator is intended primarily for those local notes. It is not an iCloud note-merging tool.
- Replacing the entire store also replaces local metadata and cached iCloud note state. **If you have important current/iCloud notes, do not blindly migrate.** Consider going offline for the recovery, and export important current notes before proceeding.
- `PRAGMA quick_check` verifies SQLite integrity, **not** that a newer Notes app will accept the database or preserve all account relationships. Always visually check your notes, folders and attachments after the migration.
- If Terminal cannot read your Time Machine backup, give it **Full Disk Access** in macOS Privacy & Security and retry. `tmutil -m` additionally requires administrator authorization for mounting; do not run the entire tool with `sudo`.
- Ensure enough disk space for a staged copy of the old data plus backup copies of the current data. The original snapshot is never modified.
- The script keeps both backups intentionally. **Do not delete them until you have checked Notes.**
- Do not force-quit Terminal or reboot during the short final directory swap. A `SIGKILL` or power loss cannot run the automatic rollback, but the previous folder is retained next to the destination for manual recovery.
- `--mount-time-machine` can mount many backups in one request and does not automatically unmount them. Alternatively, mount/select one snapshot in Finder and pass it to `--backup-root`.

## Reverting

Quit Notes and run the migrator again with `--source` pointing at the saved current folder printed after the original migration:

```bash
bash macos-notes-migrator/macos-notes-migrator.sh --source "/path/to/NotesMigratorBackups/notes-.../current-group.com.apple.notes"
```

It will create another safety backup and ask for confirmation before restoring that state. The hidden `.group.com.apple.notes.pre-migration-...` folder is an additional emergency copy.

## Requirements

- macOS Ventura or newer, with Notes installed.
- A Time Machine backup or extracted folder with `NoteStore.sqlite` under `group.com.apple.notes`.
- macOS command-line tools: `ditto`, `sqlite3`, `tmutil` (for snapshot auto-discovery), `osascript`.

## License

MIT — see [LICENSE](LICENSE).

## Origin and testing

Version 1.0.0 is built from the original v0.2.3 source scripts and tests, with account selection integrated directly into the Flashnote converter. It is **not** the separate reconstructed v0.3.0 implementation. A real Ventura → Tahoe migration demonstrated full-folder Notes restoration, and a real Flashnote sample imported into Tahoe with its source date; CI only simulates the complete automated workflows.

The one-time `publish.sh` is shipped only in the owner-download archive, ignored by Git, and excluded from public release assets.
