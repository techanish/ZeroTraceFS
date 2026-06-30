from __future__ import annotations

from datetime import datetime, timezone


def display_banner() -> None:
    banner = [
        "========================================================",
        "                ZERO TRACE FILE SYSTEM                  ",
        "                   ZeroTraceFS Vault                    ",
        "       Self-Destructing Encrypted File System           ",
        "",
        "            AES-256-CBC | Trigger-Driven Wipe           ",
        "========================================================",
    ]
    print("\n".join(banner))


def format_time_remaining(seconds: float | None) -> str:
    if seconds is None:
        return "N/A"
    if seconds <= 0:
        return "expired"
    total = int(seconds)
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    return f"{h:02d}h {m:02d}m {s:02d}s"


def display_status(vfs, triggers, auth, last_sync: str | None = None) -> None:
    now = datetime.now(timezone.utc)
    file_count = len(vfs.get_all_filenames())
    uptime = max(0.0, (now - triggers.system_start_time).total_seconds())

    if triggers.global_ttl_seconds is not None:
        ttl_remaining = triggers.global_ttl_seconds - uptime
        ttl_text = format_time_remaining(ttl_remaining)
    else:
        ttl_text = "Disabled"

    if triggers.dead_man_switch_interval is not None:
        deadman_remaining = triggers.dead_man_switch_interval - (now - triggers.last_heartbeat).total_seconds()
        deadman_text = format_time_remaining(deadman_remaining)
    else:
        deadman_text = "Disabled"

    print("\nVault Status Dashboard")
    print(f"Files in vault:           {file_count}")
    print(f"Global TTL remaining:     {ttl_text}")
    print(f"Dead man's switch:        {deadman_text}")
    print(f"Failed auth attempts:     {auth.failed_attempts} / {auth.max_attempts}")
    print(f"System uptime:            {format_time_remaining(uptime)}")
    print(f"Last sync:                {last_sync or 'N/A'}")


def display_file_list(vfs) -> None:
    rows = vfs.list_files()
    print("\nVault File List")
    if not rows:
        print("No files currently in vault.")
        return
    for row in rows:
        print(f"- {row['filename']} ({row['file_size']} bytes, reads={row['read_count']})")


def display_menu() -> None:
    print("\nCommands")
    print("status")
    print("list")
    print("add <filepath>")
    print("read <filename>")
    print("set-ttl <filename> <minutes>")
    print("set-reads <filename> <max>")
    print("set-deadline <filename> <YYYY-mm-dd HH:MM:SS>")
    print("audit")
    print("export <filename> <dest>")
    print("destroy <filename>")
    print("destroy-all")
    print("lock")
    print("change-password")
    print("quit")


def prompt_password(message: str = "Enter password: ") -> str:
    import os
    if os.environ.get("ZTFS_GUI_MODE") == "1":
        # In GUI mode, read from predefined environment variables
        msg_lower = message.lower()
        if "master" in msg_lower or "vault" in msg_lower:
            return os.environ.get("ZTFS_MASTER_PASSWORD", "")
        if "duress" in msg_lower:
            return os.environ.get("ZTFS_DURESS_PASSWORD", "")
            
    import getpass
    return getpass.getpass(message)


def prompt_input(message: str = "Input: ") -> str:
    import os
    if os.environ.get("ZTFS_GUI_MODE") == "1":
        msg_lower = message.lower()
        if "create new vault" in msg_lower:
            return "y"
        if "dead man" in msg_lower:
            return os.environ.get("ZTFS_DEADMAN_HOURS", "0")
        if "global vault ttl" in msg_lower:
            return os.environ.get("ZTFS_GLOBAL_TTL_HOURS", "0")
        if "command" in msg_lower:
            # Block forever to simulate the background loop without exiting
            import time
            while True:
                time.sleep(10)
            return ""
    return input(message)
