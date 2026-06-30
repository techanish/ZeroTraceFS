from __future__ import annotations

import gc
import os
from pathlib import Path


class SecureWiper:
    def wipe_file(self, file_path: str | Path) -> bool:
        path = Path(file_path)
        try:
            if not path.exists():
                return False

            size = path.stat().st_size
            if size <= 0:
                path.unlink(missing_ok=True)
                return True

            for _ in range(3):
                self._overwrite_pass(path, size, random_fill=True)
            self._overwrite_pass(path, size, random_fill=False)

            with path.open("wb"):
                pass

            path.unlink(missing_ok=True)
            return not path.exists()
        except Exception:
            return False

    def wipe_directory(self, dir_path: str | Path) -> bool:
        path = Path(dir_path)
        if not path.exists():
            return True

        ok = True
        files = sorted([p for p in path.rglob("*") if p.is_file()], key=lambda p: len(p.parts), reverse=True)
        for file_path in files:
            ok = self.wipe_file(file_path) and ok

        dirs = sorted([p for p in path.rglob("*") if p.is_dir()], key=lambda p: len(p.parts), reverse=True)
        for d in dirs:
            try:
                d.rmdir()
            except Exception:
                pass

        return ok

    def wipe_memory_object(self, namespace: dict, obj_name: str) -> bool:
        if obj_name not in namespace:
            return False
        value = namespace[obj_name]
        size = len(repr(value).encode("utf-8"))
        namespace[obj_name] = os.urandom(max(size, 32))
        del namespace[obj_name]
        gc.collect()
        return True

    def destroy_crypto_artifacts(self, file_entry: dict | None) -> dict | None:
        if not isinstance(file_entry, dict):
            return file_entry
        for key in ("key", "iv", "salt"):
            value = file_entry.get(key)
            if isinstance(value, (bytes, bytearray)):
                file_entry[key] = None
        return file_entry

    def full_system_wipe(self, mount_path: str | Path, container_path: str | Path | None, control_path: str | Path | None = None) -> dict:
        mount_ok = self.wipe_directory(mount_path)
        container_ok = True
        if container_path:
            cpath = Path(container_path)
            if cpath.exists():
                container_ok = self.wipe_file(cpath)
                
        control_ok = True
        if control_path:
            ctrl = Path(control_path)
            if ctrl.exists():
                processed_dir = ctrl / "processed"
                if processed_dir.exists():
                    self.wipe_directory(processed_dir)
                    
                commands_dir = ctrl / "commands"
                if commands_dir.exists():
                    self.wipe_directory(commands_dir)
                
                # Wipe status
                for f in ctrl.glob("*.*"):
                    if f.is_file() and f.name != "lock":
                        self.wipe_file(f)
                        
                gui_log = ctrl.parent / "gui.log"
                if gui_log.exists():
                    self.wipe_file(gui_log)
                
        gc.collect()
        return {"mount_wiped": mount_ok, "container_wiped": container_ok, "control_wiped": control_ok, "completed": mount_ok and container_ok}

    @staticmethod
    def _overwrite_pass(path: Path, size: int, random_fill: bool) -> None:
        chunk_size = 1024 * 1024
        with path.open("r+b") as fh:
            remaining = int(size)
            while remaining > 0:
                n = min(chunk_size, remaining)
                data = os.urandom(n) if random_fill else (b"\x00" * n)
                fh.write(data)
                remaining -= n
            fh.flush()
