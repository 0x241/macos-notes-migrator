#!/usr/bin/env python3
"""Read a Flashnote notes2.db and stage its tree for Apple Notes' native importer.

No Apple Notes database or application data is written by this tool. The user
performs the final, additive import in the Notes application after inspection.
Standard-library only; compatible with Python 3.9+.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
from html import escape as html_escape
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from time import monotonic
from xml.etree import ElementTree
from xml.sax.saxutils import escape as xml_escape


DB_NAME = re.compile(r"^notes2(?: backup \d{4}-\d{2}-\d{2} \d{2}-\d{2})?\.db$", re.I)
REQUIRED_COLUMNS = {
    "id", "pid", "folderpos", "name", "note", "pos", "created", "modified", "trash", "type"
}
MAX_ROWS = 250_000
MAX_SEARCH_DIRS = 40_000
MAX_SEARCH_FILES = 500_000
MAX_SEARCH_SECONDS = 75
SKIP_DIRS = {
    ".git", ".svn", ".hg", ".Spotlight-V100", ".Trashes", ".fseventsd",
    ".DocumentRevisions-V100", ".timemachine", "node_modules", "__pycache__",
    "Caches", "Cache", "TemporaryItems", "Group Containers", "Containers",
    "System", "Applications", "private", "proc", "dev", "Backups.backupdb",
}


class ImportErrorSafe(Exception):
    """A condition that must abort without touching any Apple Notes data."""


def available_snapshot_roots() -> tuple[list[Path], int]:
    """Read only already-mounted snapshots; never mount or call sudo here."""
    override = os.environ.get("NOTES_MIGRATOR_TEST_TM_FILE")
    if override:
        try:
            listing = Path(override).read_text(encoding="utf-8")
        except OSError:
            return [], 0
    else:
        try:
            completed = subprocess.run(
                ["tmutil", "listbackups"], capture_output=True, text=True,
                check=False, timeout=15,
            )
        except (OSError, subprocess.TimeoutExpired):
            return [], 0
        if completed.returncode:
            return [], 0
        listing = completed.stdout

    roots: list[Path] = []
    unavailable = 0
    for raw in listing.splitlines():
        if not raw.startswith("/"):
            continue
        snapshot = Path(raw)
        if not snapshot.is_dir():
            unavailable += 1
            continue
        # Only look in user-data locations of an APFS/HFS snapshot; a full
        # recursive search of every system file in every snapshot is excessive.
        for pattern in ("Users/*", "*/Users/*", "*/*/Users/*"):
            for user_root in snapshot.glob(pattern):
                if not user_root.is_dir():
                    continue
                roots.append(user_root / "notes2.db")
                for name in ("Desktop", "Downloads", "Documents", "AppData"):
                    roots.append(user_root / name)
                roots.append(user_root / "Library" / "Application Support")
    return roots, unavailable


def default_search_roots(home: Path) -> tuple[list[Path], int]:
    # Prioritize likely locations, then look through the rest of the home.
    roots = [home / "Desktop", home / "Downloads", home / "Documents"]
    volume_parent = Path(os.environ.get("NOTES_MIGRATOR_TEST_VOLUMES", "/Volumes"))
    if volume_parent.is_dir():
        try:
            volumes = sorted(volume_parent.iterdir(), key=lambda p: p.name.casefold())
        except OSError:
            volumes = []
        for volume in volumes:
            if volume.name.startswith(".") or not volume.is_dir():
                continue
            try:
                if volume.samefile(Path("/")) or volume.samefile(home):
                    continue
            except OSError:
                continue
            roots.append(volume)
    snapshots, unavailable = available_snapshot_roots()
    roots.extend(snapshots)
    roots.append(home)
    return roots, unavailable


def discover_db(roots: list[Path]) -> tuple[list[Path], bool, int, int]:
    results: dict[str, Path] = {}
    # Use resolved paths, not device/inode: different APFS snapshots may expose
    # different versions of the same file with matching filesystem identifiers.
    visited_dirs: set[str] = set()
    dir_count = 0
    file_count = 0
    truncated = False
    deadline = monotonic() + MAX_SEARCH_SECONDS
    for root in roots:
        if root.is_file():
            if DB_NAME.fullmatch(root.name):
                resolved = root.resolve()
                results[str(resolved)] = resolved
            continue
        if not root.is_dir():
            continue
        # os.walk allows pruning before descending into OS caches/system trees
        # and avoids following symlinked directories across volume boundaries.
        for folder, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
            if monotonic() >= deadline or dir_count >= MAX_SEARCH_DIRS or file_count >= MAX_SEARCH_FILES:
                truncated = True
                break
            directory_id = os.path.realpath(folder)
            if directory_id in visited_dirs:
                dirnames[:] = []
                continue
            visited_dirs.add(directory_id)
            dir_count += 1
            file_count += len(filenames)
            dirnames[:] = sorted(
                (name for name in dirnames
                 if name not in SKIP_DIRS and not (Path(folder) / name).is_symlink()),
                key=str.casefold,
            )
            for name in filenames:
                if not DB_NAME.fullmatch(name):
                    continue
                path = Path(folder) / name
                if not path.is_file():
                    continue
                resolved = path.resolve()
                results[str(resolved)] = resolved
                if len(results) > 2000:
                    raise ImportErrorSafe("More than 2000 databases found; narrow --flashnote-root.")
        if truncated:
            break
    candidates = sorted(
        results.values(),
        key=lambda p: (
            p.name.casefold() == "notes2.db",
            p.name,
        ),
        reverse=True,
    )
    return candidates, truncated, dir_count, file_count


def select_db(paths: list[Path]) -> Path:
    if not paths:
        raise ImportErrorSafe(
            "No notes2.db or dated 'notes2 backup YYYY-MM-DD HH-MM.db' found. "
            "Use --flashnote-db FILE or --flashnote-root DIR."
        )
    if len(paths) == 1:
        return paths[0]
    page = 0
    while True:
        start = page * 10
        stop = min(start + 10, len(paths))
        print(f"\nFound {len(paths)} Flashnote databases (page {page + 1}/{(len(paths) + 9) // 10}):")
        for index in range(start, stop):
            path = paths[index]
            hint = "current" if path.name.casefold() == "notes2.db" else "backup"
            print(f"  {index + 1}) {path.name} [{hint}] — {path.parent}")
        try:
            answer = input("Visible number; n=next, p=previous, 0=cancel: ").strip().lower()
        except EOFError as error:
            raise ImportErrorSafe("Selection cancelled (end of input).") from error
        if answer == "0":
            raise ImportErrorSafe("Cancelled.")
        if answer == "n":
            if stop < len(paths):
                page += 1
            else:
                print("Already on the last page.")
            continue
        if answer == "p":
            if page:
                page -= 1
            else:
                print("Already on the first page.")
            continue
        if answer.isascii() and answer.isdecimal() and len(answer) <= 6:
            chosen = int(answer) - 1
            if start <= chosen < stop:
                return paths[chosen]
        print("Select a number displayed on this page.")


def read_nodes(db: Path) -> dict[int, dict]:
    if not db.is_file():
        raise ImportErrorSafe(f"Database not found: {db}")
    with db.open("rb") as handle:
        if handle.read(16) != b"SQLite format 3\x00":
            raise ImportErrorSafe("Not a plain SQLite database (possibly encrypted or corrupted).")
    try:
        connection = sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("PRAGMA query_only=ON")
            table = connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='notes3'"
            ).fetchone()
            if not table:
                raise ImportErrorSafe("Missing Flashnote notes3 table.")
            columns = {row[1] for row in connection.execute("PRAGMA table_info(notes3)")}
            missing = REQUIRED_COLUMNS - columns
            if missing:
                raise ImportErrorSafe(f"Unexpected notes3 schema: missing {', '.join(sorted(missing))}.")
            if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise ImportErrorSafe("Source SQLite database failed its integrity check.")
            if connection.execute("SELECT COUNT(*) FROM notes3").fetchone()[0] > MAX_ROWS:
                raise ImportErrorSafe("Database too large for this experimental importer.")
            rows = connection.execute(
                "SELECT id,pid,folderpos,name,note,pos,created,modified,trash,type "
                "FROM notes3 ORDER BY pos,folderpos,id"
            ).fetchall()
        finally:
            connection.close()
    except sqlite3.Error as error:
        raise ImportErrorSafe(f"Cannot read SQLite database: {error}") from error
    nodes = {}
    for row in rows:
        node = dict(row)
        node_id = int(node["id"])
        node["pid"] = int(node["pid"])
        node["name"] = node["name"] or ""
        node["note"] = node["note"] or ""
        nodes[node_id] = node
    return nodes


def plan_tree(nodes: dict[int, dict]) -> dict:
    # Resolve ancestors before writing anything. Detect cycles and exclude
    # descendants of trashed nodes, not only rows with trash=1 themselves.
    state: dict[int, bool] = {}
    orphan_ids: set[int] = set()

    def is_active(node_id: int, visiting: set[int]) -> bool:
        if node_id in state:
            return state[node_id]
        if node_id in visiting:
            raise ImportErrorSafe(f"Cycle in Flashnote pid hierarchy at row {node_id}.")
        visiting.add(node_id)
        node = nodes[node_id]
        parent = node["pid"]
        active = not bool(node["trash"])
        if parent and parent in nodes:
            active = active and is_active(parent, visiting)
        elif parent and parent != node_id:
            orphan_ids.add(node_id)
        elif parent == node_id:
            raise ImportErrorSafe(f"Self-referencing Flashnote row {node_id}.")
        visiting.remove(node_id)
        state[node_id] = active
        return active

    for node_id in nodes:
        is_active(node_id, set())

    active_nodes = {node_id: node for node_id, node in nodes.items() if state[node_id]}
    children: dict[int, list[int]] = defaultdict(list)
    roots: list[int] = []
    for node_id, node in active_nodes.items():
        parent = node["pid"]
        if parent and parent in active_nodes:
            children[parent].append(node_id)
        else:
            roots.append(node_id)
    for child_ids in children.values():
        child_ids.sort(key=lambda i: (active_nodes[i]["pos"], active_nodes[i]["folderpos"], i))
    roots.sort(key=lambda i: (active_nodes[i]["pos"], active_nodes[i]["folderpos"], i))
    return {
        "nodes": active_nodes,
        "children": children,
        "roots": roots,
        "excluded": len(nodes) - len(active_nodes),
        "orphans": len(orphan_ids & active_nodes.keys()),
        "type_counts": dict(sorted(Counter(str(node["type"]) for node in active_nodes.values()).items())),
    }


def clean_name(name: str) -> str:
    name = re.sub(r"[\x00-\x1f\x7f/\\:]", " ", name).strip().strip(".")
    name = re.sub(r"\s+", " ", name)
    return name[:90].strip().strip(".") or "Untitled"


def export_tree(plan: dict, export_dir: Path, source: Path) -> dict:
    notes_dir = export_dir / "Import to Notes"
    notes_dir.mkdir(mode=0o700)
    manifest = []
    counts = {"notes": 0, "folders": 0, "notes_in_parent_nodes": 0}
    children = plan["children"]
    nodes = plan["nodes"]
    used_names: dict[Path, set[str]] = defaultdict(set)

    def unique_name(folder: Path, title: str, node_id: int, suffix: str = "") -> str:
        base = clean_name(title)
        candidate = f"{base}{suffix}"
        if candidate.casefold() in used_names[folder]:
            candidate = f"{base} (Flashnote {node_id}){suffix}"
        used_names[folder].add(candidate.casefold())
        return candidate

    def write_note(folder: Path, title: str, text: str, node_id: int, parent_note: bool) -> Path:
        filename = unique_name(folder, title, node_id, ".txt")
        path = folder / filename
        contents = f"{title.strip() or 'Untitled'}\n\n{text}".rstrip() + "\n"
        with path.open("x", encoding="utf-8", newline="\n") as handle:
            handle.write(contents)
        counts["notes"] += 1
        if parent_note:
            counts["notes_in_parent_nodes"] += 1
        return path

    def write_nodes(node_ids: list[int], folder: Path, ancestors: tuple[int, ...]) -> None:
        for node_id in node_ids:
            node = nodes[node_id]
            title = str(node["name"])
            body = str(node["note"]).replace("\r\n", "\n").replace("\r", "\n")
            has_children = bool(children.get(node_id))
            if has_children:
                child_folder = folder / unique_name(folder, title, node_id)
                child_folder.mkdir(mode=0o700)
                counts["folders"] += 1
                if body.strip():
                    path = write_note(child_folder, title, body, node_id, parent_note=True)
                    kind = "folder+note"
                else:
                    path = child_folder
                    kind = "folder"
                manifest.append({
                    "id": node_id, "parent_id": node["pid"], "title": title,
                    "kind": kind, "type": node["type"], "created": str(node["created"]),
                    "modified": str(node["modified"]), "relative_path": str(path.relative_to(export_dir)),
                })
                write_nodes(children[node_id], child_folder, ancestors + (node_id,))
            else:
                path = write_note(folder, title, body, node_id, parent_note=False)
                manifest.append({
                    "id": node_id, "parent_id": node["pid"], "title": title,
                    "kind": "note", "type": node["type"], "created": str(node["created"]),
                    "modified": str(node["modified"]), "relative_path": str(path.relative_to(export_dir)),
                })

    write_nodes(plan["roots"], notes_dir, ())
    with (export_dir / "flashnote-manifest.json").open("x", encoding="utf-8") as handle:
        json.dump({"source": str(source), "counts": counts, "items": manifest}, handle,
                  ensure_ascii=False, indent=2)
    return counts


def enex_timestamp(value: object, node_id: int, field: str) -> str:
    """Evernote ENEX uses UTC timestamps; SQLite CURRENT_TIMESTAMP is UTC.

    Flashnote's timezone for any explicitly written naive timestamps is not
    documented; preserve the clock value and assume UTC rather than silently
    applying the current machine's timezone.
    """
    try:
        parsed = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    except (TypeError, ValueError, OverflowError) as error:
        raise ImportErrorSafe(
            f"Flashnote row {node_id} has invalid {field} timestamp: {value!r}."
        ) from error


def ensure_xml_text(value: str, node_id: int) -> None:
    """Fail rather than silently remove original note characters."""
    for character in value:
        code = ord(character)
        if not (code in (9, 10, 13) or 0x20 <= code <= 0xD7FF or
                0xE000 <= code <= 0xFFFD or 0x10000 <= code <= 0x10FFFF):
            raise ImportErrorSafe(f"Flashnote row {node_id} contains text forbidden in XML.")


def enex_note_items(plan: dict) -> list[tuple[int, str, str, dict]]:
    """Flatten nested folders for ENEX, retaining their labels in note titles."""
    nodes = plan["nodes"]
    children = plan["children"]
    items: list[tuple[int, str, str, dict]] = []

    def walk(ids: list[int], ancestors: tuple[str, ...]) -> None:
        for node_id in ids:
            node = nodes[node_id]
            title = str(node["name"]).strip() or "Untitled"
            body = str(node["note"]).replace("\r\n", "\n").replace("\r", "\n")
            has_children = bool(children.get(node_id))
            if not has_children or body.strip():
                # ENEX does not encode folder hierarchies. Make provenance
                # visible without altering the original leaf title if flat.
                full_title = " / ".join((*ancestors, title))
                items.append((node_id, full_title, body, node))
            if has_children:
                walk(children[node_id], (*ancestors, title))

    walk(plan["roots"], ())
    return items


def export_enex(plan: dict, export_dir: Path, source: Path, limit: int | None) -> dict:
    items = enex_note_items(plan)
    if limit is not None:
        items = items[:limit]
    if not items:
        raise ImportErrorSafe("No active Flashnote notes with content to export.")
    date = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    filename = "Flashnote-date-test.enex" if limit == 1 else "Flashnote.enex"
    path = export_dir / filename
    manifest = []

    # ENEX's content element contains a complete ENML XML document as CDATA.
    # Converting original plaintext lines to divs follows Evernote's ENML guide.
    with path.open("x", encoding="utf-8", newline="\n") as handle:
        handle.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        handle.write('<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export3.dtd">\n')
        handle.write(f'<en-export export-date="{date}" application="macOS Notes Migrator" version="1.0">\n')
        for node_id, title, body, node in items:
            ensure_xml_text(title, node_id)
            ensure_xml_text(body, node_id)
            created = enex_timestamp(node["created"], node_id, "created")
            updated = enex_timestamp(node["modified"], node_id, "modified")
            divs = "".join(
                f"<div>{html_escape(line, quote=False)}</div>" if line else "<div><br/></div>"
                for line in body.split("\n")
            )
            enml = (
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">\n'
                f'<en-note>{divs}</en-note>'
            )
            handle.write("  <note>\n")
            handle.write(f"    <title>{xml_escape(title)}</title>\n")
            handle.write(f"    <content><![CDATA[{enml}]]></content>\n")
            handle.write(f"    <created>{created}</created>\n")
            handle.write(f"    <updated>{updated}</updated>\n")
            handle.write("  </note>\n")
            manifest.append({
                "id": node_id, "parent_id": node["pid"], "title": title,
                "created": str(node["created"]), "modified": str(node["modified"]),
                "enex_created": created, "enex_updated": updated,
            })
        handle.write("</en-export>\n")

    # Offline structural verification (does not contact Evernote or Apple).
    parsed = ElementTree.parse(path).getroot()
    if parsed.tag != "en-export" or len(parsed.findall("note")) != len(items):
        raise ImportErrorSafe("Generated ENEX did not pass XML structural verification.")
    counts = {"notes": len(items), "folders": 0}
    with (export_dir / "flashnote-manifest.json").open("x", encoding="utf-8") as handle:
        json.dump({"source": str(source), "format": "enex", "counts": counts, "items": manifest},
                  handle, ensure_ascii=False, indent=2)
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--db", type=Path)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--output-base", required=True, type=Path)
    parser.add_argument("--format", choices=("txt", "enex"), default="txt")
    parser.add_argument("--notes-account", choices=("local", "icloud", "ask"),
                        default="ask", help="Guide the final Apple Notes import account; does not control Notes UI")
    parser.add_argument("--limit", type=int, help="ENEX only: export first N notes for a safe test")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    if args.limit is not None and (args.format != "enex" or args.limit < 1):
        raise ImportErrorSafe("--flashnote-limit needs --flashnote-format enex and a positive number.")
    if args.db and args.root:
        raise ImportErrorSafe("Choose --db or --root, not both.")
    if args.db or args.root:
        search_roots = [args.db] if args.db else [args.root]
        unmounted_snapshots = 0
    else:
        search_roots, unmounted_snapshots = default_search_roots(args.home)
    print("Searching Flashnote databases (bounded read-only scan)...", flush=True)
    candidates, truncated, dirs_scanned, files_scanned = discover_db(search_roots)
    print(f"Inspected {dirs_scanned} directories and {files_scanned} filenames.")
    if unmounted_snapshots:
        print(f"Skipped {unmounted_snapshots} unmounted Time Machine snapshots.")
    if truncated:
        print("WARNING: search limit reached; results are incomplete. "
              "Use --flashnote-root or --flashnote-db to narrow the search.", file=sys.stderr)
    source = select_db(candidates)
    nodes = read_nodes(source)
    plan = plan_tree(nodes)
    parents = sum(bool(plan["children"].get(node_id)) for node_id in plan["nodes"])
    leaves = len(plan["nodes"]) - parents
    print(f"\nFlashnote source: {source}")
    print(f"SQLite rows: {len(nodes)}, active: {len(plan['nodes'])}, excluded by trash: {plan['excluded']}")
    print(f"Hierarchy: {parents} parent nodes, {leaves} leaf notes, {plan['orphans']} orphan rows")
    print(f"Original type values: {plan['type_counts']} (meaning not assumed)")
    if args.format == "enex":
        print("ENEX export: original created/modified timestamps are embedded in each note.")
        print("Flashnote timestamps without timezone information are interpreted as UTC.")
        print("ENEX cannot preserve nested folders; ancestor names become part of note titles.")
        if args.limit is not None:
            print(f"TEST MODE: export at most {args.limit} notes to check Apple Notes date handling.")
    else:
        print("Each parent node becomes a folder; any text in it becomes a note inside that folder.")
        print("Each leaf node becomes a text note, including empty notes.")
    print("No Apple Notes data is replaced or modified by this conversion.")

    if args.dry_run:
        print(f"Intended Notes account: {args.notes_account} (no account is selected in dry-run).")
        print("\nDRY RUN: no directories or notes were written.")
        return 0
    try:
        confirmation = input("\nType EXPORT to prepare the Apple Notes import files (0=cancel): ").strip()
    except EOFError:
        confirmation = ""
    if confirmation != "EXPORT":
        print("Cancelled without changes.")
        return 0
    account = args.notes_account
    if account == "ask":
        print("\nChoose the Apple Notes account for your MANUAL import:")
        print("  1) On My Mac (local, no iCloud sync)")
        print("  2) iCloud (synced)")
        try:
            choice = input("Enter 1 or 2 (anything else cancels): ").strip()
        except EOFError:
            choice = ""
        if choice not in ("1", "2"):
            print("Cancelled before creating export files.")
            return 0
        account = "local" if choice == "1" else "icloud"
    print(f"Intended Apple Notes account: {account} (selection in Notes is MANUAL).")
    output_base = args.output_base.expanduser().resolve()
    if output_base == Path("/") or output_base == source.parent:
        raise ImportErrorSafe("Choose a dedicated export directory, not a disk root or source folder.")
    output_base.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="flashnote-", dir=str(output_base)))
    try:
        counts = (export_enex(plan, stage, source, args.limit) if args.format == "enex"
                  else export_tree(plan, stage, source))
    except Exception:
        shutil.rmtree(stage)
        raise
    print(f"\nEXPORT COMPLETE: {counts['notes']} notes, {counts['folders']} folders.")
    target = stage / ("Flashnote-date-test.enex" if args.limit == 1 else "Flashnote.enex") \
        if args.format == "enex" else stage / "Import to Notes"
    print(f"Import source: {target}")
    print(f"Manifest / source metadata: {stage / 'flashnote-manifest.json'}")
    print("\nMANUAL APPLE NOTES IMPORT (ENEX cannot select an account):")
    if account == "local":
        print("  1. In Notes > Settings, enable 'On My Mac' if that account is hidden.")
        print("  2. In the Notes sidebar, CLICK A FOLDER UNDER 'On My Mac'.")
    else:
        print("  1. In the Notes sidebar, CLICK A FOLDER UNDER 'iCloud'.")
    print("  3. Only then choose File > Import to Notes and select the import source above.")
    print("  4. Verify the Imported Notes folder is under the intended account.")
    print("The tool cannot control or verify the selected Notes sidebar account.")
    if args.format == "enex":
        print("IMPORTANT: check original dates on a ONE-NOTE import before a full export.")
        if args.limit == 1:
            example = enex_note_items(plan)[0]
            print(f"Sample: {example[1]!r}")
            print(f"Original created: {example[3]['created']} | modified: {example[3]['modified']}")
        print("Apple Notes might ignore ENEX timestamps; existing imported notes are not changed.")
        print("A second import creates DUPLICATES. Remove older imported copies only after verification.")
    else:
        print("When importing TXT folders, enable 'Preserve folder structure on import'.")
    if sys.platform == "darwin" and not args.no_open:
        # Reveal (rather than open) ENEX. Opening it directly can trigger an
        # import in whichever Notes account was previously selected.
        command = ["open", "-R", str(target)] if args.format == "enex" else ["open", str(target)]
        subprocess.run(command, check=False)
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    try:
        raise SystemExit(main())
    except ImportErrorSafe as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1) from None
