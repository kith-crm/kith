#!/usr/bin/env python3
"""Deterministic Monica HTTP fixture. No database or external Monica needed."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

NOTES = [{"id": n, "uuid": f"pr44-note-{n}", "body": f"PR44 note {n:02d}",
          "created_at": f"2020-01-{n:02d}T10:00:00Z", "updated_at": f"2020-01-{n:02d}T10:00:00Z"}
         for n in range(1, 11)]
CONTACT = {
    "id": 1, "uuid": "pr44-contact-1", "object": "contact", "first_name": "Mona",
    "last_name": "Fixture", "is_active": True, "is_dead": False, "is_partial": False,
    "information": {"dates": {}, "career": {}, "avatar": {"source": "default"},
                    "relationships": {}, "how_you_met": {}},
    "addresses": [], "tags": [], "contactFields": [], "notes": NOTES[-3:],
    "statistics": {"number_of_notes": 10, "number_of_calls": 0, "number_of_activities": 0,
                   "number_of_gifts": 0, "number_of_debts": 0, "number_of_tasks": 0,
                   "number_of_reminders": 0, "number_of_conversations": 1},
}
CONVERSATION = {"id": 100, "subject": "Fixture exchange", "contact_field_type": {"name": "SMS"},
                "messages": [{"id": 101, "content": "OK", "written_by_me": True,
                              "written_at": "2020-01-01T10:30:15Z"},
                             {"id": 102, "content": "OK", "written_by_me": False,
                              "written_at": "2020-01-01T10:30:15Z"}]}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if self.headers.get("Authorization") != "Bearer pr44-fixture-token":
            self.send_error(401)
            return
        if path == "/api/me":
            body = {"data": {"id": 1}}
        elif path == "/api/contacts":
            page = int(parse_qs(parsed.query).get("page", ["1"])[0])
            body = {"data": [CONTACT] if page == 1 else [], "meta": {"current_page": page, "last_page": 1, "total": 1}}
        elif path == "/api/contacts/1":
            body = {"data": CONTACT}
        elif path == "/api/contacts/1/notes":
            body = {"data": NOTES, "meta": {"last_page": 1, "total": 10}}
        elif path == "/api/contacts/1/conversations":
            body = {"data": [CONVERSATION]}
        elif path == "/api/contacts/1/pets":
            body = {"data": []}
        else:
            self.send_error(404, path)
            return
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8094)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
