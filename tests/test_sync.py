import os

from zerotracefs.filesystem import VirtualFileSystem
from zerotracefs.sync import SyncEngine


def test_sync_lifecycle(tmp_path):
    mount = tmp_path / "mount"
    mount.mkdir()
    vfs = VirtualFileSystem()
    sync_engine = SyncEngine(mount, vfs, master_password="master123")

    target = mount / "new_file.txt"
    target.write_text("hello zero trace", encoding="utf-8")

    changes = sync_engine.sync_all()
    assert "new_file.txt" in changes["new"]
    assert vfs.file_exists("new_file.txt")

    old_cipher = vfs.files["new_file.txt"].ciphertext
    target.write_text("updated payload", encoding="utf-8")
    changes = sync_engine.sync_all()
    assert "new_file.txt" in changes["modified"]
    assert vfs.files["new_file.txt"].ciphertext != old_cipher

    target.unlink()
    changes = sync_engine.sync_all()
    assert "new_file.txt" in changes["deleted"]
    assert not vfs.file_exists("new_file.txt")


def test_sync_preserves_binary_content(tmp_path):
    mount = tmp_path / "mount"
    mount.mkdir()
    vfs = VirtualFileSystem()
    sync_engine = SyncEngine(mount, vfs, master_password="master123")

    fname = "binary_blob.bin"
    payload = os.urandom(4096)
    (mount / fname).write_bytes(payload)

    sync_engine.sync_all()
    recovered = vfs.peek_file(fname, "master123")
    assert recovered == payload
