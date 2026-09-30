#!/usr/bin/env python3
"""Create a test account on a local Skippy server and fill it with sample data.

Credentials live in `.env.local-test` at the repository root (gitignored by
`.env*`). The first run writes that file with a generated password; later runs
reuse it. Seeding happens once: an account that already has notes is left
alone.

    python3 scripts/seed-local.py

What it creates, in the account's default workspace:

    General (grid)   pinned welcome note, markdown, checklists with subtasks,
                     reminders, a note link, one archived and one trashed note
    Projects (board) To do / Doing / Done columns with cards, one unassigned
    Labels           Work, Personal, Ideas
"""

import json
import secrets
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, time, timedelta, timezone
from pathlib import Path

ENV_FILE = Path(__file__).resolve().parent.parent / ".env.local-test"
DEFAULTS = {
    "SKIPPY_URL": "http://localhost:8790",
    "SKIPPY_TEST_NAME": "Test User",
    "SKIPPY_TEST_EMAIL": "test@skippy.local",
}
HTTP_CONFLICT = 409


def load_env():
    env = dict(DEFAULTS)
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and not key.startswith("#"):
                env[key.strip()] = value.strip()

    if "SKIPPY_TEST_PASSWORD" not in env:
        env["SKIPPY_TEST_PASSWORD"] = secrets.token_urlsafe(12)
        ENV_FILE.write_text(
            "# Local Skippy test account, written by scripts/seed-local.py.\n"
            + "".join(f"{k}={v}\n" for k, v in env.items())
        )
    return env


class Client:
    def __init__(self, base):
        self.base = base.rstrip("/") + "/api"
        self.token = None

    def call(self, method, path, body=None):
        request = urllib.request.Request(
            self.base + path,
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
        )
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(request) as response:
            raw = response.read()
        return json.loads(raw) if raw else None


def sign_in(client, env):
    account = {
        "name": env["SKIPPY_TEST_NAME"],
        "email": env["SKIPPY_TEST_EMAIL"],
        "password": env["SKIPPY_TEST_PASSWORD"],
    }
    try:
        auth = client.call("POST", "/auth/register", account)
    except urllib.error.HTTPError as error:
        if error.code != HTTP_CONFLICT:
            raise
        auth = client.call("POST", "/auth/login", account)
    client.token = auth["token"]


def at_local(days, hour):
    """An ISO UTC timestamp `days` from today at `hour` local time."""
    day = datetime.now().astimezone().date() + timedelta(days=days)
    local = datetime.combine(day, time(hour)).astimezone()
    return local.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def items(*rows):
    """Checklist rows from (text, done, depth) tuples."""
    return [
        {"id": str(uuid.uuid4()), "text": text, "done": done, "depth": depth}
        for text, done, depth in rows
    ]


def seed(client):
    workspace = next(w for w in client.call("GET", "/workspaces") if w["is_default"])
    ws = workspace["id"]
    client.call("PATCH", f"/workspaces/{ws}", {"board_enabled": True})

    labels = {}
    for name, color, icon in [
        ("Work", "#1A73E8", "work"),
        ("Personal", "#188038", "home"),
        ("Ideas", "#FF7043", "star"),
    ]:
        label = client.call(
            "POST",
            "/labels",
            {"workspace_id": ws, "name": name, "color": color, "icon": icon},
        )
        labels[name] = label["id"]

    def note(**fields):
        fields.setdefault("id", str(uuid.uuid4()))
        fields.setdefault("workspace_id", ws)
        return client.call("POST", "/notes", fields)

    welcome = note(
        title="Welcome to Skippy",
        content=(
            "This account was filled by scripts/seed-local.py.\n\n"
            "Try pinning, archiving, dragging cards around, or switching to "
            "the Projects board from the sidebar."
        ),
        color="yellow",
        pinned=True,
    )
    note(
        kind="markdown",
        title="Weekly sync",
        content=(
            "## Agenda\n\n"
            "- Roadmap review\n"
            "- **Hiring** update\n"
            "- Open questions\n\n"
            "## Decisions\n\n"
            "1. Ship the board view this sprint\n"
            "2. Move retro to Fridays\n\n"
            "> Notes are shared with the whole team."
        ),
        label_ids=[labels["Work"]],
    )
    note(
        kind="checklist",
        title="Groceries",
        items=items(
            ("Milk", False, 0),
            ("Eggs", False, 0),
            ("Bread", True, 0),
            ("Coffee beans", False, 0),
            ("Apples", True, 0),
        ),
        color="green",
        label_ids=[labels["Personal"]],
    )
    plan = items(
        ("Write release notes", False, 0),
        ("Draft changelog", True, 1),
        ("Collect screenshots", False, 1),
        ("Dark mode", False, 2),
        ("Tag the release", False, 0),
        ("Announce", False, 0),
    )
    note(
        kind="checklist",
        title="Launch plan",
        items=plan,
        label_ids=[labels["Work"]],
        item_reminders=[{"item_id": plan[4]["id"], "reminder_at": at_local(2, 10)}],
    )
    note(
        title="Call the dentist",
        content="Ask about moving the appointment to next week.",
        reminder_at=at_local(1, 9),
        color="blue",
        label_ids=[labels["Personal"]],
    )
    note(
        title="Reading list",
        content=(
            "Start with [[" + welcome["id"] + "|Welcome to Skippy]], then:\n"
            "- The Pragmatic Programmer\n"
            "- A Philosophy of Software Design\n"
            "- Designing Data-Intensive Applications"
        ),
        label_ids=[labels["Ideas"]],
    )
    note(
        title="App ideas",
        content=(
            "A plant watering tracker with reminders per plant.\n\n"
            "A shared packing list for trips that learns what you forget.\n\n"
            "A tiny budget view that only shows this week."
        ),
        color="orange",
        label_ids=[labels["Ideas"]],
    )
    note(title="Old ideas", content="Kept for the archive view.", archived=True)
    note(title="Scratch", content="Kept for the trash view.", trashed=True)

    # A board collection with three columns.
    projects = str(uuid.uuid4())
    client.call(
        "PUT",
        f"/workspaces/{ws}/collections/{projects}",
        {
            "id": projects,
            "workspace_id": ws,
            "name": "Projects",
            "icon": "work",
            "color": None,
            "layout": "board",
            "sort": "custom",
            "position": 4096,
        },
    )
    stages = {}
    for position, (name, color) in enumerate(
        [("To do", "#9E9E9E"), ("Doing", "#1A73E8"), ("Done", "#188038")]
    ):
        stage = client.call(
            "POST",
            "/stages",
            {
                "workspace_id": ws,
                "collection_id": projects,
                "name": name,
                "color": color,
                "position": (position + 1) * 1024,
            },
        )
        stages[name] = stage["id"]

    for position, (title, stage, content) in enumerate(
        [
            ("Design the onboarding", "To do", "Three screens, skippable."),
            ("Fix sync on flaky networks", "To do", "Retry with backoff."),
            ("Pick a font", "To do", ""),
            ("Board view polish", "Doing", "Rolling column counters."),
            ("Font picker", "Doing", "Settings, Appearance."),
            ("Keep import", "Done", "Google Takeout zip."),
            ("Note links", "Done", "[[id|Title]] with backlinks."),
            ("Someday: dark app icon", None, ""),
        ]
    ):
        note(
            collection_id=projects,
            title=title,
            content=content,
            stage_id=stages.get(stage),
            stage_position=(position + 1) * 1024,
            label_ids=[labels["Work"]],
        )


def main():
    env = load_env()
    client = Client(env["SKIPPY_URL"])
    try:
        sign_in(client, env)
        if client.call("GET", "/notes"):
            print(f"Account already has notes; left as is. Credentials: {ENV_FILE}")
            return
        seed(client)
    except urllib.error.HTTPError as error:
        sys.exit(f"{error.code} {error.reason}: {error.read().decode()[:300]}")
    except urllib.error.URLError as error:
        sys.exit(f"Server not reachable at {env['SKIPPY_URL']}: {error.reason}")
    print(f"Seeded. Credentials: {ENV_FILE}")


if __name__ == "__main__":
    main()
