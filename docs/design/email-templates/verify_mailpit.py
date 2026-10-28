"""Verify captured preview messages. Uses only Python's standard library.

Run after mix kith.email.preview --output /tmp/kith-email-previews --mailpit:
  python3 docs/design/email-templates/verify_mailpit.py /tmp/kith-email-previews

Exports the exact delivered MIME, a browser preview with Mailpit CID URLs, and a
JSON report. This verifies local delivery; it does not emulate email clients.
"""

import argparse
import base64
import email
import email.policy
import hashlib
import json
import re
import urllib.request
from pathlib import Path

VARIANTS = [
    "confirmation", "password-reset", "email-change", "invitation",
    "birthday-today", "birthday-upcoming", "first-met", "stay-in-touch",
    "reminder-upcoming", "reminder-due", "welcome", "export",
]


def fetch(url):
    with urllib.request.urlopen(url, timeout=15) as response:
        return response.read()


def normalized(text):
    return text.replace("\r\n", "\n").strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("preview_directory", type=Path)
    parser.add_argument("--mailpit", default="http://localhost:8025")
    parser.add_argument("--output", type=Path, default=Path("/tmp/kith-mailpit-verification"))
    args = parser.parse_args()
    api = args.mailpit.rstrip("/")
    args.output.mkdir(parents=True, exist_ok=True)
    inbox = json.loads(fetch(api + "/api/v1/messages?limit=500"))["messages"]
    candidates = [m for m in inbox if any(t["Address"] == "preview@example.test" for t in m["To"])]
    messages = [json.loads(fetch(api + "/api/v1/message/" + m["ID"])) for m in candidates]
    results = []

    for variant in VARIANTS:
        expected_text = normalized((args.preview_directory / (variant + ".txt")).read_text())
        expected_html = normalized((args.preview_directory / (variant + ".html")).read_text())
        match = next((m for m in messages if normalized(m["Text"]) == expected_text), None)
        assert match is not None, f"No delivered text matches {variant}; regenerate previews and send to Mailpit"
        raw = fetch(api + "/api/v1/message/" + match["ID"] + "/raw")
        mime = email.message_from_bytes(raw, policy=email.policy.default)
        html_part, text_part = mime.get_body(("html",)), mime.get_body(("plain",))
        assert html_part and text_part, f"Missing HTML/plain-text alternative: {variant}"
        assert normalized(text_part.get_content()) == expected_text, variant
        logos = [p for p in mime.walk() if p.get("Content-ID", "").strip("<>") == "kith-logo.png"]
        assert len(logos) == 1, f"Missing or ambiguous CID logo: {variant}"
        logo = logos[0]
        png = logo.get_payload(decode=True)
        assert png.startswith(b"\x89PNG\r\n\x1a\n"), variant
        assert logo.get_content_type() == "image/png" and logo.get_content_disposition() == "inline", variant
        html = normalized(html_part.get_content())
        embedded = "data:image/png;base64," + base64.b64encode(png).decode()
        assert html.replace("cid:kith-logo.png", embedded) == expected_html, f"Delivered HTML mismatch: {variant}"
        assert 'alt="Kith logo"' in html and ">Kith</td>" in html, variant
        links = re.findall(r'href="([^"]+)"', html)
        assert links and all(link.startswith(("http://", "https://")) for link in links), variant
        assert "#d25900" in html and "data:image" not in html, variant
        inline = next(p for p in match["Inline"] if p["ContentID"] == "kith-logo.png")
        image_url = api + "/api/v1/message/" + match["ID"] + "/part/" + inline["PartID"]
        assert fetch(image_url) == png, f"Mailpit cannot resolve the logo: {variant}"
        (args.output / (variant + ".eml")).write_bytes(raw)
        (args.output / (variant + ".html")).write_text(html.replace("cid:kith-logo.png", image_url))
        results.append({
            "variant": variant, "subject": match["Subject"], "message_id": match["ID"],
            "mailpit_view": api + "/view/" + match["ID"],
            "mime_sha256": hashlib.sha256(raw).hexdigest(), "html_bytes": len(html.encode()),
            "html_and_text_match_builders": True, "inline_png_resolves": True,
            "absolute_action_links": True, "kith_text_survives_image_blocking": True,
        })

    report = {"scope": "Local SMTP/MIME verification in Mailpit, not Gmail/Outlook/Apple Mail certification",
              "messages_checked": len(results), "results": results}
    (args.output / "mime-results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Passed: {len(results)} delivered HTML/text/CID/link checks. Evidence: {args.output}")


if __name__ == "__main__":
    main()
