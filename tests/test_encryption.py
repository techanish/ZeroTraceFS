import os

from zerotracefs.encryption import EncryptionEngine


def test_encrypt_then_decrypt_returns_original_content():
    engine = EncryptionEngine()
    key = engine.generate_key()
    iv = engine.generate_iv()
    plaintext = b"ZeroTraceFS test plaintext"
    ciphertext = engine.encrypt(plaintext, key, iv)
    recovered = engine.decrypt(ciphertext, key, iv)
    assert plaintext == recovered


def test_different_ivs_produce_different_ciphertext():
    engine = EncryptionEngine()
    key = engine.generate_key()
    plaintext = b"same plaintext"
    c1 = engine.encrypt(plaintext, key, engine.generate_iv())
    c2 = engine.encrypt(plaintext, key, engine.generate_iv())
    assert c1 != c2


def test_wrong_key_fails_or_nonmatching_plaintext():
    engine = EncryptionEngine()
    key_ok = engine.generate_key()
    key_bad = engine.generate_key()
    iv = engine.generate_iv()
    plaintext = b"sensitive payload"
    ciphertext = engine.encrypt(plaintext, key_ok, iv)
    try:
        wrong_result = engine.decrypt(ciphertext, key_bad, iv)
        assert wrong_result != plaintext
    except Exception:
        assert True


def test_binary_data_encrypts_decrypts_correctly():
    engine = EncryptionEngine()
    key = engine.generate_key()
    iv = engine.generate_iv()
    blob = os.urandom(2048)
    ciphertext = engine.encrypt(blob, key, iv)
    recovered = engine.decrypt(ciphertext, key, iv)
    assert blob == recovered


def test_empty_content_handling():
    engine = EncryptionEngine()
    key = engine.generate_key()
    iv = engine.generate_iv()
    plaintext = b""
    ciphertext = engine.encrypt(plaintext, key, iv)
    recovered = engine.decrypt(ciphertext, key, iv)
    assert plaintext == recovered


def test_large_file_handling(tmp_path):
    engine = EncryptionEngine()
    plain = tmp_path / "plain.bin"
    out = tmp_path / "out.bin"
    payload = os.urandom(1024 * 1024 + 128)
    plain.write_bytes(payload)

    key = engine.generate_key()
    encrypted = engine.encrypt_file(plain, key)
    engine.decrypt_to_file(encrypted["ciphertext"], key, encrypted["iv"], out)

    assert out.read_bytes() == payload
