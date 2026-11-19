"""School payment API. Bind to loopback and deploy behind HTTPS."""
from contextlib import closing
from datetime import datetime, timezone
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import sqlite3

DATABASE = os.getenv("SCHOOL_DB", "school.sqlite3")
API_KEY = os.getenv("SCHOOL_API_KEY", "")
FEE_TYPES = ("minerval", "tuition", "state")


def connect():
    db = sqlite3.connect(DATABASE)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    return db


def initialize():
    with closing(connect()) as db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS students (
                id INTEGER PRIMARY KEY, name TEXT NOT NULL, phone TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS payments (
                id INTEGER PRIMARY KEY, request_id TEXT UNIQUE NOT NULL,
                student_id INTEGER NOT NULL REFERENCES students(id),
                amount INTEGER NOT NULL, created_at TEXT NOT NULL,
                sms TEXT NOT NULL, fee_type TEXT
            );
        """)
        with db:
            db.execute("BEGIN IMMEDIATE")
            columns = {row["name"] for row in db.execute("PRAGMA table_info(payments)")}
            if "fee_type" not in columns:
                db.execute("ALTER TABLE payments ADD COLUMN fee_type TEXT")


def add_payment(db, data):
    student_id, amount, request_id = (data.get(key) for key in
                                      ("student_id", "amount", "request_id"))
    fee_type = data.get("fee_type")
    if (type(student_id) is not int or type(amount) is not int
            or not 0 < amount <= 10**12 or not isinstance(request_id, str)
            or not re.fullmatch(r"[0-9a-f]{32}", request_id)):
        raise ValueError("Paiement invalide.")
    with db:
        db.execute("BEGIN IMMEDIATE")
        existing = db.execute("SELECT * FROM payments WHERE request_id = ?",
                              (request_id,)).fetchone()
        if existing:
            if (existing["student_id"], existing["amount"], existing["fee_type"]) != (
                student_id, amount, fee_type,
            ):
                raise ValueError("Cette référence correspond à un autre paiement.")
            return dict(existing)
        if fee_type not in FEE_TYPES:
            raise ValueError("Choisissez un type de frais.")
        student = db.execute("SELECT name, phone FROM students WHERE id = ?",
                             (student_id,)).fetchone()
        if student is None:
            raise ValueError("Élève introuvable.")
        receipt = db.execute(
            "INSERT INTO payments(request_id, student_id, amount, created_at, sms, fee_type)"
            " VALUES (?, ?, ?, ?, 'pending', ?)",
            (request_id, student_id, amount, datetime.now(timezone.utc).isoformat(), fee_type),
        ).lastrowid
    payment = dict(db.execute("SELECT * FROM payments WHERE id = ?", (receipt,)).fetchone())
    return dict(payment, phone=student["phone"], name=student["name"])


def update_sms(db, data):
    request_id, status = data.get("request_id"), data.get("status")
    if not isinstance(request_id, str) or status not in (
        "airtel_submitted", "airtel_no_sim", "airtel_permission", "airtel_failed",
    ):
        raise ValueError("Statut SMS invalide.")
    with db:
        db.execute("UPDATE payments SET sms = ? WHERE request_id = ? AND sms = 'pending'",
                   (status, request_id))
    payment = db.execute("SELECT * FROM payments WHERE request_id = ?", (request_id,)).fetchone()
    if payment is None:
        raise ValueError("Reçu introuvable.")
    return dict(payment)


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        value = self.headers.get("Authorization", "").encode()
        if hmac.compare_digest(value, ("Bearer " + API_KEY).encode()):
            return True
        self.reply(401, {"error": "Clé d'accès invalide."})
        return False

    def do_GET(self):
        if not self.authorized():
            return
        queries = {
            "/students": "SELECT * FROM students ORDER BY name, id",
            "/payments": "SELECT p.*, s.name FROM payments p JOIN students s "
                         "ON s.id = p.student_id ORDER BY p.id DESC",
        }
        if self.path not in queries:
            self.reply(404, {"error": "Page introuvable."})
            return
        with closing(connect()) as db:
            self.reply(200, {"items": [dict(row) for row in db.execute(queries[self.path])]})

    def do_POST(self):
        if not self.authorized():
            return
        if self.path not in ("/students", "/payments", "/payments/sms"):
            self.reply(404, {"error": "Page introuvable."})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 4096:
                raise ValueError("Données invalides.")
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict):
                raise ValueError("Données invalides.")
            with closing(connect()) as db:
                if self.path == "/payments":
                    result = add_payment(db, data)
                elif self.path == "/payments/sms":
                    result = update_sms(db, data)
                else:
                    name, phone = data.get("name"), data.get("phone")
                    if not isinstance(name, str) or not 0 < len(name.strip()) <= 120:
                        raise ValueError("Saisissez le nom de l’élève.")
                    if not isinstance(phone, str) or not re.fullmatch(r"\+243[0-9]{9}", phone):
                        raise ValueError("Saisissez un numéro RDC au format +243 suivi de 9 chiffres.")
                    with db:
                        student_id = db.execute("INSERT INTO students(name, phone) VALUES (?, ?)",
                                                (name.strip(), phone)).lastrowid
                    result = {"id": student_id}
        except (json.JSONDecodeError, UnicodeError):
            self.reply(400, {"error": "Données invalides."})
        except ValueError as error:
            self.reply(400, {"error": str(error)})
        else:
            self.reply(200, result)


if __name__ == "__main__":
    if not API_KEY:
        raise SystemExit("Définissez SCHOOL_API_KEY avant de démarrer.")
    initialize()
    ThreadingHTTPServer(("127.0.0.1", int(os.getenv("SCHOOL_PORT", "8080"))),
                        Handler).serve_forever()

