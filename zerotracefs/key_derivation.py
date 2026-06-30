from __future__ import annotations

import hashlib
import hmac
import os


class KeyDerivation:
    def derive_key(self, password: str, salt: bytes, iterations: int = 10000) -> bytes:
        if not isinstance(password, str) or not password:
            raise ValueError("Password must be a non-empty string.")
        if not isinstance(salt, (bytes, bytearray)):
            raise ValueError("Salt must be bytes.")
        if iterations < 1:
            raise ValueError("Iterations must be positive.")

        try:
            return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), bytes(salt), iterations, dklen=32)
        except Exception:
            return self._fallback_pbkdf2(password.encode("utf-8"), bytes(salt), iterations, 32)

    @staticmethod
    def generate_salt() -> bytes:
        return os.urandom(32)

    @staticmethod
    def hash_password(password: str) -> str:
        return hashlib.sha256(password.encode("utf-8")).hexdigest()

    def verify_password(self, password: str, stored_hash: str | None) -> bool:
        if not stored_hash:
            return False
        return hmac.compare_digest(self.hash_password(password), stored_hash)

    @staticmethod
    def _fallback_pbkdf2(password_raw: bytes, salt_raw: bytes, iterations: int, output_len: int) -> bytes:
        hash_len = 32
        blocks = (output_len + hash_len - 1) // hash_len
        out = b""

        for i in range(1, blocks + 1):
            block_index = i.to_bytes(4, "big")
            u = hmac.new(password_raw, salt_raw + block_index, hashlib.sha256).digest()
            t = bytearray(u)
            for _ in range(2, iterations + 1):
                u = hmac.new(password_raw, u, hashlib.sha256).digest()
                t = bytearray(a ^ b for a, b in zip(t, u))
            out += bytes(t)

        return out[:output_len]
