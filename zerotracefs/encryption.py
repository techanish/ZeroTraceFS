from __future__ import annotations

import os
from pathlib import Path

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


class EncryptionEngine:
    def encrypt(self, plaintext: bytes, key: bytes, iv: bytes) -> bytes:
        self._validate_key_iv(key, iv)
        padder = padding.PKCS7(128).padder()
        padded = padder.update(plaintext) + padder.finalize()
        cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
        encryptor = cipher.encryptor()
        return encryptor.update(padded) + encryptor.finalize()

    def decrypt(self, ciphertext: bytes, key: bytes, iv: bytes) -> bytes:
        self._validate_key_iv(key, iv)
        cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
        decryptor = cipher.decryptor()
        padded = decryptor.update(ciphertext) + decryptor.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        return unpadder.update(padded) + unpadder.finalize()

    @staticmethod
    def generate_iv() -> bytes:
        return os.urandom(16)

    @staticmethod
    def generate_key() -> bytes:
        return os.urandom(32)

    def encrypt_file(self, file_path: str | Path, key: bytes) -> dict[str, bytes]:
        path = Path(file_path)
        if not path.exists():
            raise FileNotFoundError(str(path))
        plaintext = path.read_bytes()
        iv = self.generate_iv()
        ciphertext = self.encrypt(plaintext, key, iv)
        return {"ciphertext": ciphertext, "iv": iv}

    def decrypt_to_file(self, ciphertext: bytes, key: bytes, iv: bytes, output_path: str | Path) -> Path:
        plaintext = self.decrypt(ciphertext, key, iv)
        path = Path(output_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plaintext)
        return path

    @staticmethod
    def _validate_key_iv(key: bytes, iv: bytes) -> None:
        if len(key) != 32:
            raise ValueError("Key must be 32 bytes for AES-256-CBC.")
        if len(iv) != 16:
            raise ValueError("IV must be 16 bytes for AES-CBC.")
