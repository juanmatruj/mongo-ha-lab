"""Validate the provisioned cluster's actual state."""

import stat

import pytest
from pymongo import MongoClient
from pymongo.errors import OperationFailure, ServerSelectionTimeoutError

from tests.config import NODES, SEED_LIST


# --- Topology ---

def test_replica_set_has_one_primary(admin_client):
    status = admin_client.admin.command("replSetGetStatus")
    primaries = [m for m in status["members"] if m["stateStr"] == "PRIMARY"]
    assert len(primaries) == 1, f"Expected 1 primary, found {len(primaries)}"


def test_replica_set_has_two_healthy_secondaries(admin_client):
    status = admin_client.admin.command("replSetGetStatus")
    secondaries = [
        m for m in status["members"]
        if m["stateStr"] == "SECONDARY" and m["health"] == 1
    ]
    assert len(secondaries) == 2, f"Expected 2 secondaries, found {len(secondaries)}"


def test_all_members_are_reachable(admin_client):
    status = admin_client.admin.command("replSetGetStatus")
    unhealthy = [m["name"] for m in status["members"] if m["health"] != 1]
    assert not unhealthy, f"Unreachable members: {unhealthy}"


def test_majority_write_is_acknowledged(admin_client):
    collection = admin_client.get_database(
        "labdb", write_concern=admin_client.write_concern
    ).ci_checks
    result = collection.insert_one(
        {"check": "majority write"},
    )
    assert result.acknowledged


# --- Authentication is mandatory ---

def test_unauthenticated_connection_is_rejected(ca_file):
    client = MongoClient(
        f"mongodb://{SEED_LIST}/?replicaSet=rs0",
        tls=True,
        tlsCAFile=ca_file,
        serverSelectionTimeoutMS=5000,
    )
    with pytest.raises(OperationFailure) as exc:
        client.labdb.lab.find_one()
    assert exc.value.code == 13, f"Expected Unauthorized (13), got {exc.value.code}"
    client.close()


def test_connection_without_tls_is_rejected(ca_file):
    client = MongoClient(
        f"mongodb://{NODES[0][0]}:{NODES[0][1]}/",
        directConnection=True,
        serverSelectionTimeoutMS=5000,
    )
    with pytest.raises(ServerSelectionTimeoutError):
        client.admin.command("ping")
    client.close()


# --- Users and least privilege ---

EXPECTED_USERS = {"admin", "monitoring", "backup_user", "app_user"}


def test_all_expected_users_exist(admin_client):
    users = admin_client.admin.command("usersInfo")["users"]
    found = {u["user"] for u in users}
    assert found == EXPECTED_USERS, f"Unexpected user set: {found}"


def test_app_user_can_write_to_its_own_database(app_client):
    result = app_client.labdb.ci_checks.insert_one({"check": "app write"})
    assert result.acknowledged


def test_app_user_cannot_read_system_users(app_client):
    with pytest.raises(OperationFailure) as exc:
        app_client.admin.system.users.find_one()
    assert exc.value.code == 13, f"Expected Unauthorized (13), got {exc.value.code}"

def test_app_user_cannot_write_outside_its_database(app_client):
    with pytest.raises(OperationFailure) as exc:
        app_client.other_db.data.insert_one({"x": 1})
    assert exc.value.code == 13, f"Expected Unauthorized (13), got {exc.value.code}"


def test_app_user_cannot_escalate_privileges(app_client):
    with pytest.raises(OperationFailure) as exc:
        app_client.admin.command(
            "createUser", "intruder", pwd="whatever",
            roles=[{"role": "root", "db": "admin"}],
        )
    assert exc.value.code == 13, f"Expected Unauthorized (13), got {exc.value.code}"


# --- Security configuration ---

def test_keyfile_permissions(keyfile_path):
    assert keyfile_path.exists(), f"Keyfile not found at {keyfile_path}"
    mode = stat.S_IMODE(keyfile_path.stat().st_mode)
    assert mode == 0o400, f"Expected mode 0400, found {oct(mode)}"


def test_keyfile_is_owned_by_container_user(keyfile_path):
    assert keyfile_path.stat().st_uid == 999, (
        "Keyfile must be owned by UID 999; MongoDB refuses to start otherwise"
    )
