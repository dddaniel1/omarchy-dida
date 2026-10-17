"""Account management commands shared by the CLI and the management pane."""
from __future__ import annotations

import json
import math
import sys
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from . import api, auth, config, store
from .errors import UsageError


def register(cmd):
    p = cmd("manage", "Manage habits, dates, comments, lists and account settings.", run)
    p.add_argument("resource", choices=("habit", "countdown", "tag", "folder", "column",
                                       "project", "comment", "member", "assignment",
                                       "focus-record", "preference", "undone", "batch", "revoke"))
    p.add_argument("action", choices=("list", "get", "add", "edit", "delete", "complete", "revoke"))
    for key in ("id", "project", "task", "name", "content", "username", "color", "repeat",
                "section", "start", "end", "ids", "group"):
        p.add_argument("--" + key, default="")
    p.add_argument("--unit", default=None)
    p.add_argument("--goal", type=float, default=None)
    p.add_argument("--step", type=float, default=None)
    p.add_argument("--priority", type=int, choices=(0, 1, 3, 5), default=None)
    p.add_argument("--type", type=int, choices=(0, 1), default=0)
    p.add_argument("--yes", action="store_true")


def required(args, key):
    value = getattr(args, key)
    if not value or not str(value).strip():
        raise UsageError(f"--{key} is required")
    return value


def run(args):
    cfg = config.load()
    client = api.Client(config.token(cfg), base=api.resolve_base(cfg))
    resource, action = args.resource, args.action
    if action not in ("list", "get", "revoke") and store.load().get("outbox"):
        raise UsageError("Sync pending offline changes before managing account data: run `ticktick sync`")
    if action in ("delete", "revoke") and not args.yes:
        raise UsageError("This action is permanent; confirm with --yes")
    result = None
    if resource == "countdown" and action == "list":
        result = client.countdowns()
    elif resource == "preference" and action == "get":
        result = client.preferences()
        zone = str(result.get("timeZone") or "")
        try:
            ZoneInfo(zone)
        except (ZoneInfoNotFoundError, ValueError):
            raise UsageError("The account returned an invalid time zone") from None
        cfg["account_time_zone"] = zone
        config.save(cfg)
    elif resource == "habit":
        if action == "list":
            result = client.habits()
        elif action == "get":
            result = client.habit(required(args, "id"))
        elif action in ("add", "edit"):
            fields = {}
            for flag, field in (("name", "name"), ("color", "color"), ("repeat", "repeatRule"),
                                ("section", "sectionId")):
                if getattr(args, flag):
                    fields[field] = getattr(args, flag)
            if args.unit is not None:
                fields["unit"] = args.unit
            if args.repeat:
                from .cli import _repeat
                fields["repeatRule"] = _repeat(args.repeat)
            for field in ("goal", "step"):
                value = getattr(args, field)
                if value is not None:
                    if not math.isfinite(value) or value <= 0:
                        raise UsageError(f"--{field} must be a positive number")
                    fields[field] = value
            if action == "add":
                fields["name"] = required(args, "name")
                fields.setdefault("type", "Real" if args.goal and args.goal > 1 else "Boolean")
                fields.setdefault("goal", 1)
                fields.setdefault("step", 1)
                fields.setdefault("repeatRule", "RRULE:FREQ=DAILY;INTERVAL=1")
                result = client.create_habit(**fields)
            else:
                hid = required(args, "id")
                current = client.habit(hid)
                current.pop("id", None)
                result = client.update_habit(hid, **{**current, **fields})
    elif resource == "tag":
        if action == "list":
            result = client.tags()
        elif action == "add":
            result = client.create_tag(required(args, "name"))
    elif resource == "folder":
        if action == "list":
            result = client.project_groups()
        elif action == "add":
            result = client.create_project_group(required(args, "name"))
        elif action == "edit":
            result = client.update_project_group(required(args, "id"), name=required(args, "name"))
        elif action == "delete":
            client.delete_project_group(required(args, "id"))
            result = {"deleted": args.id}
    elif resource == "project":
        if action == "list":
            result = client.projects()
        elif action == "get":
            result = client.project(required(args, "project"))
        elif action == "edit":
            fields = {}
            for key in ("name", "color"):
                if getattr(args, key):
                    fields[key] = getattr(args, key)
            if args.color:
                import re
                if not re.fullmatch(r"#[0-9a-fA-F]{6}", args.color):
                    raise UsageError("Use a list color in #RRGGBB format")
            if args.group:
                fields["groupId"] = args.group
            result = client.update_project(required(args, "project"), **fields)
    elif resource == "column":
        pid = required(args, "project")
        if action == "list":
            result = client.columns(pid)
        elif action == "add":
            result = client.create_column(pid, name=required(args, "name"))
        elif action == "edit":
            result = client.update_column(pid, required(args, "id"), name=required(args, "name"))
    elif resource == "comment":
        pid, tid = required(args, "project"), required(args, "task")
        if action == "list":
            result = client.comments(pid, tid)
        elif action == "add":
            result = client.add_comment(pid, tid, required(args, "content"))
        elif action == "delete":
            client.delete_comment(pid, tid, required(args, "id"))
            result = {"deleted": args.id}
    elif resource == "member" and action == "list":
        result = client.members(required(args, "project"))
    elif resource == "assignment":
        if action == "edit":
            result = client.assign_task(required(args, "project"), required(args, "task"),
                                        required(args, "username"))
        elif action == "delete":
            result = client.assign_task(required(args, "project"), required(args, "task"))
    elif resource == "focus-record":
        if action == "get":
            result = client.focus_record(required(args, "id"), args.type)
        elif action == "delete":
            client.delete_focus(required(args, "id"), args.type)
            result = {"deleted": args.id}
        elif action == "list":
            result = client.focuses(required(args, "start"), required(args, "end"), args.type)
    elif resource == "undone" and action == "list":
        start, end = required(args, "start"), required(args, "end")
        try:
            span = datetime.fromisoformat(end) - datetime.fromisoformat(start)
        except (ValueError, TypeError):
            raise UsageError("Use ISO dates with matching time zones") from None
        if not 0 <= span.total_seconds() <= 14 * 86400:
            raise UsageError("The date range must be between 0 and 14 days")
        fields = {"startDate": start, "endDate": end}
        if args.project:
            fields["projectIds"] = [args.project]
        result = client.undone_tasks(**fields)
    elif resource == "batch":
        if action == "list":
            result = client.project_data(required(args, "project")).get("tasks", [])
        elif action == "complete":
            ids = list(dict.fromkeys(x.strip() for x in required(args, "ids").split(",") if x.strip()))
            if len(ids) > 50:
                raise UsageError("Select at most 50 tasks from one list")
            completed = client.complete_tasks(required(args, "project"), ids)
            result = {"completed": completed, "failed": [tid for tid in ids if tid not in completed]}
        elif action == "edit":
            pid = required(args, "project")
            ids = list(dict.fromkeys(x.strip() for x in required(args, "ids").split(",") if x.strip()))
            if len(ids) > 50:
                raise UsageError("Select at most 50 tasks")
            if not args.end and args.priority is None:
                raise UsageError("Choose a due date or priority")
            changes = {}
            if args.end:
                from . import nlp, dates
                parsed = nlp.parse(args.end)
                if parsed.due is None:
                    raise UsageError("Could not understand the due date")
                changes.update(dueDate=dates.format(parsed.due), isAllDay=parsed.all_day)
            if args.priority is not None:
                changes["priority"] = args.priority
            result = client.batch_tasks(add=[], update=[{**client.task(pid, tid), **changes} for tid in ids])
        elif action == "add" and args.content:
            titles = [x.strip() for x in args.content.splitlines() if x.strip()]
            if not 1 <= len(titles) <= 50:
                raise UsageError("Enter 1–50 task titles, one per line")
            result = client.batch_tasks(add=[{"title": t, **({"projectId": args.project} if args.project else {})}
                                             for t in titles], update=[])
        elif action == "add":
            try:
                body = json.load(sys.stdin)
            except (ValueError, OSError):
                raise UsageError("Pass a JSON object with add/update arrays on stdin") from None
            if not isinstance(body, dict) or set(body) - {"add", "update"}:
                raise UsageError("Only add and update arrays are accepted")
            add, updates = body.get("add", []), body.get("update", [])
            if any(not isinstance(items, list) or len(items) > 50 or
                   any(not isinstance(t, dict) for t in items) for items in (add, updates)):
                raise UsageError("add and update must contain at most 50 task objects each")
            merged = []
            for task in updates:
                if not task.get("id") or not task.get("projectId"):
                    raise UsageError("Each update needs id and projectId")
                merged.append({**client.task(task["projectId"], task["id"]), **task})
            result = client.batch_tasks(add=add, update=merged)
    elif resource == "revoke" and action == "revoke":
        client.revoke_token()
        auth.logout()
        store.STATE_PATH.unlink(missing_ok=True)
        store.FOCUS_PATH.unlink(missing_ok=True)
        result = {"revoked": True}
    if result is None:
        raise UsageError(f"Unsupported action: {resource} {action}")
    if action not in ("list", "get") and resource != "revoke":
        state = store.load()
        state["fetched_at"] = 0
        state["habits_fetched_at"] = 0
        if resource == "focus-record":
            state["focus_records_at"] = 0
        store.save_quietly(state)
    errors = (result.get("id2error", {}) or result.get("failed", [])) if isinstance(result, dict) else {}
    return {"resource": resource, "action": action, "result": result,
            "warning": "Some tasks failed: " + json.dumps(errors) if errors else ""}
