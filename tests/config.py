"""Shared constants for the test suite."""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CA_FILE = str(REPO_ROOT / "certs" / "ca.crt")
KEYFILE = REPO_ROOT / "secrets" / "keyfile"

NODES = [
    ("mongo1", 27017),
    ("mongo2", 27018),
    ("mongo3", 27019),
]

SEED_LIST = ",".join(f"{host}:{port}" for host, port in NODES)
