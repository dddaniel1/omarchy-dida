"""Habit check-ins: today's state, streaks, and the rows the widget renders.

Habits live on the documented Open API, unlike the web app's private `/api/v2` habit
paths, so nothing here needs a cookie session. Three facts about that surface shape
everything below, all verified against a live Dida365 account:

* The list endpoint is ``GET /habit``. ``/habits`` is a 404.
* Check-ins come back as one document *per habit*, each with a ``checkins`` array whose
  ``year`` field is not to be trusted — a live account answers ``0`` — so history is
  merged by ``habitId`` and never keyed on the year.
* ``status`` is ``2`` for a completed day. The docs call ``value``/``goal`` optional, so
  a day also counts as done when ``value >= goal`` and the status is absent.

Nothing here talks to the network or the clock: `collect` takes its source and its
"today" as arguments, which is what makes the streak arithmetic testable.
"""

from __future__ import annotations

import dataclasses
from datetime import date as _date, datetime, timedelta
from typing import Any, Callable, Iterable

from . import dates as _dates

#: `checkinStamp`, the wire's date integer: 20260407.
STAMP_FORMAT = "%Y%m%d"

#: Check-in status. A day is unfinished (0), explicitly failed (1), or done (2).
CHECKIN_UNCHECKED = 0
CHECKIN_FAILED = 1
CHECKIN_DONE = 2

#: How much history to pull. The streak is drawn from this; the endpoint's own `to` is
#: exclusive and it clamps a range over 30 days, so a longer window is walked in slices.
HISTORY_DAYS = 60

#: The most days one slice may span, inclusive.
#:
#: 29, not 30, even though the server documents a 30-day cap: the cap is measured
#: against the `to` that reaches the wire, and an inclusive 30-day window is sent as
#: `from = end-29, to = end+1`, which is 30 days of range. One day of margin costs
#: nothing and keeps the last day of a slice from being silently dropped.
MAX_WINDOW_DAYS = 29

_WEEKDAYS = ("MO", "TU", "WE", "TH", "FR", "SA", "SU")


def stamp_of(day: _date | datetime) -> int:
    """The wire's date stamp for a calendar day: 20260407."""
    return int(day.strftime(STAMP_FORMAT))


def day_of(value: Any) -> _date | None:
    """The calendar date an integer stamp denotes, or None if it is not one."""
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    text = str(number)
    if len(text) != 8:
        return None
    try:
        return datetime.strptime(text, STAMP_FORMAT).date()
    except ValueError:
        return None


def add_days(day: _date, count: int) -> _date:
    return day + timedelta(days=count)


# --- reading check-ins -------------------------------------------------------


def entries_for(checkins: dict[str, list[dict]], habit_id: str) -> list[dict]:
    """Every cached check-in for one habit, defensively typed."""
    raw = (checkins or {}).get(str(habit_id)) or []
    return [e for e in raw if isinstance(e, dict)]


def checkin_for(
    checkins: dict[str, list[dict]], habit_id: str, day_stamp: int
) -> dict | None:
    """The check-in recorded for one habit on one day, or None."""
    if day_stamp is None:
        return None
    for entry in entries_for(checkins, habit_id):
        try:
            if int(entry.get("stamp") or 0) == int(day_stamp):
                return entry
        except (TypeError, ValueError):
            continue
    return None


def is_done(entry: dict | None) -> bool:
    """Whether a check-in entry means "finished for the day".

    `status` wins when it says something: 2 is done, 1 is an explicit failure even if
    the value reached the goal. When it is absent or 0, the value has to speak, because
    the API documents `value`/`goal` as optional and a client that omits `status` is
    still expected to render as done.
    """
    if not isinstance(entry, dict):
        return False
    status = entry.get("status")
    try:
        code = int(status) if status is not None else None
    except (TypeError, ValueError):
        code = None
    if code == CHECKIN_DONE:
        return True
    if code == CHECKIN_FAILED:
        return False
    value = _number(entry.get("value"))
    goal = _number(entry.get("goal")) or 1.0
    return value is not None and value >= goal


def merge_horizons(documents: Iterable[dict]) -> dict[str, list[dict]]:
    """Fold the per-habit check-in documents into one map of habitId → entries.

    Several documents can carry the same habit when a range spans a year boundary, so
    they are concatenated rather than replaced. Entries are de-duplicated on their
    stamp, last one winning, and sorted newest first — the order the streak walk wants.
    """
    merged: dict[str, dict[int, dict]] = {}
    for document in documents or []:
        if not isinstance(document, dict):
            continue
        habit_id = str(document.get("habitId") or "")
        if not habit_id:
            continue
        bucket = merged.setdefault(habit_id, {})
        for entry in document.get("checkins") or []:
            if not isinstance(entry, dict):
                continue
            key = _int(entry.get("stamp"))
            if key is None:
                continue
            bucket[key] = entry
    return {
        habit_id: [bucket[key] for key in sorted(bucket, reverse=True)]
        for habit_id, bucket in merged.items()
    }


# --- the day's state ---------------------------------------------------------


def goal_of(habit: dict) -> float:
    """A habit's target for a day, defaulting to one click."""
    goal = _number((habit or {}).get("goal"))
    return goal if goal and goal > 0 else 1.0


def step_of(habit: dict) -> float:
    """How much one click advances a habit.

    `step` is 0 on a plain boolean habit (a live account has `step: 0.0` with
    `goal: 1.0`), which would make every click a no-op, so a non-positive step falls
    back to the goal — one click finishes the day, which is what a boolean habit means.
    """
    step = _number((habit or {}).get("step"))
    if step and step > 0:
        return step
    return goal_of(habit)


def is_quantified(habit: dict) -> bool:
    """Whether a habit has partial progress worth counting.

    Deliberately not read off `type`: a live Dida365 account reports `"time"` for a
    once-a-day habit and `"Boolean"` for another, both with `goal: 1`, so the type
    string does not decide it. The goal does — a habit you can complete in one click
    has nothing to tally — with a fractional step as the other honest signal.
    """
    goal = goal_of(habit)
    if goal > 1:
        return True
    step = _number((habit or {}).get("step")) or 0.0
    return 0 < step < goal


def progress(habit: dict, checkins: dict[str, list[dict]], day_stamp: int) -> dict:
    """Everything the widget needs to draw one habit's day, always fully populated."""
    goal = goal_of(habit)
    entry = checkin_for(checkins, str((habit or {}).get("id") or ""), day_stamp)
    value = _number((entry or {}).get("value")) or 0.0
    ratio = min(1.0, value / goal) if goal > 0 else 0.0
    return {
        "value": value,
        "goal": goal,
        "ratio": ratio,
        "done": is_done(entry),
        "quantified": is_quantified(habit),
        "step": step_of(habit),
        "unit": str((habit or {}).get("unit") or ""),
    }


def streak(checkins: dict[str, list[dict]], habit_id: str, today_stamp: int) -> int:
    """Consecutive completed days ending today, or ending yesterday when today is open.

    A streak should not read as broken at nine in the morning, so an unfinished today
    is skipped rather than counted as a miss. Only completed days count: a partial
    tally on a quantified habit keeps the run alive only by *not* breaking it, which
    is why yesterday is the anchor when today is unfinished.
    """
    done = {
        _int(entry.get("stamp"))
        for entry in entries_for(checkins, habit_id)
        if is_done(entry)
    }
    done.discard(None)

    cursor = day_of(today_stamp)
    if cursor is None:
        return 0
    if stamp_of(cursor) not in done:
        cursor = add_days(cursor, -1)

    count = 0
    while stamp_of(cursor) in done:
        count += 1
        cursor = add_days(cursor, -1)
    return count


def is_due(habit: dict, today: _date) -> bool:
    """Whether a habit's own repeat rule puts it on today's plate.

    Only `BYDAY` is honoured, because that is the one part of the RRULE a daily-or-
    weekly habit actually needs and the only part the API's own examples use. Anything
    unrecognised — no rule, `FREQ=DAILY`, a malformed value — is due, which fails
    towards showing the habit rather than hiding it.
    """
    rule = str((habit or {}).get("repeatRule") or "").upper()
    if "BYDAY=" not in rule:
        return True
    for part in rule.split(";")[1:]:
        if not part.startswith("BYDAY="):
            continue
        days = part.split("=", 1)[1].split(",")
        wanted = {_WEEKDAYS[today.weekday()]}
        return any(day.strip()[:2] in wanted for day in days if day.strip())
    return True


# --- writing a day -----------------------------------------------------------


def next_checkin(
    habit: dict,
    existing: dict | None,
    *,
    value: float | None = None,
    toggle: bool = False,
) -> tuple[float, int]:
    """The `(value, status)` a click should write, given the day so far.

    One function decides every write, so the three ways in — a plain click, an explicit
    `--value`, and `--uncheck` — cannot drift apart:

    * an explicit value wins outright, `0` included;
    * `toggle` un-finishes a day that was already finished, and otherwise behaves like
      a click;
    * a quantified habit advances by its own step, so repeated clicks walk
      1/3, 2/3, 3/3 rather than jumping straight to complete;
    * a boolean habit finishes in one click.
    """
    goal = goal_of(habit)
    step = step_of(habit)
    current = _number((existing or {}).get("value")) or 0.0

    if value is not None:
        new_value = float(value)
    elif toggle and is_done(existing):
        new_value = 0.0
    elif is_quantified(habit):
        new_value = min(current + step, goal) if current < goal else 0.0
    else:
        new_value = goal

    return new_value, (CHECKIN_DONE if new_value >= goal else CHECKIN_UNCHECKED)


def checkin_payload(
    habit: dict,
    day_stamp: int,
    new_value: float,
    status: int,
    *,
    when: datetime,
) -> dict:
    """The body `POST /habit/{id}/checkin` wants.

    `goal` travels with the write so the server records the target the click was
    measured against, and the timestamps are UTC stamps like every other date on this
    API. `id` is deliberately absent: this endpoint keys on `(habit, stamp)` itself, and
    sending another client's document id is how you overwrite the wrong day.
    """
    return {
        "stamp": int(day_stamp),
        "time": _dates.format(when),
        "opTime": _dates.format(when),
        "value": float(new_value),
        "goal": goal_of(habit),
        "status": int(status),
    }


# --- rows --------------------------------------------------------------------


def prettify_section(name: str) -> str:
    """The section name as a heading a person would recognise.

    Dida365 stores its built-in habit sections with internal names — a live account
    returns `_morning` and `_night` — and rendering those verbatim puts an underscore
    and a capitalised fragment in front of the user. The leading underscores go, the
    rest is left exactly as the account has it, and only the very first character is
    raised, so a real name like "reading list" survives intact and a Chinese one is
    untouched by an operation its script has no case for.
    """
    text = str(name or "").strip().lstrip("_").strip().replace("_", " ")
    if not text:
        return ""
    return text[0].upper() + text[1:]


def row(
    habit: dict,
    checkins: dict[str, list[dict]],
    today_stamp: int,
    *,
    today: _date,
    sections: dict[str, str] | None = None,
) -> dict:
    """One flat habit row. Every key is present and non-null, like a task row.

    Mirrors `views.row`: strings default to '', numbers to 0, lists to [], and a
    malformed habit yields a row rather than an exception.
    """
    habit = habit if isinstance(habit, dict) else {}
    habit_id = str(habit.get("id") or "")
    state = progress(habit, checkins, today_stamp)
    entry = checkin_for(checkins, habit_id, today_stamp) or {}
    section_id = str(habit.get("sectionId") or "")
    return {
        "id": habit_id,
        "name": str(habit.get("name") or ""),
        "icon": str(habit.get("iconRes") or ""),
        "color": str(habit.get("color") or ""),
        "unit": state["unit"],
        "goal": state["goal"],
        "step": state["step"],
        "quantified": state["quantified"],
        "value": state["value"],
        "ratio": state["ratio"],
        "done": state["done"],
        "status": _int(entry.get("status")) or 0,
        "streak": streak(checkins, habit_id, today_stamp),
        "totalCheckIns": _int(habit.get("totalCheckIns")) or 0,
        "encouragement": str(habit.get("encouragement") or ""),
        "sectionId": section_id,
        "section": prettify_section((sections or {}).get(section_id) or ""),
        "repeatRule": str(habit.get("repeatRule") or ""),
        "targetDays": _int(habit.get("targetDays")) or 0,
        "due": is_due(habit, today),
        "stamp": int(today_stamp),
    }


def active(habits: Iterable[dict]) -> list[dict]:
    """The habits worth showing: not archived, in the order the account gave them.

    `status` 0 is active; anything else is archived or deleted. The server's own order
    is kept — it reflects `sortOrder`, which is the user's arrangement in the app — and
    habits are not re-sorted here.
    """
    return [
        h
        for h in habits or []
        if isinstance(h, dict) and (_int(h.get("status")) or 0) == 0
    ]


def counts(rows: Iterable[dict]) -> dict:
    """The summary line's numbers, counted over the rows as rendered."""
    rows = list(rows or [])
    due = [r for r in rows if r.get("due")]
    done = [r for r in due if r.get("done")]
    return {
        "total": len(rows),
        "due": len(due),
        "done": len(done),
        "remaining": len(due) - len(done),
        "streakBest": max((int(r.get("streak") or 0) for r in rows), default=0),
    }


# --- collection --------------------------------------------------------------


@dataclasses.dataclass
class Snapshot:
    """A day's habits, ready to render, plus the history they were derived from.

    `documents` is the raw per-habit check-in payload, kept alongside the merged map so
    a caller can cache exactly what the API said. The merge is lossy in a way that
    matters for a cache — it is keyed by habit and day, with the `year` documents folded
    away — and re-deriving it from the raw form on every read is what keeps a cached
    write and a fresh one indistinguishable.
    """

    habits: list[dict]
    checkins: dict[str, list[dict]]
    sections: list[dict]
    today: _date
    documents: list[dict] = dataclasses.field(default_factory=list)


def fetch(
    source: Any,
    *,
    today: _date | None = None,
    history_days: int = HISTORY_DAYS,
) -> Snapshot:
    """Read habits and their check-in history from a client or a cached source.

    The window is walked in 30-day slices because the server silently clamps a longer
    range: asking for 60 days in one call returns the most recent 30, which would
    quietly halve every streak past a month.
    """
    today = today or _dates.now().date()
    habits = active(_getattr_list(source, "habits"))
    ids = [str(h.get("id") or "") for h in habits if h.get("id")]

    documents: list[dict] = []
    if ids:
        for start, end in windows(today, history_days):
            documents.extend(
                _getattr_list(
                    source,
                    "habit_checkins",
                    ids,
                    stamp_of(start),
                    stamp_of(end),
                )
            )

    sections = [
        s for s in _getattr_list(source, "habit_sections") if isinstance(s, dict)
    ]
    return Snapshot(
        habits=habits,
        checkins=merge_horizons(documents),
        sections=sections,
        today=today,
        documents=documents,
    )


def collect(
    snapshot: Snapshot,
    *,
    section_names: bool = True,
) -> dict:
    """The payload `ticktick habits` emits: rows, sections, counts and the day stamp."""
    today_stamp = stamp_of(snapshot.today)
    names = {
        str(s.get("id") or ""): prettify_section(str(s.get("name") or ""))
        for s in snapshot.sections
        if s.get("id")
    }
    rows = [
        row(
            habit,
            snapshot.checkins,
            today_stamp,
            today=snapshot.today,
            sections=names if section_names else {},
        )
        for habit in snapshot.habits
    ]
    return {
        "habits": rows,
        "sections": [
            {"id": str(s.get("id") or ""), "name": prettify_section(str(s.get("name") or ""))}
            for s in sorted(
                snapshot.sections, key=lambda s: _int(s.get("sortOrder")) or 0
            )
            if s.get("id")
        ],
        "counts": counts(rows),
        "date": {
            "stamp": today_stamp,
            "iso": snapshot.today.isoformat(),
        },
    }


def resolve(habits: Iterable[dict], needle: str) -> dict:
    """Find a habit by exact id, then exact name, then partial name.

    A name is accepted because an id is not something anyone types, and the three
    passes are ordered so a name that happens to look like another habit's id cannot
    shadow an exact id match.
    """
    habits = [h for h in habits or [] if isinstance(h, dict)]
    wanted = str(needle or "").strip()
    if not wanted:
        raise KeyError("no habit given")
    for habit in habits:
        if str(habit.get("id") or "") == wanted:
            return habit
    lowered = wanted.lower()
    for habit in habits:
        if str(habit.get("name") or "").strip().lower() == lowered:
            return habit
    for habit in habits:
        if lowered in str(habit.get("name") or "").strip().lower():
            return habit
    raise KeyError(wanted)


# --- internals ---------------------------------------------------------------


def _windows(today: _date, history_days: int) -> list[tuple[_date, _date]]:
    """(start, end) date pairs covering `history_days` back from today, newest first."""
    spans: list[tuple[_date, _date]] = []
    end = today
    remaining = max(1, int(history_days))
    while remaining > 0:
        size = min(remaining, MAX_WINDOW_DAYS)
        start = add_days(end, -(size - 1))
        spans.append((start, end))
        remaining -= size
        end = add_days(start, -1)
    return spans


#: Public spelling. The slice boundaries are part of what a caller has to know when it
#: wants to cache the raw documents rather than just render them.
windows = _windows


def _getattr_list(obj: Any, name: str, *args: Any) -> list[dict]:
    """Call `obj.name(*args)` if it exists, treat anything odd as an empty list."""
    method: Callable[..., Any] | None = getattr(obj, name, None)
    if method is None:
        return []
    try:
        value = method(*args)
    except Exception:
        # A decorative read must never take down the habit list. Auth is the one
        # exception worth propagating, and the API layer has already decided that.
        return []
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []


def _number(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return None if number != number else number  # NaN is not a number we want


def _int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


__all__ = [
    "STAMP_FORMAT",
    "HISTORY_DAYS",
    "MAX_WINDOW_DAYS",
    "CHECKIN_UNCHECKED",
    "CHECKIN_FAILED",
    "CHECKIN_DONE",
    "Snapshot",
    "active",
    "stamp_of",
    "day_of",
    "add_days",
    "entries_for",
    "checkin_for",
    "is_done",
    "is_due",
    "merge_horizons",
    "goal_of",
    "step_of",
    "is_quantified",
    "progress",
    "streak",
    "next_checkin",
    "checkin_payload",
    "row",
    "prettify_section",
    "counts",
    "fetch",
    "collect",
    "resolve",
]
