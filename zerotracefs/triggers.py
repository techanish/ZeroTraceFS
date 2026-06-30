from __future__ import annotations

from .utils import format_utc, parse_time, utcnow


class TriggerEngine:
    def __init__(self, global_ttl_seconds: float | None = None, dead_man_switch_interval: float | None = None) -> None:
        self.global_ttl_seconds = float(global_ttl_seconds) if global_ttl_seconds else None
        self.dead_man_switch_interval = float(dead_man_switch_interval) if dead_man_switch_interval else None
        self.system_start_time = utcnow()
        self.last_heartbeat = utcnow()

    def check_file_triggers(self, file_metadata: dict) -> dict:
        now = utcnow()

        ttl_seconds = file_metadata.get("ttl_seconds")
        if ttl_seconds is not None:
            ttl_anchor = file_metadata.get("last_access_at") or file_metadata.get("last_read_at") or file_metadata.get("created_at")
            anchor = parse_time(ttl_anchor, default=now)
            age = max(0.0, (now - anchor).total_seconds())
            if age >= float(ttl_seconds):
                return {"triggered": True, "reason": "Per-file TTL expired"}

        max_reads = file_metadata.get("max_reads")
        if max_reads is not None and int(file_metadata.get("read_count", 0)) > int(max_reads):
            return {"triggered": True, "reason": "Read limit exceeded"}

        deadline = parse_time(file_metadata.get("deadline"))
        if deadline and now >= deadline:
            return {"triggered": True, "reason": "Date deadline reached"}

        return {"triggered": False, "reason": ""}

    def check_global_triggers(self) -> dict:
        now = utcnow()

        if self.global_ttl_seconds is not None:
            uptime = max(0.0, (now - self.system_start_time).total_seconds())
            if uptime > self.global_ttl_seconds:
                return {"triggered": True, "reason": "Global vault TTL expired"}

        if self.dead_man_switch_interval is not None:
            stale_for = (now - self.last_heartbeat).total_seconds()
            if stale_for > self.dead_man_switch_interval:
                return {"triggered": True, "reason": "Dead man's switch triggered"}

        return {"triggered": False, "reason": ""}

    def check_all(self, vfs) -> dict:
        global_result = self.check_global_triggers()
        file_results: list[dict] = []

        if not global_result["triggered"]:
            for fname in vfs.get_all_filenames():
                meta = vfs.get_metadata(fname)
                if not meta or meta.get("is_destroyed"):
                    continue
                trigger_result = self.check_file_triggers(meta)
                if trigger_result["triggered"]:
                    file_results.append({"filename": fname, "reason": trigger_result["reason"]})

        return {"global": global_result, "files": file_results}

    def update_heartbeat(self) -> None:
        self.last_heartbeat = utcnow()

    def set_global_ttl(self, seconds: float | None) -> None:
        self.global_ttl_seconds = None if not seconds or seconds <= 0 else float(seconds)

    def set_dead_man_switch(self, seconds: float | None) -> None:
        self.dead_man_switch_interval = None if not seconds or seconds <= 0 else float(seconds)
        self.last_heartbeat = utcnow()

    def serialize(self) -> dict:
        return {
            "global_ttl_seconds": self.global_ttl_seconds,
            "system_start_time": format_utc(self.system_start_time),
            "dead_man_switch_interval": self.dead_man_switch_interval,
            "last_heartbeat": format_utc(self.last_heartbeat),
        }

    def deserialize(self, data: dict) -> "TriggerEngine":
        self.global_ttl_seconds = data.get("global_ttl_seconds")
        self.system_start_time = parse_time(data.get("system_start_time"), default=utcnow())
        self.dead_man_switch_interval = data.get("dead_man_switch_interval")
        self.last_heartbeat = parse_time(data.get("last_heartbeat"), default=utcnow())
        return self
