#!/usr/bin/env python3
"""Real SQLite fixtures; no private user databases or Notes apps involved."""

from __future__ import annotations

from pathlib import Path

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from xml.etree import ElementTree


PROJECT = Path(__file__).resolve().parent.parent
SCRIPT = PROJECT / "flashnote-to-notes.py"
WRAPPER = PROJECT / "macos-notes-migrator.sh"
MOCKS = PROJECT / "tests" / "mocks"
SCHEMA = """
CREATE TABLE notes3(
 id INTEGER PRIMARY KEY AUTOINCREMENT,pid INTEGER not null default 0,
 folderpos INTEGER not null default 1,name TEXT not null default '',
 note TEXT not null default '',pos INTEGER not null default 0,
 created TIMESTAMP not null default CURRENT_TIMESTAMP,
 modified TIMESTAMP not null default CURRENT_TIMESTAMP,
 trash boolean not null default 0,type INTEGER not null default 0
);
"""


def make_db(path: Path, rows: list[tuple]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as connection:
        connection.executescript(SCHEMA)
        connection.executemany(
            "INSERT INTO notes3(id,pid,name,note,trash,type) VALUES (?,?,?,?,?,?)", rows
        )


def run(*args: str, input_text: str = "", via_wrapper: bool = False,
        extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["PATH"] = str(MOCKS) + os.pathsep + env.get("PATH", "")
    if extra_env:
        env.update(extra_env)
    command = ["bash", str(WRAPPER), "--import-flashnote"] if via_wrapper else [
        sys.executable, str(SCRIPT)
    ]
    return subprocess.run(
        command + list(args), input=input_text, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, check=False
    )


def assert_ok(result: subprocess.CompletedProcess) -> None:
    assert result.returncode == 0, (result.stdout, result.stderr)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="flashnote-import-tests-") as scratch:
        root = Path(scratch)
        store = root / "Desktop" / "Old Windows" / "AppData" / "Roaming" / "Flashnote"
        db = store / "notes2.db"
        make_db(db, [
            (1, 0, "Projects", "", 0, 1),
            (2, 1, "One/Two", "Parent text", 0, 1),
            (3, 2, "Title", "Hello\r\nWorld", 0, 0),
            (4, 2, "Title", "", 0, 0),
            (5, 1, "Trashed", "Don't import", 1, 1),
            (6, 5, "Trashed child", "Don't import", 0, 0),
            (7, 0, "../evil", "Safe name", 0, 0),
            (8, 999, "Orphan", "Recovered", 0, 0),
        ])
        with sqlite3.connect(db) as connection:
            connection.execute(
                "UPDATE notes3 SET created=?, modified=? WHERE id=2",
                ("2015-08-03 03:38:00", "2016-01-02 05:06:07"),
            )
            connection.execute(
                "UPDATE notes3 SET created=?, modified=? WHERE id=3",
                ("2014-07-01 00:00:00", "2015-12-31 23:59:59"),
            )
        backup = store / "backup" / "notes2 backup 2015-08-03 03-38.db"
        backup.parent.mkdir()
        shutil.copyfile(db, backup)
        output = root / "exports"

        # Users often copy loose .db files onto Desktop, without retaining
        # the original Flashnote parent directory. Any nesting depth counts.
        loose_home = root / "loose-home"
        loose_desktop = loose_home / "Desktop" / "notes2.db"
        loose_desktop.parent.mkdir(parents=True)
        shutil.copyfile(db, loose_desktop)
        loose_backup = loose_home / "Downloads" / "arbitrary" / "deep" / backup.name
        loose_backup.parent.mkdir(parents=True)
        shutil.copyfile(db, loose_backup)
        loose_preview = run("--home", str(loose_home), "--output-base",
                            str(root / "loose-exports"), "--dry-run", input_text="1\n")
        assert_ok(loose_preview)
        assert str(loose_desktop) in loose_preview.stdout, loose_preview.stdout
        assert not (root / "loose-exports").exists()

        # The default scan also covers arbitrary home folders, mounted volumes,
        # and the user-data portion of already-accessible Time Machine snapshots.
        scan_home = root / "whole-home"
        home_note = scan_home / "Personal Workspace" / "notes2.db"
        home_note.parent.mkdir(parents=True)
        shutil.copyfile(db, home_note)
        volume_parent = root / "Volumes"
        volume_parent.mkdir()
        tm_list_file = root / "tm-backups.txt"
        tm_list_file.write_text("")
        scan_env = {
            "NOTES_MIGRATOR_TEST_VOLUMES": str(volume_parent),
            "NOTES_MIGRATOR_TEST_TM_FILE": str(tm_list_file),
        }
        home_preview = run("--home", str(scan_home), "--output-base",
                           str(root / "scan-output"), "--dry-run", extra_env=scan_env)
        assert_ok(home_preview)
        assert str(home_note) in home_preview.stdout

        external_note = volume_parent / "External Disk" / "archive" / backup.name
        external_note.parent.mkdir(parents=True)
        shutil.copyfile(db, external_note)
        tm_snapshot = root / "snapshot" / "2025-03-05-010101.backup" / "2025-03-05-010101.backup"
        tm_note = tm_snapshot / "Macintosh HD - Data" / "Users" / "sample-account" / "Downloads" / backup.name
        tm_note.parent.mkdir(parents=True)
        shutil.copyfile(db, tm_note)
        tm_list_file.write_text(str(tm_snapshot) + "\n" + str(root / "unmounted.backup") + "\n")
        broad_preview = run("--home", str(scan_home), "--output-base",
                            str(root / "scan-output"), "--dry-run", input_text="1\n",
                            extra_env=scan_env)
        assert_ok(broad_preview)
        assert "Found 3 Flashnote databases" in broad_preview.stdout, broad_preview.stdout
        assert "Skipped 1 unmounted Time Machine snapshots" in broad_preview.stdout
        assert str(home_note) in broad_preview.stdout
        assert str(external_note.parent) in broad_preview.stdout
        assert str(tm_note.parent) in broad_preview.stdout
        assert not (root / "scan-output").exists()

        preview = run("--db", str(db), "--output-base", str(output), "--dry-run")
        assert_ok(preview)
        assert "active: 6, excluded by trash: 2" in preview.stdout, preview.stdout
        assert "Original type values: {'0': 4, '1': 2}" in preview.stdout, preview.stdout
        assert not output.exists(), "Dry run unexpectedly wrote an output folder."

        # Autodiscovery sees current and dated backup names; choose the current.
        discovered = run("--root", str(store), "--output-base", str(output),
                         "--dry-run", input_text="1\n")
        assert_ok(discovered)
        assert str(db) in discovered.stdout
        wrapper_preview = run("--flashnote-db", str(db), "--dry-run",
                              via_wrapper=True)
        assert_ok(wrapper_preview)
        assert "DRY RUN" in wrapper_preview.stdout

        exported = run("--db", str(db), "--output-base", str(output),
                       "--no-open", "--notes-account", "local", input_text="EXPORT\n")
        assert_ok(exported)
        export_dirs = list(output.glob("flashnote-*"))
        assert len(export_dirs) == 1
        export_dir = export_dirs[0]
        note_dir = export_dir / "Import to Notes"
        nested = note_dir / "Projects" / "One Two"
        assert (nested / "Title.txt").is_file()
        assert (nested / "Title (Flashnote 4).txt").is_file()
        assert "Hello\nWorld" in (nested / "Title.txt").read_text()
        assert (nested / "One Two.txt").is_file()
        assert (note_dir / "evil.txt").is_file()
        assert not list(note_dir.rglob("*Trashed*"))
        manifest = json.loads((export_dir / "flashnote-manifest.json").read_text())
        assert manifest["counts"] == {
            "notes": 5, "folders": 2, "notes_in_parent_nodes": 1
        }, manifest["counts"]
        assert len(manifest["items"]) == 6

        # ENEX carries source dates within the XML, unlike plain .txt imports.
        # A one-note test must NOT unexpectedly export or import everything.
        enex_output = root / "date-export"
        enex_preview = run("--db", str(db), "--output-base", str(enex_output),
                           "--format", "enex", "--limit", "1", "--dry-run")
        assert_ok(enex_preview)
        assert not enex_output.exists()
        enex_sample = run("--flashnote-db", str(db), "--flashnote-output",
                          str(enex_output), "--flashnote-format", "enex",
                          "--flashnote-limit", "1", "--no-open", "--notes-account", "local",
                          via_wrapper=True, input_text="EXPORT\n")
        assert_ok(enex_sample)
        sample_folder = next(enex_output.glob("flashnote-*"))
        sample = sample_folder / "Flashnote-date-test.enex"
        assert sample.is_file()
        sample_xml = ElementTree.parse(sample).getroot()
        sample_notes = sample_xml.findall("note")
        assert len(sample_notes) == 1
        assert sample_notes[0].findtext("title") == "Projects / One/Two"
        assert sample_notes[0].findtext("created") == "20150803T033800Z"
        assert sample_notes[0].findtext("updated") == "20160102T050607Z"
        enml = sample_notes[0].findtext("content")
        assert "<en-note>" in enml and "Parent text" in enml
        full_enex_output = root / "full-date-export"
        full_enex = run("--db", str(db), "--output-base", str(full_enex_output),
                        "--format", "enex", "--no-open", "--notes-account", "local", input_text="EXPORT\n")
        assert_ok(full_enex)
        full_xml = ElementTree.parse(
            next(full_enex_output.glob("flashnote-*")) / "Flashnote.enex"
        ).getroot()
        assert len(full_xml.findall("note")) == 5
        assert any(note.findtext("created") == "20140701T000000Z"
                   for note in full_xml.findall("note"))
        assert all(note.findtext("updated") for note in full_xml.findall("note"))

        # Account option must guide, never silently pick current iCloud account.
        # This test also ensures the original source database stays unchanged.
        account_output = root / "account-import"
        asked = run("--flashnote-db", str(db), "--flashnote-output", str(account_output),
                    "--flashnote-format", "enex", "--no-open", via_wrapper=True,
                    input_text="EXPORT\n1\n")
        assert_ok(asked)
        assert "On My Mac" in asked.stdout
        assert "MANUAL APPLE NOTES IMPORT" in asked.stdout
        assert next(account_output.glob("flashnote-*")) / "Flashnote.enex"
        icloud_output = root / "icloud-import"
        icloud = run("--flashnote-db", str(db), "--flashnote-output", str(icloud_output),
                     "--flashnote-format", "enex", "--no-open", "--notes-account", "icloud",
                     via_wrapper=True, input_text="EXPORT\n")
        assert_ok(icloud)
        assert "CLICK A FOLDER UNDER 'iCloud'" in icloud.stdout
        denied_output = root / "denied-import"
        denied = run("--flashnote-db", str(db), "--flashnote-output", str(denied_output),
                     "--flashnote-format", "enex", "--no-open", via_wrapper=True,
                     input_text="EXPORT\n0\n")
        assert_ok(denied)
        assert not denied_output.exists()
        env = os.environ.copy()
        env["PATH"] = str(MOCKS) + os.pathsep + env.get("PATH", "")
        unexpected_option = subprocess.run(
            ["bash", str(WRAPPER), "--notes-account", "local", "--dry-run"],
            capture_output=True, text=True, env=env, check=False)
        assert unexpected_option.returncode != 0
        assert "--import-flashnote" in unexpected_option.stderr

        invalid_limit = run("--db", str(db), "--output-base", str(root / "invalid-limit"),
                            "--format", "txt", "--limit", "1")
        assert invalid_limit.returncode != 0
        assert not (root / "invalid-limit").exists()
        with sqlite3.connect(db) as connection:
            connection.execute("UPDATE notes3 SET created='not-a-date' WHERE id=2")
        invalid_date = run("--db", str(db), "--output-base", str(root / "invalid-date"),
                           "--format", "enex", "--no-open", "--notes-account", "local", input_text="EXPORT\n")
        assert invalid_date.returncode != 0
        assert "invalid created timestamp" in invalid_date.stderr
        assert not list((root / "invalid-date").glob("flashnote-*"))

        # A corrupt/proprietary/encrypted file must refuse before creating output.
        wrong = root / "notes2 encrypted.db"
        wrong.write_bytes(b"not a SQLite database")
        rejected = run("--db", str(wrong), "--output-base", str(root / "rejected"))
        assert rejected.returncode != 0
        assert not (root / "rejected").exists()

        # A cycle cannot be safely mapped into the Notes folder tree.
        cyclic_db = root / "notes2.db"
        make_db(cyclic_db, [(11, 12, "A", "a", 0, 0), (12, 11, "B", "b", 0, 0)])
        cyclic = run("--db", str(cyclic_db), "--output-base", str(root / "cycles"))
        assert cyclic.returncode != 0
        assert "Cycle" in cyclic.stderr
        assert not (root / "cycles").exists()

    print("PASS: discovery, hierarchy, trash, TXT/ENEX, source dates, sample preview and rejection.")


if __name__ == "__main__":
    main()
