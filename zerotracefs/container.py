from __future__ import annotations

import pickle
from pathlib import Path

from .utils import utcnow


class ContainerManager:
    def __init__(self, container_path: str | Path = Path("data") / "container.pkl") -> None:
        self.container_path = Path(container_path).resolve()
        self.container_path.parent.mkdir(parents=True, exist_ok=True)

    def save_state(self, vfs, auth, triggers, audit) -> None:
        payload = {
            "vfs_data": vfs.serialize(),
            "auth_data": auth.serialize(),
            "trigger_data": triggers.serialize(),
            "audit_data": audit.serialize(),
            "version": "1.0.0",
            "created_at": utcnow().isoformat(),
        }
        with self.container_path.open("wb") as fh:
            pickle.dump(payload, fh)

    def load_state(self, container_path: str | Path | None = None) -> dict:
        path = Path(container_path).resolve() if container_path else self.container_path
        if not path.exists():
            raise FileNotFoundError(f"Container file not found: {path}")

        with path.open("rb") as fh:
            state = pickle.load(fh)

        required = {"vfs_data", "auth_data", "trigger_data", "audit_data"}
        missing = sorted(required.difference(state.keys()))
        if missing:
            raise ValueError(f"Container state is missing fields: {', '.join(missing)}")
        return state

    def container_exists(self) -> bool:
        return self.container_path.exists()

    def destroy_container(self) -> bool:
        if not self.container_path.exists():
            return True
        try:
            self.container_path.unlink()
            return not self.container_path.exists()
        except Exception:
            return False
