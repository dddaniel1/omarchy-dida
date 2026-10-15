"""Statistics over the account: what got done, what is left, and how it is spread.

Pure arithmetic over payloads that already exist — the rows :func:`ticktick.views.row`
renders, the completed window ``_cmd_completed`` fetches, and the habit and focus
summaries the other modules produce. Nothing here talks to the network or reads the
clock of its own: :func:`collect` is handed ``now``, exactly like ``views.row``, which
is what keeps the trend arithmetic deterministic under test.

The trend buckets finished work by the **local** calendar day of its ``completedTime``,
because "what did I finish on Tuesday" is a question about the reader's day, not about
UTC. A task completed at 23:30 belongs to that day however the wire spells the offset.

Two rules are inherited from the rest of the codebase and hold here too:

* a **note** has no checkbox and no completion, so it is excluded from every count, and
* every key is present and non-null, because a QML binding that reads a missing key
  renders the literal string ``undefined`` on screen.
"""

from __future__ import annotations

from datetime import date as _date, datetime, timedelta
from typing import Any

#: How far the completion trend reaches by default, and the ceiling it is clamped to.
#: The ceiling matches the manifest's `completedDays` cap, because both answer the same
#: "how much finished work is worth looking at" question.
DEFAULT_DAYS = 7
MAX_DAYS = 90

#: The six task buckets, in the order the UI stacks them. `completed` is not one: it is
#: a view of the other endpoint, not a place an open task can sit.
BUCKETS = ("overdue", "today", "tomorrow", "upcoming", "later", "undated")

#: TickTick's four priority levels, highest first, with the label it gives each.
PRIORITIES = ((5, "High"), (3, "Medium"), (1, "Low"), (0, "None"))

_WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")


def clamp_days(days: Any) -> int:
    """The trend window as a usable day count: at least 1, at most :data:`MAX_DAYS`."""
    try:
        number = int(days)
    except (TypeError, ValueError):
        number = DEFAULT_DAYS
    return max(1, min(MAX_DAYS, number))


def collect(
    open_rows: list[dict],
    completed_rows: list[dict],
    *,
    now: datetime,
    days: int = DEFAULT_DAYS,
    habits: dict | None = None,
    focus: dict | None = None,
) -> dict:
    """The whole stats payload, from the pieces each caller has already fetched.

    Returns ``{'days', 'generated', 'summary', 'trend', 'distribution', 'habits',
    'focus'}``. `habits` and `focus` are the modules' own payloads passed straight
    through as summaries, or None when the caller had nothing to hand over — the UI
    hides a section it was given nothing for rather than drawing it empty.
    """
    days = clamp_days(days)
    trend = completion_trend(completed_rows, now=now, days=days)
    distribution = distribution_of(open_rows)
    return {
        "days": days,
        "generated": now.isoformat(),
        "summary": summary(open_rows, trend, habits=habits, focus=focus),
        "trend": trend,
        "distribution": distribution,
        "habits": habit_summary(habits),
        "focus": focus_summary(focus),
    }


def completion_trend(rows: list[dict], *, now: datetime, days: int) -> list[dict]:
    """Finished work per local day for the last `days` days, oldest first, today last.

    Every day in the window is present even when nothing was finished, so the bar chart
    has a slot for a zero and the shape of the week does not depend on the data.
    """
    days = clamp_days(days)
    tz = now.tzinfo
    counted: dict[_date, int] = {}
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        day = _day_of(row.get("completed"), tz)
        if day is not None:
            counted[day] = counted.get(day, 0) + 1

    today = now.date()
    out: list[dict] = []
    for offset in range(days - 1, -1, -1):
        day = today - timedelta(days=offset)
        out.append(
            {
                "date": day.isoformat(),
                "weekday": _WEEKDAYS[day.weekday()],
                "count": counted.get(day, 0),
            }
        )
    return out


def distribution_of(rows: list[dict]) -> dict:
    """Where the open work sits: by list, priority, bucket and tag.

    Counted over the rows as rendered, so it can never disagree with the list the user
    is looking at. Notes are excluded from every part and reported separately; a task
    carrying several tags is counted under each, which is what a tag breakdown means.
    """
    by_list: dict[str, dict] = {}
    by_priority = {level: 0 for level, _ in PRIORITIES}
    by_bucket = {key: 0 for key in BUCKETS}
    tags: dict[str, int] = {}
    notes = 0
    total = 0

    for row in rows or []:
        if not isinstance(row, dict):
            continue
        if row.get("isNote"):
            notes += 1
            continue
        total += 1
        pid = _text(row.get("projectId"))
        entry = by_list.setdefault(
            pid,
            {
                "id": pid,
                "name": _text(row.get("project")),
                "color": _text(row.get("projectColor")),
                "count": 0,
            },
        )
        entry["count"] += 1
        by_priority[_priority(row.get("priority"))] += 1
        bucket = _text(row.get("bucket")) or "undated"
        by_bucket[bucket if bucket in by_bucket else "undated"] += 1
        for tag in row.get("tags") or []:
            name = _text(tag)
            if name:
                tags[name] = tags.get(name, 0) + 1

    lists = sorted(by_list.values(), key=lambda e: (-e["count"], e["name"].lower(), e["id"]))
    return {
        "byList": lists,
        "byPriority": [
            {"priority": level, "label": label, "count": by_priority[level]}
            for level, label in PRIORITIES
        ],
        "byBucket": by_bucket,
        "byTag": [
            {"tag": tag, "count": count}
            for tag, count in sorted(tags.items(), key=lambda kv: (-kv[1], kv[0]))
        ],
        "notes": notes,
        "total": total,
    }


def summary(
    open_rows: list[dict],
    trend: list[dict],
    *,
    habits: dict | None = None,
    focus: dict | None = None,
) -> dict:
    """The headline numbers: open, late, due today, finished, and the two side sections.

    `completed` is the sum of the trend rather than a separate count of rows, so the
    number and the chart above it are the same fact twice.
    """
    overdue = 0
    today = 0
    for row in open_rows or []:
        if not isinstance(row, dict) or row.get("isNote"):
            continue
        bucket = _text(row.get("bucket"))
        if bucket == "overdue":
            overdue += 1
        elif bucket == "today":
            today += 1

    habit = habit_summary(habits) or {}
    focus_today = focus or {}
    return {
        "open": sum(1 for r in open_rows or [] if isinstance(r, dict) and not r.get("isNote")),
        "overdue": overdue,
        "today": today,
        "completed": sum(int(day.get("count") or 0) for day in trend or []),
        "habitDue": int(habit.get("due") or 0),
        "habitDone": int(habit.get("done") or 0),
        "streakBest": int(habit.get("streakBest") or 0),
        "focusBlocks": int(focus_today.get("count") or 0),
        "focusMinutes": int(focus_today.get("minutes") or 0),
    }


def habit_summary(payload: dict | None) -> dict | None:
    """The habit section's numbers, or None when there was no habit payload."""
    if not isinstance(payload, dict):
        return None
    counts = payload.get("counts") if isinstance(payload.get("counts"), dict) else {}
    return {
        "total": int(counts.get("total") or 0),
        "due": int(counts.get("due") or 0),
        "done": int(counts.get("done") or 0),
        "remaining": int(counts.get("remaining") or 0),
        "streakBest": int(counts.get("streakBest") or 0),
    }


def focus_summary(payload: dict | None) -> dict | None:
    """The focus section's numbers for today, or None when there was no tally."""
    if not isinstance(payload, dict):
        return None
    return {
        "date": _text(payload.get("date")),
        "count": int(payload.get("count") or 0),
        "minutes": int(payload.get("minutes") or 0),
        "source": _text(payload.get("source")),
    }


# --- internals ---------------------------------------------------------------


def _day_of(epoch: Any, tz: Any) -> _date | None:
    """The local calendar day an epoch-seconds stamp falls on, or None."""
    try:
        stamp = float(epoch)
    except (TypeError, ValueError):
        return None
    if stamp <= 0:
        return None
    try:
        return datetime.fromtimestamp(stamp, tz=tz).date()
    except (OverflowError, OSError, ValueError):
        return None


def _priority(value: Any) -> int:
    """TickTick's four levels only; anything else reads as none."""
    try:
        level = int(value)
    except (TypeError, ValueError):
        return 0
    return level if level in {5, 3, 1, 0} else 0


def _text(value: Any) -> str:
    return "" if value is None else str(value)


__all__ = [
    "DEFAULT_DAYS",
    "MAX_DAYS",
    "BUCKETS",
    "PRIORITIES",
    "clamp_days",
    "collect",
    "completion_trend",
    "distribution_of",
    "summary",
    "habit_summary",
    "focus_summary",
]
