import os
import json
import logging
import boto3
from flask import Flask, request, jsonify
from pythonjsonlogger import jsonlogger
from models import db, Book

logger = logging.getLogger()
handler = logging.StreamHandler()
formatter = jsonlogger.JsonFormatter(fmt="%(asctime)s %(levelname)s %(name)s %(message)s")
handler.setFormatter(formatter)
logger.addHandler(handler)
logger.setLevel(logging.INFO)

def get_db_credentials():
    secret_name = os.environ.get("SECRET_NAME", "flask-eks/db-credentials")
    region      = os.environ.get("AWS_REGION", "us-east-1")
    client      = boto3.client("secretsmanager", region_name=region)
    secret      = client.get_secret_value(SecretId=secret_name)
    return json.loads(secret["SecretString"])

def create_app(test_db_url=None):
    app = Flask(__name__)

    if test_db_url:
        db_url = test_db_url
    else:
        creds  = get_db_credentials()
        db_url = (
            f"postgresql://{creds['username']}:{creds['password']}"
            f"@{creds['host']}:{creds['port']}/{creds['dbname']}"
        )

    app.config["SQLALCHEMY_DATABASE_URI"]        = db_url
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

    if not test_db_url:
        app.config["SQLALCHEMY_ENGINE_OPTIONS"] = {
            "pool_pre_ping": True,
            "pool_recycle":  300,
            "pool_size":     5,
            "max_overflow":  10,
        }

    db.init_app(app)

    with app.app_context():
        db.create_all()

    @app.route("/health/live")
    def liveness():
        return jsonify({"status": "alive"}), 200

    @app.route("/health/ready")
    def readiness():
        try:
            db.session.execute(db.text("SELECT 1"))
            return jsonify({"status": "ready", "db": "connected"}), 200
        except Exception as e:
            return jsonify({"status": "not ready", "db": "disconnected"}), 503

    @app.route("/books", methods=["GET"])
    def get_books():
        books = Book.query.all()
        return jsonify([b.to_dict() for b in books]), 200

    @app.route("/books/<int:book_id>", methods=["GET"])
    def get_book(book_id):
        book = Book.query.get_or_404(book_id)
        return jsonify(book.to_dict()), 200

    @app.route("/books", methods=["POST"])
    def create_book():
        data = request.get_json()
        if not data or not data.get("title") or not data.get("author"):
            return jsonify({"error": "title and author are required"}), 400
        book = Book(
            title       = data["title"],
            author      = data["author"],
            description = data.get("description", ""),
        )
        db.session.add(book)
        db.session.commit()
        return jsonify(book.to_dict()), 201

    @app.route("/books/<int:book_id>", methods=["PUT"])
    def update_book(book_id):
        book = Book.query.get_or_404(book_id)
        data = request.get_json()
        if data.get("title"):       book.title       = data["title"]
        if data.get("author"):      book.author      = data["author"]
        if data.get("description"): book.description = data["description"]
        db.session.commit()
        return jsonify(book.to_dict()), 200

    @app.route("/books/<int:book_id>", methods=["DELETE"])
    def delete_book(book_id):
        book = Book.query.get_or_404(book_id)
        db.session.delete(book)
        db.session.commit()
        return jsonify({"message": f"Book {book_id} deleted"}), 200

    return app

if __name__ == "__main__":
    application = create_app()
    application.run(host="0.0.0.0", port=5000, debug=False)
