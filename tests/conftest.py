"""Shared fixtures for the mongo-ha-lab test suite."""

import os
import pathlib

import pytest
from pymongo import MongoClient

from tests.config import CA_FILE, KEYFILE, SEED_LIST

def _password(name):
    """Read a password from the environment, failing loudly if absent."""
    value = os.environ.get(name)
    if not value:
        pytest.fail(
            f"{name} is not set. Export the credentials before running the "
            f"suite, or pass them from the CI secret store."
        )
    return value


@pytest.fixture(scope="session")
def ca_file():
    if not pathlib.Path(CA_FILE).exists():
        pytest.fail(f"CA certificate not found at {CA_FILE}. Run the playbook first.")
    return CA_FILE


@pytest.fixture(scope="session")
def admin_client(ca_file):
    """Authenticated client with cluster-wide privileges."""
    client = MongoClient(
        f"mongodb://{SEED_LIST}/?replicaSet=rs0&authSource=admin",
        username="admin",
        password=_password("MONGO_ADMIN_PASS"),
        tls=True,
        tlsCAFile=ca_file,
        serverSelectionTimeoutMS=10000,
    )
    yield client
    client.close()


@pytest.fixture(scope="session")
def app_client(ca_file):
    """Least-privilege client, scoped to a single database."""
    client = MongoClient(
        f"mongodb://{SEED_LIST}/?replicaSet=rs0&authSource=admin",
        username="app_user",
        password=_password("MONGO_APP_PASS"),
        tls=True,
        tlsCAFile=ca_file,
        serverSelectionTimeoutMS=10000,
    )
    yield client
    client.close()


@pytest.fixture(scope="session")
def keyfile_path():
    return KEYFILE
