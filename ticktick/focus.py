"""Focus blocks: a pomodoro state machine, the record it uploads, and today's tally.

The *clock* is not here. A bar widget is instantiated once per monitor, so a timer
living in QML would be several clocks racing to upload the same block — the shell also
loses it on restart. Instead the state lives in a small file, every transition goes
through this module, and QML only renders what `ticktick focus` reports and ticks
locally between polls. One writer, one record, and a countdown that survives a reload.

Timings come from the widget's own settings, not the account: the Open API has no focus
preferences endpoint (`POST /preference` answers only the time zone), so `0` on a
setting means "use this module's default" rather than "ask the server".

Everything here is pure — states are plain dicts in and out, and the clock arrives as an
argument — so the phase arithmetic is testable without a shell.
"""

from __future__ import annotations

import dataclasses
from datetime import datetime, timedelta, timezone
from typing import Any

from . import dates as _dates

#: Phases. `idle` is "no block", the other three are what a countdown can be showing.
FOCUS = "focus"
SHORT_BREAK = "shortBreak"
LONG_BREAK = "longBreak"
IDLE = "idle"

PHASES = (IDLE, FOCUS, SHORT_BREAK, LONG_BREAK)
WORK_PHASES = (FOCUS,)
BREAK_PHASES = (SHORT_BREAK, LONG_BREAK)

#: Defaults, used when a setting is 0 or missing.
DEFAULT_FOCUS_MINUTES = 25
DEFAULT_SHORT_BREAK_MINUTES = 5
DEFAULT_LONG_BREAK_MINUTES = 15
DEFAULT_LONG_BREAK_INTERVAL = 4

#: The API's discriminator: 0 pomodoro, 1 open-ended stopwatch. Only 0 is produced here.
TYPE_POMODORO = 0
TYPE_TIMING = 1

#: A block is only reported as finished once the clock has actually run out. This much
#: slack absorbs QML's half-second tick landing a hair early.
FINISH_SLACK_MS = 250


@dataclasses.dataclass(frozen=True)
class Prefs:
    """Resolved durations in minutes, and how often a long break replaces a short one."""

    focus: int = DEFAULT_FOCUS_MINUTES
    short_break: int = DEFAULT_SHORT_BREAK_MINUTES
    long_break: int = DEFAULT_LONG_BREAK_MINUTES
    long_interval: int = DEFAULT_LONG_BREAK_INTERVAL

    def minutes_for(self, phase: str) -> int:
        if phase == SHORT_BREAK:
            return self.short_break
        if phase == LONG_BREAK:
            return self.long_break
        return self.focus

    def as_dict(self) -> dict:
        return {
            "focus": self.focus,
            "shortBreak": self.short_break,
            "longBreak": self.long_break,
            "longInterval": self.long_interval,
        }


def prefs(
    focus: Any = 0,
    short_break: Any = 0,
    long_break: Any = 0,
    long_interval: Any = 0,
) -> Prefs:
    """Resolve settings into durations.

    A non-positive value means "unset" for every field: the widget's settings use 0 as
    "not configured", so a 0 must fall through to the default rather than become a
    zero-length block. Values are clamped to something a person could plausibly want
    (1 minute to 8 hours of focus; a long break at least every block).
    """
    return Prefs(
        focus=_clamp(focus, 1, 480, DEFAULT_FOCUS_MINUTES),
        short_break=_clamp(short_break, 1, 240, DEFAULT_SHORT_BREAK_MINUTES),
        long_break=_clamp(long_break, 1, 480, DEFAULT_LONG_BREAK_MINUTES),
        long_interval=_clamp(long_interval, 1, 24, DEFAULT_LONG_BREAK_INTERVAL),
    )


def phase_seconds(phase: str, settings: Prefs) -> int:
    """How long a phase lasts, in seconds."""
    return int(settings.minutes_for(phase)) * 60


def next_phase(blocks_done: Any, settings: Prefs) -> str:
    """The break owed after `blocks_done` finished focus blocks.

    Every `long_interval`-th block earns the long break, so with an interval of 4 the
    4th and 8th are long and the rest are short. A count that is not a positive number
    is treated as 0, which yields the short break — the conservative answer, since
    handing out an extra-long break on bad input is the more annoying mistake.
    """
    try:
        done = int(blocks_done)
    except (TypeError, ValueError):
        done = 0
    if done <= 0:
        return SHORT_BREAK
    return LONG_BREAK if done % settings.long_interval == 0 else SHORT_BREAK


def phase_label(phase: str) -> str:
    if phase == FOCUS:
        return "Focus"
    if phase == SHORT_BREAK:
        return "Short break"
    if phase == LONG_BREAK:
        return "Long break"
    return "Idle"


# --- state -------------------------------------------------------------------


def blank_state(settings: Prefs | None = None) -> dict:
    """A fresh, idle timer. Also the shape a corrupt state file is reset to."""
    return {
        "phase": IDLE,
        "started_at": 0,
        "ends_at": 0,
        "paused_left_ms": 0,
        "pause_ms": 0,
        "pause_started_at": 0,
        "blocks_done": 0,
        "task_id": "",
        "note": "",
        "prefs": (settings or Prefs()).as_dict(),
    }


def settings_of(state: dict) -> Prefs:
    """The durations a live state carries, so a later call needs no flags."""
    raw = (state or {}).get("prefs") or {}
    if not isinstance(raw, dict):
        return Prefs()
    return prefs(
        raw.get("focus"),
        raw.get("shortBreak"),
        raw.get("longBreak"),
        raw.get("longInterval"),
    )


def normalise(state: Any) -> dict:
    """Coerce anything into a usable state. Never raises on a corrupt file."""
    if not isinstance(state, dict):
        return blank_state()
    phase = str(state.get("phase") or IDLE)
    if phase not in PHASES:
        phase = IDLE
    out = blank_state(settings_of(state))
    out.update(
        {
            "phase": phase,
            "task_id": str(state.get("task_id") or ""),
            "note": str(state.get("note") or ""),
        }
    )
    for key in ("started_at", "ends_at", "paused_left_ms", "pause_ms", "pause_started_at", "blocks_done"):
        out[key] = _int(state.get(key)) or 0
    if phase == IDLE:
        # An idle state keeps the block count — the long-break cadence spans a session
        # — but nothing else about a block that is over.
        out.update({"started_at": 0, "ends_at": 0, "paused_left_ms": 0, "pause_started_at": 0})
    return out


def is_running(state: dict) -> bool:
    return normalise(state)["phase"] != IDLE and _int(normalise(state).get("ends_at")) > 0


def is_paused(state: dict) -> bool:
    state = normalise(state)
    return state["phase"] != IDLE and not _int(state.get("ends_at"))


def remaining_ms(state: dict, now_ms: int) -> int:
    """Milliseconds left, whether the clock is running or paused. Never negative."""
    state = normalise(state)
    if state["phase"] == IDLE:
        return 0
    if state["ends_at"]:
        return max(0, state["ends_at"] - int(now_ms))
    return max(0, _int(state.get("paused_left_ms")))


def elapsed_ms(state: dict, now_ms: int) -> int:
    """Wall-clock milliseconds since the block began, pauses included."""
    state = normalise(state)
    if not state["started_at"]:
        return 0
    return max(0, int(now_ms) - state["started_at"])


def start(
    state: dict,
    *,
    now_ms: int,
    settings: Prefs | None = None,
    phase: str = FOCUS,
    task_id: str = "",
    note: str = "",
) -> dict:
    """Begin a block. Starting over abandons whatever was running, unlodged.

    A discarded block is never uploaded: the account counts completed pomodoros, and
    banking partial ones would inflate the statistics it shows on every device.
    """
    if phase not in (FOCUS,) + BREAK_PHASES:
        phase = FOCUS
    settings = settings or settings_of(state)
    out = blank_state(settings)
    out.update(
        {
            "phase": phase,
            "started_at": int(now_ms),
            "ends_at": int(now_ms) + phase_seconds(phase, settings) * 1000,
            "blocks_done": _int(normalise(state).get("blocks_done")) or 0,
            "task_id": str(task_id or ""),
            "note": str(note or ""),
        }
    )
    return out


def pause(state: dict, *, now_ms: int) -> dict:
    """Freeze the clock, remembering what was left. A no-op unless it is running."""
    out = normalise(state)
    if out["phase"] == IDLE or not out["ends_at"]:
        return out
    out["paused_left_ms"] = max(0, out["ends_at"] - int(now_ms))
    out["ends_at"] = 0
    out["pause_started_at"] = int(now_ms)
    return out


def resume(state: dict, *, now_ms: int) -> dict:
    """Restart a paused clock from where it stopped, banking the pause."""
    out = normalise(state)
    if out["phase"] == IDLE or out["ends_at"]:
        return out
    left = _int(out.get("paused_left_ms"))
    out["ends_at"] = int(now_ms) + max(0, left)
    out["paused_left_ms"] = 0
    if out["pause_started_at"]:
        out["pause_ms"] = (_int(out.get("pause_ms")) or 0) + max(
            0, int(now_ms) - out["pause_started_at"]
        )
        out["pause_started_at"] = 0
    return out


def stop(state: dict) -> dict:
    """Discard the block. Nothing is uploaded, and the block count never moves."""
    out = normalise(state)
    out.update(
        {
            "phase": IDLE,
            "started_at": 0,
            "ends_at": 0,
            "paused_left_ms": 0,
            "pause_started_at": 0,
            "task_id": "",
            "note": "",
        }
    )
    return out


def settled(state: dict, *, now_ms: int) -> bool:
    """Whether the clock has run out (paused clocks never have)."""
    state = normalise(state)
    if state["phase"] == IDLE:
        return False
    if not state["ends_at"]:
        return False
    return state["ends_at"] - int(now_ms) <= FINISH_SLACK_MS


def complete(state: dict, *, now_ms: int) -> tuple[dict, dict | None]:
    """Finish the block whose clock has run out.

    Returns ``(next_state, record)``. `record` is the body to upload and is present ONLY
    for a focus block — a finished break just ends, because the account counts pomodoros
    and a break is not one. The count of finished focus blocks moves here rather than in
    `start`, so the long-break cadence counts work actually done.
    """
    current = normalise(state)
    if current["phase"] == IDLE:
        return current, None

    settings = settings_of(current)
    record = None
    phase = current["phase"]

    if phase == FOCUS:
        record = record_from(current, settings=settings)
        blocks = (_int(current.get("blocks_done")) or 0) + 1
        follow = next_phase(blocks, settings)
        nxt = blank_state(settings)
        nxt.update(
            {
                "phase": follow,
                "started_at": int(now_ms),
                "ends_at": int(now_ms) + phase_seconds(follow, settings) * 1000,
                "blocks_done": blocks,
                "task_id": current.get("task_id") or "",
                "note": current.get("note") or "",
            }
        )
        return nxt, record

    nxt = blank_state(settings)
    nxt["blocks_done"] = _int(current.get("blocks_done")) or 0
    return nxt, None


def record_from(state: dict, *, settings: Prefs | None = None) -> dict:
    """The body `POST /focus` wants for the block a state describes.

    `endTime` is the clock's own deadline, not "now": a completion that arrives late —
    the shell was asleep, the poll was slow — should record the block that was asked
    for, not a longer one nobody worked. `duration` is the focused seconds, with the
    accumulated pause taken out, and the pause is reported separately the way the API
    models it.

    Seconds in, milliseconds back: this body's `duration` is seconds (as documented, and
    the account stores a 60-second block as `60000`), while a *read* answers in
    milliseconds. `focus.record_seconds` is the other half of that asymmetry.
    """
    state = normalise(state)
    settings = settings or settings_of(state)
    phase = state["phase"]
    started_at = _int(state.get("started_at")) or 0
    ends_at = _int(state.get("ends_at")) or (started_at + phase_seconds(phase, settings) * 1000)
    span_seconds = max(0, round((ends_at - started_at) / 1000))
    pause_seconds = max(0, round((_int(state.get("pause_ms")) or 0) / 1000))

    body: dict[str, Any] = {
        "type": TYPE_POMODORO,
        "startTime": wire_time(started_at),
        "endTime": wire_time(ends_at),
        "duration": max(1, span_seconds - pause_seconds),
        "pauseDuration": pause_seconds,
    }
    if state.get("task_id"):
        body["taskId"] = str(state["task_id"])
    if state.get("note"):
        body["note"] = str(state["note"])
    return body


# --- reading what the account has -------------------------------------------


def record_seconds(record: dict) -> int:
    """Focused seconds for one record, from the timestamps where they are usable.

    `duration` is **milliseconds** in a response, not the seconds its documentation and
    its own `1500`-for-25-minutes example claim: a 60-second block posted here comes
    back as `duration: 60000`, verified against a live account. The timestamps are
    preferred over that field anyway, because they are unambiguous and they are what the
    account's own timeline draws; `duration` is only the fallback for a record that
    arrives without them.
    """
    start = _instant_ms(record.get("startTime"))
    end = _instant_ms(record.get("endTime"))
    if start is not None and end is not None and end > start:
        span = round((end - start) / 1000)
        pause = max(0, _int(record.get("pauseDuration")) or 0)
        # A pause at or beyond the span is a field with different units than promised,
        # not a block with no focused time in it; ignore it rather than report zero.
        return max(0, span - pause) if 0 < pause < span else span
    return max(0, (_int(record.get("duration")) or 0) // 1000)


def summarise(records: list[dict]) -> dict:
    """Today's tally from `GET /focus`: how many blocks, and how long.

    A record is counted even when its duration cannot be read, so the count and the
    total can never disagree about whether a block happened.
    """
    blocks = 0
    seconds = 0
    for record in records or []:
        if not isinstance(record, dict):
            continue
        blocks += 1
        seconds += record_seconds(record)
    return {
        "count": blocks,
        "seconds": seconds,
        "minutes": int(round(seconds / 60)),
        "duration": seconds,
    }


def already_recorded(records: list[dict], start_time: str, *, slack_ms: int = 1000) -> bool:
    """Whether a block starting at `start_time` is already on the account.

    `POST /focus` takes no client-supplied id, so a replay after an ambiguous failure
    would otherwise record the same block twice. Comparing `startTime` is what makes a
    queued upload idempotent: re-sending is harmless once the first one landed.
    """
    if not start_time:
        return False
    wanted = _instant_ms(start_time)
    if wanted is None:
        return False
    for record in records or []:
        if not isinstance(record, dict):
            continue
        found = _instant_ms(record.get("startTime"))
        if found is not None and abs(found - wanted) <= slack_ms:
            return True
    return False


def window(day: datetime, now_ms: int) -> tuple[str, str]:
    """The `(from, to)` pair for one local day, up to now.

    Local midnight to now, in the API's own stamp format: asking for the whole day would
    include blocks that have not happened, and the server clamps a range over 30 days,
    so a day is the natural window for a day's tally.
    """
    start = day.replace(hour=0, minute=0, second=0, microsecond=0)
    end = datetime.fromtimestamp(now_ms / 1000, tz=start.tzinfo)
    return _dates.format(start), _dates.format(end)


def clock_text(ms: int) -> str:
    """`mm:ss`, growing to `h:mm:ss` past an hour. Never negative."""
    seconds = max(0, int(ms) // 1000)
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def wire_time(epoch_ms: int) -> str:
    """An epoch-millisecond instant as the API's `yyyy-MM-ddTHH:mm:ssZ`, in local time."""
    moment = datetime.fromtimestamp(int(epoch_ms) / 1000, tz=_dates.now().tzinfo)
    return _dates.format(moment)


def status(state: dict, *, now_ms: int, settings: Prefs | None = None) -> dict:
    """The `ticktick focus` payload: the clock, the resolved durations, nothing else."""
    state = normalise(state)
    settings = settings or settings_of(state)
    left = remaining_ms(state, now_ms)
    phase = state["phase"]
    return {
        "phase": phase,
        "label": phase_label(phase),
        "running": bool(state["ends_at"]) and phase != IDLE,
        "paused": phase != IDLE and not state["ends_at"],
        "secondsLeft": int(round(left / 1000)),
        "endsAt": _int(state.get("ends_at")) or 0,
        "clock": clock_text(left) if phase != IDLE else "",
        "blocksDone": _int(state.get("blocks_done")) or 0,
        "taskId": str(state.get("task_id") or ""),
        "prefs": settings.as_dict(),
        "startedAt": _int(state.get("started_at")) or 0,
    }


# --- internals ---------------------------------------------------------------


def _clamp(value: Any, low: int, high: int, fallback: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return fallback
    if number <= 0:
        return fallback
    return max(low, min(high, number))


def _int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _instant_ms(raw: Any) -> int | None:
    moment = _dates.parse(str(raw) if raw else None)
    if moment is None:
        return None
    return int(moment.timestamp() * 1000)


__all__ = [
    "FOCUS",
    "SHORT_BREAK",
    "LONG_BREAK",
    "IDLE",
    "PHASES",
    "WORK_PHASES",
    "BREAK_PHASES",
    "DEFAULT_FOCUS_MINUTES",
    "DEFAULT_SHORT_BREAK_MINUTES",
    "DEFAULT_LONG_BREAK_MINUTES",
    "DEFAULT_LONG_BREAK_INTERVAL",
    "TYPE_POMODORO",
    "TYPE_TIMING",
    "Prefs",
    "prefs",
    "phase_seconds",
    "next_phase",
    "phase_label",
    "blank_state",
    "settings_of",
    "normalise",
    "is_running",
    "is_paused",
    "remaining_ms",
    "elapsed_ms",
    "start",
    "pause",
    "resume",
    "stop",
    "settled",
    "complete",
    "record_from",
    "record_seconds",
    "summarise",
    "already_recorded",
    "window",
    "clock_text",
    "wire_time",
    "status",
]
