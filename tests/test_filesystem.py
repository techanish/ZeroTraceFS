from datetime import timedelta

from zerotracefs.filesystem import VirtualFileSystem
from zerotracefs.utils import utcnow


def test_add_file_and_retrieve_it():
    vfs = VirtualFileSystem()
    payload = b"classified"
    vfs.add_file("doc.txt", payload, "master123")
    recovered = vfs.peek_file("doc.txt", "master123")
    assert payload == recovered


def test_file_metadata_correctly_tracked():
    vfs = VirtualFileSystem()
    payload = b"metadata payload"
    vfs.add_file("meta.txt", payload, "master123")
    meta = vfs.get_metadata("meta.txt")
    assert meta["filename"] == "meta.txt"
    assert meta["file_size"] == len(payload)
    assert meta["created_at"] is not None
    assert meta["modified_at"] is not None


def test_read_count_increments():
    vfs = VirtualFileSystem()
    vfs.add_file("readme.txt", b"123", "master123")
    vfs.read_file("readme.txt", "master123")
    vfs.read_file("readme.txt", "master123")
    meta = vfs.get_metadata("readme.txt")
    assert meta["read_count"] == 2
    assert meta["last_read_at"] is not None
    assert meta["last_access_at"] is not None


def test_setting_ttl_resets_access_anchor():
    vfs = VirtualFileSystem()
    vfs.add_file("ttl.txt", b"123", "master123")
    vfs.files["ttl.txt"].metadata["created_at"] = utcnow() - timedelta(hours=1)
    vfs.set_trigger("ttl.txt", "ttl_seconds", 60)
    meta = vfs.get_metadata("ttl.txt")
    assert meta["ttl_set_at"] is not None
    assert (utcnow() - meta["last_access_at"]).total_seconds() < 5


def test_remove_file_works():
    vfs = VirtualFileSystem()
    vfs.add_file("gone.txt", b"gone", "master123")
    assert vfs.file_exists("gone.txt")
    vfs.remove_file("gone.txt")
    assert not vfs.file_exists("gone.txt")


def test_list_files_returns_correct_data():
    vfs = VirtualFileSystem()
    vfs.add_file("a.txt", b"a", "master123")
    vfs.add_file("b.txt", b"b", "master123")
    rows = vfs.list_files()
    names = {r["filename"] for r in rows}
    assert len(rows) == 2
    assert {"a.txt", "b.txt"}.issubset(names)
