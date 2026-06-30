from zerotracefs.auth import AuthManager


def test_correct_password_returns_granted():
    auth = AuthManager(max_attempts=5)
    auth.setup("master123", "panic999")
    assert auth.authenticate("master123") == "granted"


def test_wrong_password_denied_and_increments_counter():
    auth = AuthManager(max_attempts=5)
    auth.setup("master123", "panic999")
    assert auth.authenticate("wrong-pass") == "denied"
    assert auth.failed_attempts == 1


def test_duress_password_returns_duress():
    auth = AuthManager(max_attempts=5)
    auth.setup("master123", "panic999")
    assert auth.authenticate("panic999") == "duress"


def test_lockout_after_max_attempts():
    auth = AuthManager(max_attempts=3)
    auth.setup("master123", "panic999")
    assert auth.authenticate("a") == "denied"
    assert auth.authenticate("b") == "denied"
    assert auth.authenticate("c") == "lockout"
    assert auth.is_lockout_triggered()


def test_password_change_works():
    auth = AuthManager(max_attempts=5)
    auth.setup("master123", "panic999")
    assert auth.change_password("master123", "newmaster456") is True
    assert auth.authenticate("newmaster456") == "granted"


def test_counter_resets_after_successful_auth():
    auth = AuthManager(max_attempts=5)
    auth.setup("master123", "panic999")
    auth.authenticate("wrong")
    auth.authenticate("wrong2")
    assert auth.failed_attempts == 2
    assert auth.authenticate("master123") == "granted"
    assert auth.failed_attempts == 0
