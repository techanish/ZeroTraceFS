import os

from zerotracefs.wipe import SecureWiper


def test_file_is_removed_after_wipe(tmp_path):
    wiper = SecureWiper()
    f = tmp_path / "secret.txt"
    f.write_text("Top Secret", encoding="utf-8")
    assert f.exists()
    assert wiper.wipe_file(f)
    assert not f.exists()


def test_file_content_not_recoverable_after_wipe(tmp_path):
    wiper = SecureWiper()
    f = tmp_path / "blob.bin"
    f.write_bytes(os.urandom(2048))
    assert wiper.wipe_file(f)
    assert not f.exists()


def test_directory_wipe_removes_all_files(tmp_path):
    wiper = SecureWiper()
    d = tmp_path / "wipe_dir"
    d.mkdir()
    (d / "a.txt").write_text("a", encoding="utf-8")
    (d / "b.txt").write_text("b", encoding="utf-8")
    (d / "c.txt").write_text("c", encoding="utf-8")

    assert wiper.wipe_directory(d)
    assert list(d.glob("**/*")) == []


def test_zero_byte_file_handling(tmp_path):
    wiper = SecureWiper()
    f = tmp_path / "zero.bin"
    f.write_bytes(b"")
    assert f.exists()
    assert wiper.wipe_file(f)
    assert not f.exists()
