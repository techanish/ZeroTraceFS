from __future__ import annotations

import hashlib
from dataclasses import dataclass

from .encryption import EncryptionEngine
from .key_derivation import KeyDerivation
from .utils import format_utc, parse_time, utcnow


@dataclass
class FileEntry:
    ciphertext: bytes
    iv: bytes
    salt: bytes
    metadata: dict


class VirtualFileSystem:
    def __init__(self) -> None:
        self.files: dict[str, FileEntry] = {}
        self._encryption = EncryptionEngine()
        self._key_derivation = KeyDerivation()
        self._key_iterations = 10000

    def add_file(self, filename: str, content: bytes, file_password: str) -> bool:
        if not isinstance(content, (bytes, bytearray)):
            raise ValueError("content must be bytes")
        fname = self._normalize_name(filename)
        if fname in self.files:
            return self.update_file(fname, bytes(content), file_password)

        salt = self._key_derivation.generate_salt()
        key = self._key_derivation.derive_key(file_password, salt, self._key_iterations)
        iv = self._encryption.generate_iv()
        ciphertext = self._encryption.encrypt(bytes(content), key, iv)
        metadata = self._make_metadata(fname, bytes(content))
        self.files[fname] = FileEntry(ciphertext=ciphertext, iv=iv, salt=salt, metadata=metadata)
        return True

    def read_file(self, filename: str, file_password: str) -> bytes:
        return self._decrypt_entry(filename, file_password, increment_read=True)

    def peek_file(self, filename: str, file_password: str) -> bytes:
        return self._decrypt_entry(filename, file_password, increment_read=False)

    def note_file_read(self, filename: str, read_time=None) -> bool:
        return self.note_file_access(filename, access_time=read_time, increment_read=True)

    def note_file_access(self, filename: str, access_time=None, increment_read: bool = False) -> bool:
        fname = self._normalize_name(filename)
        entry = self.files.get(fname)
        if not entry or entry.metadata.get("is_destroyed"):
            return False

        ts = parse_time(access_time, default=utcnow())
        entry.metadata["last_access_at"] = ts
        if increment_read:
            entry.metadata["read_count"] = int(entry.metadata.get("read_count", 0)) + 1
            entry.metadata["last_read_at"] = ts
        return True

    def update_file(self, filename: str, content: bytes, file_password: str) -> bool:
        if not isinstance(content, (bytes, bytearray)):
            raise ValueError("content must be bytes")
        fname = self._normalize_name(filename)
        entry = self.files.get(fname)
        if not entry:
            raise KeyError(f"File not found in VFS: {fname}")

        salt = self._key_derivation.generate_salt()
        key = self._key_derivation.derive_key(file_password, salt, self._key_iterations)
        iv = self._encryption.generate_iv()
        ciphertext = self._encryption.encrypt(bytes(content), key, iv)

        now = utcnow()
        entry.ciphertext = ciphertext
        entry.iv = iv
        entry.salt = salt
        entry.metadata["modified_at"] = now
        entry.metadata["last_access_at"] = now
        entry.metadata["file_size"] = len(content)
        entry.metadata["file_hash"] = hashlib.sha256(bytes(content)).hexdigest()
        entry.metadata["is_destroyed"] = False
        return True

    def remove_file(self, filename: str) -> bool:
        fname = self._normalize_name(filename)
        if fname not in self.files:
            return False
        del self.files[fname]
        return True

    def list_files(self) -> list[dict]:
        rows: list[dict] = []
        now = utcnow()
        for fname, entry in self.files.items():
            meta = entry.metadata
            ttl_anchor = meta.get("last_access_at") or meta.get("created_at")
            ttl_seconds = meta.get("ttl_seconds")
            if ttl_seconds is None or ttl_anchor is None:
                ttl_remaining = None
            else:
                age = max(0.0, (now - parse_time(ttl_anchor, default=now)).total_seconds())
                ttl_remaining = max(0.0, float(ttl_seconds) - age)

            rows.append(
                {
                    "filename": fname,
                    "created_at": format_utc(parse_time(meta.get("created_at"))),
                    "modified_at": format_utc(parse_time(meta.get("modified_at"))),
                    "last_access_at": format_utc(parse_time(meta.get("last_access_at"))),
                    "last_read_at": format_utc(parse_time(meta.get("last_read_at"))),
                    "read_count": int(meta.get("read_count", 0)),
                    "file_size": int(meta.get("file_size", 0)),
                    "ttl_seconds": meta.get("ttl_seconds"),
                    "ttl_set_at": format_utc(parse_time(meta.get("ttl_set_at"))),
                    "ttl_remaining_seconds": ttl_remaining,
                    "max_reads": meta.get("max_reads"),
                    "deadline": format_utc(parse_time(meta.get("deadline"))),
                }
            )
        return rows

    def get_metadata(self, filename: str) -> dict | None:
        entry = self.files.get(self._normalize_name(filename))
        return None if not entry else entry.metadata

    def set_trigger(self, filename: str, trigger_type: str, value) -> bool:
        fname = self._normalize_name(filename)
        entry = self.files.get(fname)
        if not entry:
            raise KeyError(f"File not found in VFS: {fname}")

        if trigger_type == "ttl_seconds":
            entry.metadata["ttl_seconds"] = None if value is None else float(value)
            if entry.metadata["ttl_seconds"] is None:
                entry.metadata["ttl_set_at"] = None
            else:
                now = utcnow()
                entry.metadata["ttl_set_at"] = now
                entry.metadata["last_access_at"] = now
        elif trigger_type == "max_reads":
            entry.metadata["max_reads"] = None if value is None else int(value)
        elif trigger_type == "deadline":
            entry.metadata["deadline"] = parse_time(value)
        else:
            raise ValueError("Unsupported trigger_type. Use ttl_seconds, max_reads, or deadline.")

        return True

    def file_exists(self, filename: str) -> bool:
        return self._normalize_name(filename) in self.files

    def get_all_filenames(self) -> list[str]:
        return list(self.files.keys())

    def serialize(self) -> dict:
        serialized_files = {}
        for fname, entry in self.files.items():
            meta = dict(entry.metadata)
            for field in ("created_at", "modified_at", "last_access_at", "last_read_at", "ttl_set_at", "deadline"):
                meta[field] = format_utc(parse_time(meta.get(field)))
            serialized_files[fname] = {
                "ciphertext": entry.ciphertext,
                "iv": entry.iv,
                "salt": entry.salt,
                "metadata": meta,
            }
        return {"files": serialized_files, "key_iterations": self._key_iterations}

    def deserialize(self, data: dict) -> "VirtualFileSystem":
        self._key_iterations = int(data.get("key_iterations", 10000))
        restored: dict[str, FileEntry] = {}
        for fname, entry in data.get("files", {}).items():
            meta = dict(entry.get("metadata", {}))
            for field in ("created_at", "modified_at", "last_access_at", "last_read_at", "ttl_set_at", "deadline"):
                meta[field] = parse_time(meta.get(field))
            restored[fname] = FileEntry(
                ciphertext=entry["ciphertext"],
                iv=entry["iv"],
                salt=entry["salt"],
                metadata=meta,
            )
        self.files = restored
        return self

    def _make_metadata(self, filename: str, content: bytes) -> dict:
        now = utcnow()
        return {
            "filename": filename,
            "created_at": now,
            "modified_at": now,
            "last_access_at": now,
            "last_read_at": None,
            "read_count": 0,
            "file_size": len(content),
            "file_hash": hashlib.sha256(content).hexdigest(),
            "ttl_seconds": None,
            "ttl_set_at": None,
            "max_reads": None,
            "deadline": None,
            "is_destroyed": False,
        }

    def _decrypt_entry(self, filename: str, file_password: str, increment_read: bool) -> bytes:
        fname = self._normalize_name(filename)
        entry = self.files.get(fname)
        if not entry:
            raise KeyError(f"File not found in VFS: {fname}")
        if entry.metadata.get("is_destroyed"):
            raise ValueError(f"File is marked destroyed: {fname}")

        derived = self._key_derivation.derive_key(file_password, entry.salt, self._key_iterations)

        try:
            plaintext = self._encryption.decrypt(entry.ciphertext, derived, entry.iv)
        except ValueError as e:
            if "Padding is incorrect" in str(e) or "invalid padding bytes" in str(e).lower() or "pkcs#7" in str(e).lower():
                raise ValueError("Invalid file password.") from e
            raise

        if increment_read:
            self.note_file_access(fname, access_time=utcnow(), increment_read=True)
        return plaintext

    @staticmethod
    def _normalize_name(filename: str) -> str:
        name = str(filename).strip().replace("\\", "/").split("/")[-1]
        if not name:
            raise ValueError("filename must not be empty")
        return name
