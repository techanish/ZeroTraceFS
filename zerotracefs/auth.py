from __future__ import annotations

from dataclasses import dataclass

from .key_derivation import KeyDerivation
from .utils import format_utc, parse_time, utcnow


@dataclass
class AuthState:
    master_hash: str | None = None
    duress_hash: str | None = None
    failed_attempts: int = 0
    max_attempts: int = 5
    is_locked: bool = False
    last_auth_time: object = None


class AuthManager:
    def __init__(self, max_attempts: int = 5):
        self.state = AuthState(max_attempts=int(max_attempts))
        self._kdf = KeyDerivation()

    @property
    def failed_attempts(self) -> int:
        return self.state.failed_attempts

    @property
    def max_attempts(self) -> int:
        return self.state.max_attempts

    @property
    def master_hash(self) -> str | None:
        return self.state.master_hash

    def setup(self, master_password: str, duress_password: str) -> None:
        if not master_password or not duress_password:
            raise ValueError("Master and duress passwords must not be empty.")
        if master_password == duress_password:
            raise ValueError("Master and duress passwords must be different.")

        self.state.master_hash = self._kdf.hash_password(master_password)
        self.state.duress_hash = self._kdf.hash_password(duress_password)
        self.state.failed_attempts = 0
        self.state.is_locked = False
        self.state.last_auth_time = utcnow()

    def authenticate(self, input_password: str) -> str:
        if self.state.is_locked:
            return "lockout"

        input_hash = self._kdf.hash_password(input_password)

        if self.state.master_hash and input_hash == self.state.master_hash:
            self.reset_attempts()
            self.state.last_auth_time = utcnow()
            return "granted"

        if self.state.duress_hash and input_hash == self.state.duress_hash:
            self.state.last_auth_time = utcnow()
            return "duress"

        self.state.failed_attempts += 1
        if self.state.failed_attempts >= self.state.max_attempts:
            self.state.is_locked = True
            self.state.last_auth_time = utcnow()
            return "lockout"

        return "denied"

    def get_remaining_attempts(self) -> int:
        return max(0, self.state.max_attempts - self.state.failed_attempts)

    def reset_attempts(self) -> None:
        self.state.failed_attempts = 0
        self.state.is_locked = False

    def change_password(self, old_password: str, new_password: str) -> bool:
        if not old_password or not new_password or old_password == new_password:
            return False

        old_hash = self._kdf.hash_password(old_password)
        if old_hash != self.state.master_hash:
            return False

        self.state.master_hash = self._kdf.hash_password(new_password)
        self.state.last_auth_time = utcnow()
        return True

    def is_lockout_triggered(self) -> bool:
        return self.state.failed_attempts >= self.state.max_attempts

    def serialize(self) -> dict:
        return {
            "master_hash": self.state.master_hash,
            "duress_hash": self.state.duress_hash,
            "failed_attempts": self.state.failed_attempts,
            "max_attempts": self.state.max_attempts,
            "is_locked": self.state.is_locked,
            "last_auth_time": format_utc(parse_time(self.state.last_auth_time)),
        }

    def deserialize(self, data: dict) -> "AuthManager":
        self.state.master_hash = data.get("master_hash")
        self.state.duress_hash = data.get("duress_hash")
        self.state.failed_attempts = int(data.get("failed_attempts", 0))
        self.state.max_attempts = int(data.get("max_attempts", 5))
        self.state.is_locked = bool(data.get("is_locked", False))
        self.state.last_auth_time = parse_time(data.get("last_auth_time"))
        return self
