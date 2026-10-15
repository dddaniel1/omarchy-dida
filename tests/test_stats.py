"""Tests for ticktick.stats.

The arithmetic here is what a dashboard is trusted for, so each rule gets a test:
the trend buckets by the *local* day of a completion (not UTC, which shifts work
finishing near midnight), a note is never counted, and the shape of every list is the
same whether the account is empty or full.
"""

import pathlib
import sys
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from ticktick import stats  # noqa: E402

# Dida365's own timezone. Positive and far from UTC on purpose: a completion at 23:30
# local is a different calendar day than its UTC stamp, and the trend must follow the
# reader's day, not the wire's.
TZ = timezone(timedelta(hours=8))


def at(day: int, hour: int = 12, minute: int = 0) -> datetime:
    """A wall-clock instant in October 2026, in the reader's zone."""
    return datetime(2026, 10, day, hour, minute, tzinfo=TZ)


def epoch(when: datetime) -> int:
    return int(when.timestamp())


def open_row(**over) -> dict:
    row = {
        "id": "t1",
        "projectId": "p-work",
        "project": "Work",
        "projectColor": "#F18181",
        "bucket": "today",
        "priority": 0,
        "tags": [],
        "isNote": False,
        "completed": 0,
    }
    row.update(over)
    return row


def done_row(day: int, **over) -> dict:
    row = open_row(bucket="completed", completed=epoch(at(day, 9)))
    row.update(over)
    return row


class Clamp(unittest.TestCase):
    def test_a_window_is_at_least_a_day_and_at_most_the_cap(self) -> None:
        self.assertEqual(stats.clamp_days(0), 1)
        self.assertEqual(stats.clamp_days(-5), 1)
        self.assertEqual(stats.clamp_days(9999), stats.MAX_DAYS)

    def test_rubbish_falls_back_to_the_default(self) -> None:
        self.assertEqual(stats.clamp_days("nonsense"), stats.DEFAULT_DAYS)
        self.assertEqual(stats.clamp_days(None), stats.DEFAULT_DAYS)
        self.assertEqual(stats.clamp_days("14"), 14)


class Trend(unittest.TestCase):
    def test_every_day_in_the_window_is_present_oldest_first(self) -> None:
        trend = stats.completion_trend([], now=at(16), days=3)
        self.assertEqual([d["date"] for d in trend],
                         ["2026-10-14", "2026-10-15", "2026-10-16"])
        self.assertEqual([d["count"] for d in trend], [0, 0, 0])
        self.assertEqual(trend[-1]["weekday"], "Fri")  # 2026-10-16 really is a Friday

    def test_finished_work_lands_on_its_own_day(self) -> None:
        rows = [done_row(15), done_row(15), done_row(16)]
        trend = stats.completion_trend(rows, now=at(16), days=3)
        self.assertEqual([d["count"] for d in trend], [0, 2, 1])

    def test_a_late_night_completion_counts_on_the_local_day(self) -> None:
        # 23:30 in the reader's zone is 15:30 UTC the same day; parsing the wire stamp as
        # UTC would be right here, but one hour later would be wrong. Both are checked.
        late = open_row(completed=epoch(at(15, 23, 30)))
        early = open_row(completed=epoch(at(16, 0, 30)))
        trend = stats.completion_trend([late, early], now=at(16, 10), days=2)
        self.assertEqual([d["count"] for d in trend], [1, 1])
        self.assertEqual(trend[0]["date"], "2026-10-15")
        self.assertEqual(trend[1]["date"], "2026-10-16")

    def test_work_outside_the_window_and_bad_stamps_are_ignored(self) -> None:
        rows = [
            done_row(1),  # long before the window
            open_row(completed="not a number"),
            open_row(completed=-4),
            open_row(completed=None),
        ]
        trend = stats.completion_trend(rows, now=at(16), days=2)
        self.assertEqual([d["count"] for d in trend], [0, 0])


class Distribution(unittest.TestCase):
    def test_lists_are_counted_grouped_and_named(self) -> None:
        rows = [
            open_row(projectId="p-work", project="Work"),
            open_row(projectId="p-work", project="Work"),
            open_row(projectId="p-home", project="Home"),
            open_row(projectId="", project=""),
        ]
        dist = stats.distribution_of(rows)
        self.assertEqual([(e["name"], e["count"]) for e in dist["byList"]],
                         [("Work", 2), ("", 1), ("Home", 1)])
        self.assertEqual(dist["total"], 4)

    def test_notes_are_excluded_from_every_breakdown(self) -> None:
        rows = [open_row(), open_row(isNote=True, bucket="today", tags=["x"])]
        dist = stats.distribution_of(rows)
        self.assertEqual(dist["notes"], 1)
        self.assertEqual(dist["total"], 1)
        self.assertEqual(dist["byBucket"]["today"], 1)
        self.assertEqual(dist["byTag"], [])

    def test_every_priority_level_is_reported_and_odd_values_read_as_none(self) -> None:
        rows = [
            open_row(priority=5),
            open_row(priority=3),
            open_row(priority=1),
            open_row(priority=0),
            open_row(priority=7),  # not a TickTick level
        ]
        dist = stats.distribution_of(rows)
        self.assertEqual([(e["priority"], e["count"]) for e in dist["byPriority"]],
                         [(5, 1), (3, 1), (1, 1), (0, 2)])

    def test_buckets_cover_the_six_and_sweep_the_unknown_into_undated(self) -> None:
        rows = [open_row(bucket="overdue"), open_row(bucket="later"),
                open_row(bucket="weird")]
        dist = stats.distribution_of(rows)
        self.assertEqual(set(dist["byBucket"]), set(stats.BUCKETS))
        self.assertEqual(dist["byBucket"]["overdue"], 1)
        self.assertEqual(dist["byBucket"]["undated"], 1)

    def test_a_task_with_several_tags_is_counted_under_each(self) -> None:
        rows = [open_row(tags=["work", "urgent"]), open_row(tags=["work"])]
        dist = stats.distribution_of(rows)
        self.assertEqual(dist["byTag"], [{"tag": "work", "count": 2},
                                         {"tag": "urgent", "count": 1}])

    def test_an_empty_account_still_has_the_full_shape(self) -> None:
        dist = stats.distribution_of([])
        self.assertEqual(dist["byList"], [])
        self.assertEqual(dist["byTag"], [])
        self.assertEqual(dist["total"], 0)
        self.assertEqual([e["count"] for e in dist["byPriority"]], [0, 0, 0, 0])
        self.assertEqual(dist["byBucket"], {key: 0 for key in stats.BUCKETS})


class Summary(unittest.TestCase):
    def test_open_late_and_today_split_out(self) -> None:
        rows = [open_row(bucket="overdue"), open_row(bucket="overdue"),
                open_row(bucket="today"), open_row(bucket="upcoming"),
                open_row(isNote=True)]
        trend = stats.completion_trend([done_row(16), done_row(16)], now=at(16), days=7)
        out = stats.summary(rows, trend)
        self.assertEqual(out["open"], 4)
        self.assertEqual(out["overdue"], 2)
        self.assertEqual(out["today"], 1)
        self.assertEqual(out["completed"], 2)
        self.assertEqual(out["habitDue"], 0)
        self.assertEqual(out["focusMinutes"], 0)

    def test_habits_and_focus_fold_into_the_headline(self) -> None:
        habits = {"counts": {"total": 6, "due": 5, "done": 3, "remaining": 2, "streakBest": 9}}
        focus = {"count": 4, "minutes": 100, "date": "2026-10-16", "source": "cache"}
        out = stats.summary([open_row()], [], habits=habits, focus=focus)
        self.assertEqual(out["habitDue"], 5)
        self.assertEqual(out["habitDone"], 3)
        self.assertEqual(out["streakBest"], 9)
        self.assertEqual(out["focusBlocks"], 4)
        self.assertEqual(out["focusMinutes"], 100)


class SideSections(unittest.TestCase):
    def test_absent_payloads_summarise_to_none(self) -> None:
        self.assertIsNone(stats.habit_summary(None))
        self.assertIsNone(stats.focus_summary(None))
        self.assertIsNone(stats.habit_summary("nonsense"))
        self.assertIsNone(stats.focus_summary([]))

    def test_habit_counts_are_read_defensively(self) -> None:
        out = stats.habit_summary({"counts": {"due": "5", "done": None, "streakBest": 3}})
        self.assertEqual(out, {"total": 0, "due": 5, "done": 0, "remaining": 0,
                               "streakBest": 3})


class Collect(unittest.TestCase):
    def test_the_payload_carries_every_section(self) -> None:
        payload = stats.collect(
            [open_row()],
            [done_row(16)],
            now=at(16),
            days=7,
            habits={"counts": {"due": 1, "done": 1}},
            focus={"count": 2, "minutes": 50, "source": "network"},
        )
        self.assertEqual(payload["days"], 7)
        self.assertEqual(set(payload), {"days", "generated", "summary", "trend",
                                        "distribution", "habits", "focus", "heatmap"})
        self.assertEqual(payload["summary"]["completed"], 1)
        self.assertEqual(payload["habits"]["done"], 1)
        self.assertEqual(payload["focus"]["minutes"], 50)
        self.assertEqual(len(payload["trend"]), 7)
        self.assertEqual(len(payload["heatmap"]["weeks"]), 5)

    def test_missing_habits_and_focus_stay_null_rather_than_empty(self) -> None:
        payload = stats.collect([], [], now=at(16))
        self.assertIsNone(payload["habits"])
        self.assertIsNone(payload["focus"])

    def test_the_window_is_clamped_on_the_way_in(self) -> None:
        self.assertEqual(stats.collect([], [], now=at(16), days=0)["days"], 1)
        self.assertEqual(stats.collect([], [], now=at(16), days=500)["days"], stats.MAX_DAYS)


class Heatmap(unittest.TestCase):
    def test_heatmap_generates_five_calendar_weeks(self) -> None:
        # 2026-10-16 is Friday (weekday=4).
        # End Sunday of current week is 2026-10-18.
        # 5 weeks = 35 days total, starting Monday 2026-09-14.
        hm = stats.heatmap_data([], now=at(16), weeks=5)
        self.assertEqual(hm["weekCount"], 5)
        self.assertEqual(len(hm["weeks"]), 5)
        self.assertEqual(len(hm["days"]), 35)
        self.assertEqual(hm["weeks"][0][0]["weekdayName"], "Mon")
        self.assertEqual(hm["weeks"][-1][-1]["weekdayName"], "Sun")
        self.assertEqual(hm["weeks"][0][0]["date"], "2026-09-14")
        self.assertEqual(hm["weeks"][-1][-1]["date"], "2026-10-18")

    def test_heatmap_identifies_today_and_future(self) -> None:
        hm = stats.heatmap_data([], now=at(16), weeks=5)
        today_cell = [d for d in hm["days"] if d["isToday"]]
        self.assertEqual(len(today_cell), 1)
        self.assertEqual(today_cell[0]["date"], "2026-10-16")
        self.assertFalse(today_cell[0]["isFuture"])

        # Saturday and Sunday after today are future
        future_cells = [d for d in hm["days"] if d["isFuture"]]
        self.assertEqual(len(future_cells), 2)
        self.assertEqual([d["date"] for d in future_cells], ["2026-10-17", "2026-10-18"])
        for fc in future_cells:
            self.assertEqual(fc["level"], -1)

    def test_heatmap_counts_completions_and_levels(self) -> None:
        rows = [
            done_row(14),  # count 1 -> level 1
            done_row(15), done_row(15),  # count 2 -> level 2
            done_row(16), done_row(16), done_row(16), done_row(16),  # count 4 -> level 3
        ]
        hm = stats.heatmap_data(rows, now=at(16), weeks=5)
        by_date = {d["date"]: d for d in hm["days"]}
        self.assertEqual(by_date["2026-10-14"]["count"], 1)
        self.assertEqual(by_date["2026-10-14"]["level"], 1)
        self.assertEqual(by_date["2026-10-15"]["count"], 2)
        self.assertEqual(by_date["2026-10-15"]["level"], 2)
        self.assertEqual(by_date["2026-10-16"]["count"], 4)
        self.assertEqual(by_date["2026-10-16"]["level"], 3)
        self.assertEqual(hm["total"], 7)
        self.assertEqual(hm["maxCount"], 4)


if __name__ == "__main__":
    unittest.main()
