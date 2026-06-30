import sys

import pytest


if __name__ == "__main__":
    rc = pytest.main(["-q", "tests"])
    sys.exit(rc)
