"""Shared fixtures: the real Flask app wired to the in-memory fake database.

Tests that use `fake`, `fake_app` or `fake_client` need no MariaDB server.
"""
import os

import pymysql
import pytest

os.environ.setdefault("SECRET_KEY", "test-only-secret-key")

import app as webapp  # noqa: E402
from fakedb import FakeDatabase  # noqa: E402

FAKE_DB_PASSWORD = "fake-app-password-123"


@pytest.fixture()
def fake(monkeypatch):
    db = FakeDatabase()
    seen = []

    def connect(**kwargs):
        seen.append(kwargs)
        return db.connect(**kwargs)

    monkeypatch.setattr(pymysql, "connect", connect)
    db.connect_calls = seen
    return db


@pytest.fixture()
def fake_app(fake):
    return webapp.create_app({"TESTING": True, "SECRET_KEY": "test-only-secret-key",
                              "DB_USER": "campus_app", "DB_PASSWORD": FAKE_DB_PASSWORD,
                              "DB_HOST": "fake-host", "DB_PORT": 3306})


@pytest.fixture()
def fake_client(fake_app):
    return fake_app.test_client()
