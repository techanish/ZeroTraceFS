from datetime import timedelta

from zerotracefs.filesystem import VirtualFileSystem
from zerotracefs.triggers import TriggerEngine
from zerotracefs.utils import utcnow


def make_meta():
    now = utcnow()
    return {
        "filename": "x.txt",
        "created_at": now,
        "modified_at": now,
        "last_access_at": now,
        "last_read_at": None,
        "read_count": 0,
        "file_size": 10,
        "file_hash": "abc",
        "ttl_seconds": None,
        "ttl_set_at": None,
        "max_reads": None,
        "deadline": None,
        "is_destroyed": False,
    }


def test_file_ttl_triggers_after_expiration():
    t = TriggerEngine()
    meta = make_meta()
    meta["ttl_seconds"] = 60
    meta["last_access_at"] = utcnow() - timedelta(seconds=61)
    res = t.check_file_triggers(meta)
    assert res["triggered"]
    assert "TTL" in res["reason"]


def test_read_limit_triggers():
    t = TriggerEngine()
    meta = make_meta()
    meta["max_reads"] = 3
    meta["read_count"] = 4
    res = t.check_file_triggers(meta)
    assert res["triggered"]
    assert "Read limit" in res["reason"]


def test_ttl_uses_recent_access_not_old_creation():
    t = TriggerEngine()
    meta = make_meta()
    meta["created_at"] = utcnow() - timedelta(hours=1)
    meta["last_access_at"] = utcnow() - timedelta(seconds=5)
    meta["ttl_seconds"] = 60
    res = t.check_file_triggers(meta)
    assert not res["triggered"]


def test_deadline_in_past_triggers():
    t = TriggerEngine()
    meta = make_meta()
    meta["deadline"] = utcnow() - timedelta(seconds=1)
    res = t.check_file_triggers(meta)
    assert res["triggered"]


def test_global_ttl_triggers_correctly():
    t = TriggerEngine(global_ttl_seconds=10)
    t.system_start_time = utcnow() - timedelta(seconds=20)
    res = t.check_global_triggers()
    assert res["triggered"]


def test_dead_man_switch_triggers_when_stale():
    t = TriggerEngine(dead_man_switch_interval=30)
    t.last_heartbeat = utcnow() - timedelta(seconds=35)
    res = t.check_global_triggers()
    assert res["triggered"]


def test_check_all_returns_file_trigger_list():
    vfs = VirtualFileSystem()
    vfs.add_file("demo.txt", b"hello", "pw")
    vfs.set_trigger("demo.txt", "ttl_seconds", 1)
    vfs.files["demo.txt"].metadata["last_access_at"] = utcnow() - timedelta(seconds=2)

    t = TriggerEngine()
    all_res = t.check_all(vfs)
    assert len(all_res["files"]) == 1
    assert all_res["files"][0]["filename"] == "demo.txt"
