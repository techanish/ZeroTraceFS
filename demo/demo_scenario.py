from __future__ import annotations

import time

from zerotracefs.audit import AuditLogger
from zerotracefs.auth import AuthManager
from zerotracefs.filesystem import VirtualFileSystem
from zerotracefs.setup_env import run_setup
from zerotracefs.sync import SyncEngine
from zerotracefs.triggers import TriggerEngine
from zerotracefs.wipe import SecureWiper


def run_demo_scenario() -> None:
    paths = run_setup(".")
    wiper = SecureWiper()
    wiper.wipe_directory(paths["mount_path"])
    if paths["container_path"].exists():
        wiper.wipe_file(paths["container_path"])

    vfs = VirtualFileSystem()
    auth = AuthManager(max_attempts=5)
    triggers = TriggerEngine()
    audit = AuditLogger()

    auth.setup("demo123", "panic999")
    triggers.set_dead_man_switch(300)
    triggers.set_global_ttl(600)
    audit.log_event("SYSTEM_START", "Demo vault initialized")

    sync_engine = SyncEngine(paths["mount_path"], vfs, master_password="demo123")

    (paths["mount_path"] / "secret_note.txt").write_text("This is classified information", encoding="utf-8")
    (paths["mount_path"] / "api_key.txt").write_text("sk-abc123def456", encoding="utf-8")
    (paths["mount_path"] / "patient_record.txt").write_text("Patient: John Doe, SSN: 123-45-6789", encoding="utf-8")

    changes = sync_engine.sync_all()
    print(changes)

    vfs.set_trigger("api_key.txt", "max_reads", 2)
    for _ in range(2):
        vfs.read_file("api_key.txt", "demo123")
    vfs.read_file("api_key.txt", "demo123")

    vfs.set_trigger("secret_note.txt", "ttl_seconds", 2)
    time.sleep(3)

    print("Audit log entries:")
    for row in audit.get_log():
        print(row)


if __name__ == "__main__":
    run_demo_scenario()
