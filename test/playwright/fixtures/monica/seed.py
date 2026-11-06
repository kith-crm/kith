"""Seed a freshly reset Monica 4.1.2. Nothing depends on reminder ids.
Dates for the one-time reminders are relative to the (UTC) day the seed runs."""
import re
import subprocess
from datetime import datetime, timedelta, timezone

from mon import get, post, put

CONTAINER = "kith-monica-e2e-monica-1"
# Monica runs in UTC, so "today" must too (a host-clock date can be off by a day).
TODAY = datetime.now(timezone.utc).date()


def php(*args):
    out = subprocess.run(
        ["docker", "exec", "-u", "www-data", CONTAINER, "php", "/tmp/state.php", *args],
        check=True, capture_output=True, text=True,
    )
    return out.stdout


def contact(first, last, bday=None, deceased=None, bday_reminder=True):
    """bday = (year|None, month, day); deceased = (year, month, day)."""
    body = {
        "first_name": first, "last_name": last,
        "is_birthdate_known": bday is not None,
        "is_deceased": deceased is not None,
        "is_deceased_date_known": deceased is not None,
    }
    if bday:
        y, m, d = bday
        body.update(birthdate_month=m, birthdate_day=d, birthdate_add_reminder=bday_reminder,
                    birthdate_is_age_based=False)
        if y:
            body["birthdate_year"] = y
    if deceased:
        y, m, d = deceased
        body.update(deceased_date_year=y, deceased_date_month=m, deceased_date_day=d,
                    deceased_date_add_reminder=True)
    return post("/contacts", body)["data"]["id"]


def reminder(cid, title, ftype, fnum, date, description=None):
    body = {"contact_id": cid, "title": title, "frequency_type": ftype,
            "frequency_number": fnum, "initial_date": date}
    if description:
        body["description"] = description
    return post("/reminders", body)["data"]["id"]


subprocess.run(["docker", "cp", "state.php", f"{CONTAINER}:/tmp/state.php"], check=True)

mona = contact("Mona", "Vale", (1990, 6, 15))                          # reminder 1
paul = contact("Paul", "Stone", (1992, 2, 29))                         # 2
solo = contact("Solo", "One")
reminder(solo, "Wedding anniversary", "year", 1, "2015-03-09")         # 3
reminder(solo, "Call mum", "week", 2, "2026-01-05")                    # 4
reminder(solo, "Pay rent", "month", 1, "2024-02-01")                   # 5
reminder(solo, "Renew passport", "one_time", 1, "2020-01-01")          # 6
reminder(solo, "Dentist", "one_time", 1, (TODAY + timedelta(days=83)).isoformat())  # 7
yara = contact("Yara", "E2E", (None, 7, 4))                            # 8 (year unknown, M6)
dora = contact("Dora", "E2E", (1950, 4, 20), deceased=(2020, 8, 1))    # 9 birthday, 10 death anniversary
fiona = contact("Fiona", "E2E", (1985, 1, 15))                         # 11
php("first_met", "Fiona", "E2E", "2021-09-01")                         # 12
noel = contact("Noel", "E2E", (1988, 11, 2), bday_reminder=False)      # no reminder
tid = int(re.search(r"TYPE_ID=(\d+)", php("life_event_type", "Promotion")).group(1))
liam = contact("Liam", "E2E")
gina = contact("Gina", "E2E")
reminder(gina, "Water plants", "week", 2, "2026-01-05")                # 13
reminder(gina, "Pay card (31st)", "month", 1, "2025-01-31")            # 14
reminder(gina, "Quarterly review", "month", 3, "2025-11-30")           # 15
reminder(gina, "Leap-day thing", "year", 2, "2016-02-29")              # 16
reminder(gina, "One-time today", "one_time", 1, TODAY.isoformat())          # 17
reminder(gina, "One-time past (never sent)", "one_time", 1, "2025-03-01")  # 18
reminder(gina, "One-time past (sent)", "one_time", 1, (TODAY - timedelta(days=2)).isoformat())    # 19
reminder(gina, "One-time future", "one_time", 1, (TODAY + timedelta(days=120)).isoformat(), "Has a description")  # 20
reminder(gina, "Zero frequency", "month", 0, (TODAY + timedelta(days=120)).isoformat())             # 21
reminder(fiona, "Fiona birthday party", "year", 1, "2026-01-15")       # 22
post("/lifeevents", {"contact_id": liam, "life_event_type_id": tid, "happened_at": "2019-05-10",
                     "has_reminder": True, "name": "Promotion", "note": None, "happened_at_month_unknown": False,
                     "happened_at_day_unknown": False})                # 23

# M3: editing Mona's birthday reminder through the API (delible omitted) makes it delible: true.
r = next(x for x in get(f"/contacts/{mona}/reminders")["data"] if "birthday" in x["title"])
put(f"/reminders/{r['id']}", {"contact_id": mona, "title": r["title"], "frequency_type": r["frequency_type"],
                     "frequency_number": r["frequency_number"], "initial_date": r["initial_date"][:10]})
print("seeded; run: docker exec", CONTAINER, "php /tmp/state.php (as -u www-data)")
