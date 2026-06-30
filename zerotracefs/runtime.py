from __future__ import annotations

import json
import os
import shlex
import time
from datetime import datetime, timezone
from pathlib import Path

from .audit import AuditLogger
from .auth import AuthManager
from .container import ContainerManager
from .encryption import EncryptionEngine
from .filesystem import VirtualFileSystem
from .setup_env import run_setup
from .sync import SyncEngine
from .triggers import TriggerEngine
from .ui import (
    display_banner,
    display_file_list,
    display_menu,
    display_status,
    prompt_input,
    prompt_password,
)
from .utils import format_utc, parse_time, utcnow
from .wipe import SecureWiper


def run_zerotracefs() -> bool:
    paths = run_setup(".")
    display_banner()

    wiper = SecureWiper()
    container_manager = ContainerManager(paths["container_path"])
    vfs = VirtualFileSystem()
    auth = AuthManager(max_attempts=5)
    trigger_engine = TriggerEngine()
    audit = AuditLogger()

    master_password = None
    sync_engine = None
    control_mode = "explorer"
    last_external_action = None
    last_external_error = None

    def compute_file_ttl_remaining(meta: dict, now_time=None):
        if meta.get("ttl_seconds") is None:
            return None
        now_v = now_time or utcnow()
        ttl_anchor = meta.get("last_access_at") or meta.get("last_read_at") or meta.get("created_at")
        anchor = parse_time(ttl_anchor)
        if not anchor:
            return None
        age = max(0.0, (now_v - anchor).total_seconds())
        return max(0.0, float(meta["ttl_seconds"]) - age)

    def build_file_snapshot(now_time=None):
        now_v = now_time or utcnow()
        details = []
        for fname in vfs.get_all_filenames():
            meta = vfs.get_metadata(fname)
            details.append(
                {
                    "filename": fname,
                    "read_count": int(meta.get("read_count", 0)),
                    "file_size": int(meta.get("file_size", 0)),
                    "created_at": format_utc(parse_time(meta.get("created_at"))),
                    "modified_at": format_utc(parse_time(meta.get("modified_at"))),
                    "last_access_at": format_utc(parse_time(meta.get("last_access_at"))),
                    "last_read_at": format_utc(parse_time(meta.get("last_read_at"))),
                    "ttl_seconds": meta.get("ttl_seconds"),
                    "ttl_remaining_seconds": compute_file_ttl_remaining(meta, now_time=now_v),
                    "max_reads": meta.get("max_reads"),
                    "deadline": format_utc(parse_time(meta.get("deadline"))),
                }
            )
        return details

    def build_runtime_snapshot():
        now = utcnow()
        file_names = vfs.get_all_filenames()
        uptime_seconds = max(0.0, (now - trigger_engine.system_start_time).total_seconds())
        global_ttl_remaining = None
        if trigger_engine.global_ttl_seconds is not None:
            global_ttl_remaining = max(0.0, trigger_engine.global_ttl_seconds - uptime_seconds)

        deadman_remaining = None
        if trigger_engine.dead_man_switch_interval is not None:
            deadman_remaining = max(
                0.0,
                trigger_engine.dead_man_switch_interval - (now - trigger_engine.last_heartbeat).total_seconds(),
            )

        pending_commands = len(list(paths["commands_path"].glob("*.json")))

        return {
            "timestamp": now.isoformat().replace("+00:00", "Z"),
            "control_mode": control_mode,
            "system": {"uptime_seconds": uptime_seconds, "last_sync": None if not sync_engine else sync_engine.last_scan},
            "files": {"count": len(file_names), "names": file_names, "details": build_file_snapshot(now_time=now)},
            "auth": {
                "failed_attempts": auth.failed_attempts,
                "max_attempts": auth.max_attempts,
                "remaining_attempts": auth.get_remaining_attempts(),
                "duress_hash": auth.state.duress_hash,
            },
            "triggers": {
                "global_ttl_seconds": trigger_engine.global_ttl_seconds,
                "global_ttl_remaining_seconds": global_ttl_remaining,
                "dead_man_switch_interval_seconds": trigger_engine.dead_man_switch_interval,
                "dead_man_remaining_seconds": deadman_remaining,
                "last_heartbeat": format_utc(trigger_engine.last_heartbeat),
            },
            "external_commands": {
                "pending": pending_commands,
                "last_action": last_external_action,
                "last_error": last_external_error,
            },
        }

    def write_runtime_status():
        status_file = paths["control_path"] / "status.json"
        status_file.write_text(json.dumps(build_runtime_snapshot(), indent=2), encoding="utf-8")

    def apply_trigger_actions() -> bool:
        results = trigger_engine.check_all(vfs)
        if results["global"]["triggered"]:
            audit.log_event("TRIGGER_FIRE", f"Global trigger fired: {results['global']['reason']}")
            for fname in vfs.get_all_filenames():
                entry = vfs.files[fname]
                vfs.files[fname] = wiper.destroy_crypto_artifacts(entry.__dict__)  # best-effort sanitization
            vfs.files = {}
            wipe_result = wiper.full_system_wipe(paths["mount_path"], paths["container_path"], paths["control_path"])
            audit.log_event(
                "WIPE_COMPLETE",
                f"Global wipe complete. mount={wipe_result['mount_wiped']} container={wipe_result['container_wiped']}",
            )
            print("Vault is empty")
            return True

        for item in results["files"]:
            fname = item["filename"]
            if not vfs.file_exists(fname):
                continue
            audit.log_event("TRIGGER_FIRE", item["reason"], fname)
            if sync_engine:
                sync_engine.remove_from_mount(fname)
            vfs.remove_file(fname)
            audit.log_event("DESTRUCTION", f"Destroyed due to trigger: {item['reason']}", fname)

        return False

    def destroy_single_file(filename: str, reason: str = "Manual destroy") -> bool:
        if not vfs.file_exists(filename):
            print(f"File not found in vault: {filename}")
            return False
        if sync_engine:
            sync_engine.remove_from_mount(filename)
        vfs.remove_file(filename)
        audit.log_event("DESTRUCTION", reason, filename)
        print(f"Secure wipe complete: {filename}")
        return True

    def save_everything():
        container_manager.save_state(vfs, auth, trigger_engine, audit)

    def read_preview(filename: str, content: bytes, max_text_chars: int = 2000, max_hex_bytes: int = 256) -> dict:
        extension = Path(filename).suffix.lower().lstrip(".") or None
        try:
            text = content.decode("utf-8")
            if all((ord(ch) >= 32 or ch in "\r\n\t") for ch in text):
                return {
                    "preview_type": "text",
                    "preview": text[:max_text_chars],
                    "preview_truncated": len(text) > max_text_chars,
                    "extension": extension,
                }
        except UnicodeDecodeError:
            pass

        clipped = content[:max_hex_bytes]
        return {
            "preview_type": "hex",
            "preview": " ".join(f"{b:02x}" for b in clipped),
            "preview_truncated": len(content) > max_hex_bytes,
            "extension": extension,
        }

    def archive_command_result(command_file: Path, payload: dict | None, status: str, message: str, result_data=None):
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        out_name = f"{stamp}_{command_file.stem}_{status}.json"
        out_path = paths["processed_commands_path"] / out_name
        result = {
            "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "source_file": command_file.name,
            "status": status,
            "message": message,
            "payload": payload,
            "data": result_data,
        }
        out_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
        command_file.unlink(missing_ok=True)

    def process_external_commands() -> dict:
        nonlocal last_external_action, last_external_error

        command_files = sorted(paths["commands_path"].glob("*.json"))
        if not command_files:
            return {"stop": False}

        stop_requested = False
        for command_file in command_files:
            payload = None
            try:
                payload = json.loads(command_file.read_text(encoding="utf-8"))
                action = str(payload.get("action", "")).strip().lower()
                if not action:
                    raise ValueError("Command payload must include a non-empty 'action'.")

                last_external_action = action
                last_external_error = None

                if action == "status":
                    archive_command_result(command_file, payload, "ok", "Status captured", build_runtime_snapshot())
                elif action == "list":
                    rows = vfs.list_files()
                    archive_command_result(command_file, payload, "ok", f"Listed {len(rows)} file(s)", {"count": len(rows), "files": rows})
                elif action == "audit":
                    n_recent = int(payload.get("recent", payload.get("n", 20)))
                    recent = audit.get_recent(max(1, n_recent))
                    archive_command_result(command_file, payload, "ok", f"Fetched {len(recent)} audit entries", {"count": len(recent), "entries": recent})
                elif action == "read":
                    filename = Path(str(payload.get("target", payload.get("filename", "")))).name
                    if not vfs.file_exists(filename):
                        raise ValueError(f"File not found in vault: {filename}")
                    file_password = str(payload.get("file_password", payload.get("password", ""))).strip()
                    content = vfs.read_file(filename, file_password)
                    meta = vfs.get_metadata(filename)
                    data = {
                        "filename": filename,
                        "bytes": len(content),
                        "read_count": int(meta.get("read_count", 0)),
                        "ttl_remaining_seconds": compute_file_ttl_remaining(meta),
                    }
                    data.update(read_preview(filename, content))
                    audit.log_event("FILE_READ", "File read via Explorer", filename)
                    archive_command_result(command_file, payload, "ok", f"Read {filename}", data)
                    apply_trigger_actions()
                elif action == "export":
                    filename = Path(str(payload.get("target", payload.get("filename", "")))).name
                    if not vfs.file_exists(filename):
                        raise ValueError(f"File not found in vault: {filename}")
                    destination = str(payload.get("destination", payload.get("dest", payload.get("output", "")))).strip()
                    if not destination:
                        destination = str(paths["control_path"] / "exports")
                    file_password = str(payload.get("file_password", payload.get("password", ""))).strip()
                    content = vfs.read_file(filename, file_password)
                    dest_path = Path(destination)
                    export_path = (dest_path / filename) if dest_path.is_dir() else dest_path
                    export_path.parent.mkdir(parents=True, exist_ok=True)
                    export_path.write_bytes(content)
                    audit.log_event("FILE_READ", f"Exported via Explorer to {export_path}", filename)
                    meta = vfs.get_metadata(filename)
                    archive_command_result(
                        command_file,
                        payload,
                        "ok",
                        f"Exported {filename}",
                        {
                            "filename": filename,
                            "export_path": str(export_path),
                            "bytes": len(content),
                            "read_count": int(meta.get("read_count", 0)),
                            "ttl_remaining_seconds": compute_file_ttl_remaining(meta),
                        },
                    )
                    apply_trigger_actions()
                elif action == "set-ttl":
                    filename = Path(str(payload.get("target", payload.get("filename", "")))).name
                    minutes = float(payload.get("minutes", payload.get("value", 0)))
                    if minutes <= 0:
                        raise ValueError("set-ttl requires a positive 'minutes' value.")
                    vfs.set_trigger(filename, "ttl_seconds", minutes * 60)
                    audit.log_event("TRIGGER_SET", f"Set TTL to {minutes:.2f} minutes via Explorer", filename)
                    archive_command_result(command_file, payload, "ok", f"TTL set for {filename}")
                elif action == "set-reads":
                    filename = Path(str(payload.get("target", payload.get("filename", "")))).name
                    max_reads = int(payload.get("max_reads", payload.get("value", 0)))
                    if max_reads < 1:
                        raise ValueError("set-reads requires integer 'max_reads' >= 1.")
                    vfs.set_trigger(filename, "max_reads", max_reads)
                    audit.log_event("TRIGGER_SET", f"Set max reads to {max_reads} via Explorer", filename)
                    archive_command_result(command_file, payload, "ok", f"Read limit set for {filename}")
                elif action == "set-deadline":
                    filename = Path(str(payload.get("target", payload.get("filename", "")))).name
                    deadline_text = str(payload.get("deadline", payload.get("value", ""))).strip()
                    deadline = parse_time(deadline_text)
                    if not deadline:
                        raise ValueError("set-deadline requires parseable 'deadline' datetime.")
                    vfs.set_trigger(filename, "deadline", deadline)
                    audit.log_event("TRIGGER_SET", f"Set deadline to {deadline.isoformat()} via Explorer", filename)
                    archive_command_result(command_file, payload, "ok", f"Deadline set for {filename}")
                elif action == "destroy":
                    filename = Path(str(payload.get("target", payload.get("filename", "")))).name
                    if not destroy_single_file(filename, reason="Manual file destruction via Explorer"):
                        raise ValueError(f"Destroy failed for {filename}")
                    archive_command_result(command_file, payload, "ok", f"Destroyed {filename}")
                elif action == "auth-fail":
                    auth.state.failed_attempts += 1
                    audit.log_event("AUTH_FAIL", "Failed authentication via GUI Open Securely")
                    if auth.state.failed_attempts >= auth.state.max_attempts:
                        auth.state.is_locked = True
                        audit.log_event("AUTH_FAIL", "Authentication lockout reached via GUI")
                        save_everything()
                        vfs.files = {}
                        wiper.full_system_wipe(paths["mount_path"], paths["container_path"], paths["control_path"])
                        archive_command_result(command_file, payload, "error", "Auth locked out. Vault destroyed.")
                        stop_requested = True
                    else:
                        archive_command_result(command_file, payload, "error", f"Auth failed. {auth.get_remaining_attempts()} attempts left.")
                elif action == "destroy-all":
                    audit.log_event("DESTRUCTION", "Manual full vault destruction via Explorer")
                    vfs.files = {}
                    wiper.full_system_wipe(paths["mount_path"], paths["container_path"], paths["control_path"])
                    archive_command_result(command_file, payload, "ok", "Full vault destruction complete")
                    stop_requested = True
                elif action == "import":
                    source_path = Path(str(payload.get("source", payload.get("path", payload.get("target", ""))))).resolve()
                    if not source_path.exists():
                        raise ValueError("import requires an existing file path in 'source' or 'path'.")
                    content = source_path.read_bytes()
                    filename = source_path.name
                    file_password = str(payload.get("file_password", payload.get("password", ""))).strip()
                    if not file_password:
                        raise ValueError("import requires a 'file_password'")
                    vfs.add_file(filename, content, file_password)
                    
                    # Write the .zfs encrypted file to the mount directory
                    entry = vfs.files.get(vfs._normalize_name(filename))
                    if entry:
                        zfs_path = paths["mount_path"] / f"{filename}.zfs"
                        paths["mount_path"].mkdir(parents=True, exist_ok=True)
                        zfs_payload = entry.salt + entry.iv + entry.ciphertext
                        zfs_path.write_bytes(zfs_payload)
                    
                    # Delete the original source file so it's fully moved into the vault
                    try:
                        source_path.unlink()
                    except Exception as e:
                        print(f"Warning: Could not delete source file after import: {e}")
                    
                    audit.log_event("FILE_CREATE", "Imported file into vault via GUI/Explorer", filename)
                    archive_command_result(command_file, payload, "ok", f"Imported {filename}")
                elif action == "open-secure":
                    filename = Path(str(payload.get("target", payload.get("filename", "")))).name
                    if not vfs.file_exists(filename):
                        raise ValueError(f"File not found in vault: {filename}")
                    file_password = str(payload.get("file_password", payload.get("password", ""))).strip()
                    
                    content = vfs.read_file(filename, file_password)
                    import uuid
                    temp_dir = paths["control_path"] / "open_temp"
                    temp_dir.mkdir(parents=True, exist_ok=True)
                    stamp = uuid.uuid4().hex[:8]
                    temp_path = temp_dir / f"{stamp}_{filename}"
                    temp_path.write_bytes(content)
                    
                    audit.log_event("FILE_READ", f"Opened securely to {temp_path}", filename)
                    archive_command_result(command_file, payload, "ok", f"Opened securely: {filename}", {"temporary_path": str(temp_path)})
                    apply_trigger_actions()
                elif action == "lock":
                    sync_engine.clear_mount()
                    audit.log_event("SYSTEM_STOP", "Vault locked via Explorer")
                    save_everything()
                    archive_command_result(command_file, payload, "ok", "Vault locked")
                    stop_requested = True
                elif action == "quit":
                    audit.log_event("SYSTEM_STOP", "Secure shutdown requested via Explorer")
                    save_everything()
                    sync_engine.clear_mount()
                    archive_command_result(command_file, payload, "ok", "Secure shutdown complete")
                    stop_requested = True
                else:
                    raise ValueError(f"Unknown action: {action}")
            except Exception as exc:
                last_external_error = str(exc)
                archive_command_result(command_file, payload, "error", str(exc))

            if stop_requested:
                break

        return {"stop": stop_requested}

    if not container_manager.container_exists():
        answer = prompt_input("No existing vault found. Create new vault? (y/n): ").strip().lower()
        if answer not in {"y", "yes"}:
            print("Vault creation cancelled.")
            return False

        while True:
            master_password = prompt_password("Set master password: ")
            confirm = prompt_password("Confirm master password: ")
            if not master_password:
                print("Master password cannot be empty.")
                continue
            if master_password != confirm:
                print("Passwords do not match. Try again.")
                continue
            break

        while True:
            duress_password = prompt_password("Set duress password (triggers full destruction): ")
            if not duress_password:
                print("Duress password cannot be empty.")
                continue
            if duress_password == master_password:
                print("Duress password must be different from master password.")
                continue
            break

        dead_man_hours = float(prompt_input("Set dead man's switch interval in hours (0 to disable): ") or 0)
        global_ttl_hours = float(prompt_input("Set global vault TTL in hours (0 for no limit): ") or 0)

        auth.setup(master_password, duress_password)
        trigger_engine.set_dead_man_switch(dead_man_hours * 3600)
        trigger_engine.set_global_ttl(global_ttl_hours * 3600)
        audit.log_event("SYSTEM_START", "New vault initialized")
        save_everything()
        print("Vault initialized and saved to data/container.pkl")
    else:
        state = container_manager.load_state(paths["container_path"])
        vfs.deserialize(state["vfs_data"])
        auth.deserialize(state["auth_data"])
        trigger_engine.deserialize(state["trigger_data"])
        audit.deserialize(state["audit_data"])

        while True:
            candidate = prompt_password("Enter vault password: ")
            auth_result = auth.authenticate(candidate)
            if auth_result == "granted":
                master_password = candidate
                audit.log_event("AUTH_SUCCESS", "Vault unlocked successfully")
                break
            if auth_result == "duress":
                audit.log_event("AUTH_DURESS", "Duress password accepted")
                save_everything()
                wiper.full_system_wipe(paths["mount_path"], paths["container_path"], paths["control_path"])
                print("Vault is empty")
                return False
            if auth_result == "lockout":
                audit.log_event("AUTH_FAIL", "Authentication lockout reached")
                save_everything()
                wiper.full_system_wipe(paths["mount_path"], paths["container_path"], paths["control_path"])
                print("Vault is empty")
                return False

            audit.log_event("AUTH_FAIL", "Incorrect password")
            save_everything()
            print(f"Wrong password. {auth.get_remaining_attempts()} attempts remaining.")

    sync_engine = SyncEngine(paths["mount_path"], vfs, master_password, encryption=EncryptionEngine())
    
    is_gui = os.getenv("ZTFS_GUI_MODE", "0") == "1"
    
    sync_engine.clear_mount()
    sync_engine.populate_mount()

    mode_env = os.getenv("ZTFS_CONTROL_MODE", "").strip().lower()
    control_mode = "terminal" if mode_env in {"terminal", "t", "1"} else "explorer"
    if is_gui: control_mode = "gui (strict vault)"
    print(f"Control mode active: {control_mode}")

    write_runtime_status()
    cycle_counter = 0

    try:
        while True:
            cycle_counter += 1
            changes = {}
            if not is_gui:
                changes = sync_engine.sync_all()
            else:
                # In GUI strict mode, the mount is unused and we only sync triggers
                pass
                
            trigger_engine.update_heartbeat()

            external_cmd_result = process_external_commands()
            if external_cmd_result["stop"]:
                break

            for fname in changes.get("new", []):
                audit.log_event("FILE_CREATE", "File added and encrypted", fname)
            for fname in changes.get("modified", []):
                audit.log_event("FILE_MODIFY", "File modified and re-encrypted", fname)
            for fname in changes.get("deleted", []):
                audit.log_event("FILE_DELETE", "File deleted from mount", fname)
            for fname in changes.get("read", []):
                if vfs.note_file_read(fname):
                    audit.log_event("FILE_READ", "Read detected from mount access", fname)

            if apply_trigger_actions():
                break

            save_everything()
            write_runtime_status()

            if control_mode in ("explorer", "gui (strict vault)"):
                if cycle_counter % 5 == 0:
                    display_status(vfs, trigger_engine, auth, last_sync=sync_engine.last_scan)
                time.sleep(3)
                continue

            display_status(vfs, trigger_engine, auth, last_sync=sync_engine.last_scan)
            display_menu()
            cmd = prompt_input("Command (or press Enter to continue monitoring): ").strip()
            if not cmd:
                time.sleep(3)
                continue

            parts = shlex.split(cmd)
            action = parts[0].lower()

            if action == "status":
                display_status(vfs, trigger_engine, auth, last_sync=sync_engine.last_scan)
            elif action == "list":
                display_file_list(vfs)
            elif action == "add" and len(parts) >= 2:
                source = Path(parts[1])
                if not source.exists():
                    print("Usage: add <filepath>")
                else:
                    content = source.read_bytes()
                    fname = source.name
                    file_password = prompt_password(f"Set password for {fname}: ")
                    confirm_password = prompt_password(f"Confirm password for {fname}: ")
                    if file_password != confirm_password or not file_password:
                        print("Password confirmation failed or empty password.")
                    else:
                        vfs.add_file(fname, content, file_password)
                        (paths["mount_path"] / fname).write_bytes(content)
                        audit.log_event("FILE_CREATE", "Imported file into vault", fname)
                        print(f"Imported: {fname}")
            elif action == "read" and len(parts) >= 2:
                fname = parts[1]
                if not vfs.file_exists(fname):
                    print("Usage: read <filename>")
                else:
                    file_password = prompt_password(f"Enter password for {fname}: ")
                    try:
                        content = vfs.read_file(fname, file_password)
                        preview = read_preview(fname, content)
                        print("--- FILE CONTENT START ---")
                        print(preview["preview"])
                        print("--- FILE CONTENT END ---")
                        audit.log_event("FILE_READ", "File read command executed", fname)
                        apply_trigger_actions()
                    except ValueError as e:
                        print(f"Error reading file: {e}")
                        auth.state.failed_attempts += 1
                        if auth.state.failed_attempts >= auth.state.max_attempts:
                            auth.state.is_locked = True
                            save_everything()
                            vfs.files = {}
                            wiper.full_system_wipe(paths["mount_path"], paths["container_path"], paths["control_path"])
                            print("Auth locked out. Vault destroyed.")
                            break
            elif action == "set-ttl" and len(parts) >= 3:
                fname = parts[1]
                minutes = float(parts[2])
                vfs.set_trigger(fname, "ttl_seconds", minutes * 60)
                audit.log_event("TRIGGER_SET", f"Set TTL to {minutes:.2f} minutes", fname)
            elif action == "set-reads" and len(parts) >= 3:
                fname = parts[1]
                max_reads = int(parts[2])
                vfs.set_trigger(fname, "max_reads", max_reads)
                audit.log_event("TRIGGER_SET", f"Set max reads to {max_reads}", fname)
            elif action == "set-deadline" and len(parts) >= 4:
                fname = parts[1]
                dt_string = " ".join(parts[2:])
                deadline = parse_time(dt_string)
                if not deadline:
                    print("Could not parse datetime.")
                else:
                    vfs.set_trigger(fname, "deadline", deadline)
                    audit.log_event("TRIGGER_SET", f"Set deadline to {deadline.isoformat()}", fname)
            elif action == "audit":
                for row in audit.get_log():
                    print(row)
            elif action == "export" and len(parts) >= 3:
                fname = parts[1]
                destination = Path(parts[2])
                if not vfs.file_exists(fname):
                    print("Usage: export <filename> <dest>")
                else:
                    file_password = prompt_password(f"Enter password for {fname}: ")
                    try:
                        content = vfs.read_file(fname, file_password)
                        export_path = destination / fname if destination.is_dir() else destination
                        export_path.parent.mkdir(parents=True, exist_ok=True)
                        export_path.write_bytes(content)
                        audit.log_event("FILE_READ", f"Exported to {export_path}", fname)
                        apply_trigger_actions()
                    except ValueError as e:
                        print(f"Error exporting file: {e}")
                        auth.state.failed_attempts += 1
                        if auth.state.failed_attempts >= auth.state.max_attempts:
                            auth.state.is_locked = True
                            save_everything()
                            vfs.files = {}
                            wiper.full_system_wipe(paths["mount_path"], paths["container_path"], paths["control_path"])
                            print("Auth locked out. Vault destroyed.")
                            break
            elif action == "destroy" and len(parts) >= 2:
                destroy_single_file(parts[1], reason="Manual file destruction")
            elif action == "destroy-all":
                confirm = prompt_input("Type DESTROY to confirm full vault wipe: ").strip()
                if confirm == "DESTROY":
                    audit.log_event("DESTRUCTION", "Manual full vault destruction")
                    vfs.files = {}
                    wiper.full_system_wipe(paths["mount_path"], paths["container_path"], paths["control_path"])
                    print("Full vault destruction complete.")
                    break
                print("Cancelled full destruction.")
            elif action == "lock":
                sync_engine.clear_mount()
                audit.log_event("SYSTEM_STOP", "Vault locked")
                save_everything()
                print("Vault locked. Mount wiped, encrypted backend retained.")
                break
            elif action == "change-password":
                old_pw = prompt_password("Enter current master password: ")
                new_pw = prompt_password("Enter new master password: ")
                confirm_pw = prompt_password("Confirm new master password: ")
                if not new_pw or new_pw != confirm_pw:
                    print("New password confirmation failed.")
                elif auth.change_password(old_pw, new_pw):
                    decrypted = {}
                    failed = False
                    for fname in vfs.get_all_filenames():
                        try:
                            decrypted[fname] = vfs.peek_file(fname, old_pw)
                        except Exception:
                            failed = True
                            break
                    if failed:
                        print("Failed to re-key files. Password unchanged.")
                    else:
                        for fname, content in decrypted.items():
                            vfs.update_file(fname, content, new_pw)
                        master_password = new_pw
                        sync_engine.master_password = new_pw
                        sync_engine.populate_mount()
                        audit.log_event("PASSWORD_CHANGE", "Master password changed successfully")
                        print("Master password changed and vault re-keyed.")
                else:
                    print("Current password is incorrect.")
            elif action == "quit":
                audit.log_event("SYSTEM_STOP", "Secure shutdown requested")
                save_everything()
                sync_engine.clear_mount()
                print("Secure shutdown complete.")
                break
            else:
                print("Unknown command. Type one of the listed commands.")

            save_everything()
            time.sleep(3)
    finally:
        if sync_engine:
            sync_engine.clear_mount()

    return True
