from __future__ import annotations

from dataclasses import dataclass

from .utils import format_utc, utcnow


@dataclass
class AuditEntry:
    timestamp: str
    event_type: str
    details: str
    filename: str | None


class AuditLogger:
    def __init__(self) -> None:
        self.log_entries: list[AuditEntry] = []

    def log_event(self, event_type: str, details: str, filename: str | None = None) -> dict:
        entry = AuditEntry(
            timestamp=format_utc(utcnow()) or "",
            event_type=str(event_type),
            details=str(details),
            filename=None if filename is None else str(filename),
        )
        self.log_entries.append(entry)
        return entry.__dict__.copy()

    def get_log(self) -> list[dict]:
        return [entry.__dict__.copy() for entry in self.log_entries]

    def get_recent(self, n: int = 20) -> list[dict]:
        return self.get_log()[-int(n) :]

    def serialize(self) -> dict:
        return {"log_entries": self.get_log()}

    def deserialize(self, data: dict) -> "AuditLogger":
        entries = data.get("log_entries", []) if data else []
        self.log_entries = [AuditEntry(**e) for e in entries]
        return self

    def clear(self) -> None:
        self.log_entries = []
