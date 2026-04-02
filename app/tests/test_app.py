import pytest
import sys
import os

# Point to app/ folder so "from models import" and "from app import" work
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

@pytest.fixture
def app():
    from app import create_app
    application = create_app(test_db_url="sqlite:///:memory:")
    application.config["TESTING"] = True

    from models import db
    with application.app_context():
        db.drop_all()
        db.create_all()
        yield application

@pytest.fixture
def client(app):
    return app.test_client()

def test_liveness(client):
    res = client.get("/health/live")
    assert res.status_code == 200
    assert res.get_json()["status"] == "alive"

def test_create_book(client):
    res = client.post("/books", json={"title": "Clean Code", "author": "Robert Martin"})
    assert res.status_code == 201
    assert res.get_json()["title"]  == "Clean Code"
    assert res.get_json()["author"] == "Robert Martin"

def test_get_books(client):
    client.post("/books", json={"title": "Book1", "author": "Author1"})
    res = client.get("/books")
    assert res.status_code == 200
    assert len(res.get_json()) >= 1

def test_update_book(client):
    create  = client.post("/books", json={"title": "Old Title", "author": "Author"})
    book_id = create.get_json()["id"]
    res     = client.put(f"/books/{book_id}", json={"title": "New Title"})
    assert res.status_code == 200
    assert res.get_json()["title"] == "New Title"

def test_delete_book(client):
    create  = client.post("/books", json={"title": "To Delete", "author": "Author"})
    book_id = create.get_json()["id"]
    res     = client.delete(f"/books/{book_id}")
    assert res.status_code == 200

def test_create_book_missing_fields(client):
    res = client.post("/books", json={"title": "No Author"})
    assert res.status_code == 400
