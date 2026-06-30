from __future__ import annotations

import hashlib
import os
from pathlib import Path

from .encryption import EncryptionEngine


class SyncEngine:
    def __init__(self, mount_path: str | Path, vfs, master_password: str, encryption: EncryptionEngine | None = None) -> None:
        self.mount_path = Path(mount_path).resolve()
        self.mount_path.mkdir(parents=True, exist_ok=True)
        self.vfs = vfs
        self.master_password = master_password
        self.encryption = encryption or EncryptionEngine()
        self.file_hashes: dict[str, str] = {}
        self.file_access_times: dict[str, float] = {}
        self.file_signatures: dict[str, tuple[int, float]] = {}
        self.last_scan = None
        self._enable_atime_read_detection = os.getenv("ZTFS_ENABLE_ATIME_READ_DETECTION", "0") == "1"

    def populate_mount(self) -> bool:
        self.mount_path.mkdir(parents=True, exist_ok=True)
        self.file_hashes = {}
        self.file_access_times = {}
        self.file_signatures = {}

        for fname in self.vfs.get_all_filenames():
            entry = self.vfs.files.get(self.vfs._normalize_name(fname))
            if entry:
                target = self.mount_path / f"{fname}.zfs"
                zfs_payload = entry.salt + entry.iv + entry.ciphertext
                target.write_bytes(zfs_payload)
                self.file_hashes[fname] = self.get_file_hash(target)
                self.file_access_times[fname] = self.get_file_access_time(target)
                self.file_signatures[fname] = self.get_file_signature(target)

        return True

    def scan_changes(self) -> dict:
        file_paths = [p for p in self.mount_path.iterdir() if p.is_file()]
        current_names = [p.name for p in file_paths]

        current_signatures = {p.name: self.get_file_signature(p) for p in file_paths}
        previous_names = set(self.file_signatures.keys())

        new_files = sorted(set(current_names) - previous_names)
        deleted_files = sorted(previous_names - set(current_names))

        common = sorted(set(current_names).intersection(previous_names))
        modified = []
        current_hashes: dict[str, str] = {}
        for fname in common:
            old_sig = self.file_signatures.get(fname)
            new_sig = current_signatures.get(fname)
            if old_sig != new_sig:
                path = self.mount_path / fname
                new_hash = self.get_file_hash(path)
                old_hash = self.file_hashes.get(fname)
                current_hashes[fname] = new_hash
                if new_hash != old_hash:
                    modified.append(fname)

        self._latest_hashes = current_hashes
        self._latest_signatures = current_signatures

        return {"new": new_files, "modified": modified, "deleted": deleted_files}

    def sync_new_file(self, filename: str) -> bool:
        src = self.mount_path / filename
        if not src.exists():
            return False
        content = src.read_bytes()
        self.vfs.add_file(filename, content, self.master_password)
        self.file_hashes[filename] = self.get_file_hash(src)
        self.file_access_times[filename] = self.get_file_access_time(src)
        self.file_signatures[filename] = self.get_file_signature(src)
        return True

    def sync_modified_file(self, filename: str) -> bool:
        src = self.mount_path / filename
        if not src.exists():
            return False
        content = src.read_bytes()
        self.vfs.update_file(filename, content, self.master_password)
        self.file_hashes[filename] = self.get_file_hash(src)
        self.file_access_times[filename] = self.get_file_access_time(src)
        self.file_signatures[filename] = self.get_file_signature(src)
        return True

    def sync_deleted_file(self, filename: str) -> bool:
        self.vfs.remove_file(filename)
        self.file_hashes.pop(filename, None)
        self.file_access_times.pop(filename, None)
        self.file_signatures.pop(filename, None)
        return True

    def detect_reads(self, ignore_files: list[str] | None = None) -> list[str]:
        ignore = set(ignore_files or [])
        if not self._enable_atime_read_detection:
            return []

        file_paths = [p for p in self.mount_path.iterdir() if p.is_file()]
        if not file_paths:
            self.file_access_times = {}
            return []

        reads: list[str] = []
        keep = {p.name for p in file_paths}
        for path in file_paths:
            fname = path.name
            access_now = self.get_file_access_time(path)
            previous = self.file_access_times.get(fname)
            if previous is None:
                self.file_access_times[fname] = access_now
                continue
            if fname in ignore:
                self.file_access_times[fname] = access_now
                continue
            if access_now > previous and self.vfs.file_exists(fname):
                reads.append(fname)
            self.file_access_times[fname] = access_now

        stale = set(self.file_access_times.keys()) - keep
        for fname in stale:
            self.file_access_times.pop(fname, None)

        return sorted(set(reads))

    def sync_all(self) -> dict:
        changes = self.scan_changes()

        for fname in changes["new"]:
            self.sync_new_file(fname)

        for fname in changes["modified"]:
            self.sync_modified_file(fname)

        for fname in changes["deleted"]:
            self.sync_deleted_file(fname)

        reads = self.detect_reads(ignore_files=changes["new"] + changes["modified"])
        self.last_scan = self._now_str()
        changes["read"] = reads
        return changes

    def clear_mount(self) -> bool:
        if not self.mount_path.exists():
            return True

        for file_path in self.mount_path.glob("**/*"):
            if file_path.is_file():
                try:
                    file_path.unlink()
                except Exception:
                    pass

        self.file_hashes = {}
        self.file_access_times = {}
        self.file_signatures = {}
        return True

    def remove_from_mount(self, filename: str) -> bool:
        target = self.mount_path / filename
        if not target.exists():
            return False
        try:
            target.unlink()
        except Exception:
            return False

        self.file_hashes.pop(filename, None)
        self.file_access_times.pop(filename, None)
        self.file_signatures.pop(filename, None)
        return True

    @staticmethod
    def get_file_hash(file_path: str | Path) -> str:
        path = Path(file_path)
        if not path.exists():
            return ""
        h = hashlib.sha256()
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()

    @staticmethod
    def get_file_access_time(file_path: str | Path) -> float:
        path = Path(file_path)
        if not path.exists():
            return float("nan")
        return path.stat().st_atime

    @staticmethod
    def get_file_signature(file_path: str | Path) -> tuple[int, float]:
        stat = Path(file_path).stat()
        return int(stat.st_size), float(stat.st_mtime)

    @staticmethod
    def _now_str() -> str:
        from datetime import datetime, timezone

        return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
