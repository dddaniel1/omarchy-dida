"""Tests for ticktick.habits.

The shapes here are taken from live Dida365 responses, including the ones that look
wrong: `/habit` is singular, `year` comes back as 0, a boolean habit ships `step: 0.0`,
and status 2 is the only thing that means "done". Each of those is a way to render a
streak or a tally incorrectly, so each has a test.
"""

import pathlib
import sys
import unittest
from datetime import date, datetime

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from ticktick import habits  # noqa: E402

# The real account's three habits, trimmed to the fields the module reads.
EARLY_RISE = {
    "id": "6a534177e4b056db81d2bb69",
    "name": "7点半起床",
    "status": 0,
    "goal": 1.0,
    "step": 1.0,
    "unit": "次",
    "type": "time",
    "repeatRule": "RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR,SA,SU",
    "totalCheckIns": 2,
    "sectionId": "63f781e6f7240b22d4e84609",
}
SKINCARE = {
    "id": "6a8339a2d08626b1b582aa18",
    "name": "护肤",
    "status": 0,
    "goal": 1.0,
    "step": 0.0,  # a live account really sends this
    "unit": "Count",
    "type": "Boolean",
    "repeatRule": "RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR,SA,SU",
    "totalCheckIns": 5,
    "sectionId": "-1",
}
WATER = {
    "id": "h-water",
    "name": "喝水",
    "status": 0,
    "goal": 8.0,
    "step": 1.0,
    "unit": "杯",
    "type": "Real",
}


def entry(stamp: int, value: float = 1.0, goal: float = 1.0, status: int = 2) -> dict:
    return {
        "id": f"c{stamp}",
        "stamp": stamp,
        "value": value,
        "goal": goal,
        "status": status,
        "time": "2026-08-27T15:20:45.713+0000",
        "opTime": "2026-08-27T15:20:45.713+0000",
    }


class Stamps(unittest.TestCase):
    def test_stamp_is_yyyymmdd(self) -> None:
        self.assertEqual(habits.stamp_of(date(2026, 4, 7)), 20260407)

    def test_day_of_accepts_an_integer_stamp(self) -> None:
        self.assertEqual(habits.day_of(20260407), date(2026, 4, 7))
        self.assertEqual(habits.day_of("20260407"), date(2026, 4, 7))

    def test_day_of_rejects_anything_that_is_not_a_stamp(self) -> None:
        for bad in (None, "", "2026-04-07", 0, 20261301, "nonsense"):
            with self.subTest(bad=bad):
                self.assertIsNone(habits.day_of(bad))

    def test_round_trip(self) -> None:
        day = date(2026, 12, 31)
        self.assertEqual(habits.day_of(habits.stamp_of(day)), day)


class Merging(unittest.TestCase):
    def test_merges_across_documents_for_one_habit(self) -> None:
        # A range spanning a year boundary comes back as several documents; the `year`
        # field on them is 0 on a live account and must not be used as a key.
        docs = [
            {"habitId": "h1", "year": 0, "checkins": [entry(20251231)]},
            {"habitId": "h1", "year": 0, "checkins": [entry(20260101)]},
        ]
        merged = habits.merge_horizons(docs)
        self.assertEqual([e["stamp"] for e in merged["h1"]], [20260101, 20251231])

    def test_last_document_wins_for_a_repeated_stamp(self) -> None:
        docs = [
            {"habitId": "h1", "checkins": [entry(20260101, value=1.0, status=2)]},
            {"habitId": "h1", "checkins": [entry(20260101, value=0.0, status=0)]},
        ]
        merged = habits.merge_horizons(docs)
        self.assertEqual(len(merged["h1"]), 1)
        self.assertEqual(merged["h1"][0]["status"], 0)

    def test_ignores_junk(self) -> None:
        docs = [
            None,
            {"noHabitId": True, "checkins": [entry(20260101)]},
            {"habitId": "h1", "checkins": [None, "x", {"noStamp": 1}, entry(20260101)]},
        ]
        self.assertEqual(list(habits.merge_horizons(docs)), ["h1"])

    def test_empty_input(self) -> None:
        self.assertEqual(habits.merge_horizons([]), {})
        self.assertEqual(habits.merge_horizons(None), {})


class DoneDetection(unittest.TestCase):
    def test_status_two_is_done(self) -> None:
        self.assertTrue(habits.is_done(entry(20260101, status=2)))

    def test_failed_stays_failed_even_at_goal(self) -> None:
        self.assertFalse(habits.is_done(entry(20260101, value=8.0, goal=8.0, status=1)))

    def test_missing_status_falls_back_to_value(self) -> None:
        self.assertTrue(habits.is_done({"stamp": 20260101, "value": 8.0, "goal": 8.0}))
        self.assertFalse(habits.is_done({"stamp": 20260101, "value": 3.0, "goal": 8.0}))

    def test_zero_status_falls_back_to_value(self) -> None:
        self.assertFalse(habits.is_done(entry(20260101, value=3.0, goal=8.0, status=0)))

    def test_nothing_is_not_done(self) -> None:
        self.assertFalse(habits.is_done(None))
        self.assertFalse(habits.is_done({}))


class GoalAndStep(unittest.TestCase):
    def test_goal_defaults_to_one(self) -> None:
        self.assertEqual(habits.goal_of({}), 1.0)
        self.assertEqual(habits.goal_of({"goal": 0}), 1.0)
        self.assertEqual(habits.goal_of({"goal": None}), 1.0)

    def test_a_zero_step_falls_back_to_the_goal(self) -> None:
        # Otherwise a live boolean habit (step 0.0) could never be finished by a click.
        self.assertEqual(habits.step_of(SKINCARE), 1.0)
        self.assertEqual(habits.step_of(WATER), 1.0)

    def test_quantified_is_decided_by_the_goal_not_the_type_string(self) -> None:
        self.assertFalse(habits.is_quantified(SKINCARE))   # goal 1, type Boolean
        self.assertFalse(habits.is_quantified(EARLY_RISE))  # goal 1, type "time"
        self.assertTrue(habits.is_quantified(WATER))        # goal 8

    def test_a_fractional_step_counts_as_quantified(self) -> None:
        self.assertTrue(habits.is_quantified({"goal": 1.0, "step": 0.5}))


class Progress(unittest.TestCase):
    def test_partial_tally(self) -> None:
        checkins = {"h-water": [entry(20260101, value=3.0, goal=8.0, status=0)]}
        state = habits.progress(WATER, checkins, 20260101)
        self.assertEqual(state["value"], 3.0)
        self.assertEqual(state["goal"], 8.0)
        self.assertAlmostEqual(state["ratio"], 3 / 8)
        self.assertFalse(state["done"])
        self.assertTrue(state["quantified"])

    def test_ratio_never_exceeds_one(self) -> None:
        checkins = {"h-water": [entry(20260101, value=99.0, goal=8.0, status=2)]}
        self.assertEqual(habits.progress(WATER, checkins, 20260101)["ratio"], 1.0)

    def test_an_untouched_day(self) -> None:
        state = habits.progress(SKINCARE, {}, 20260101)
        self.assertEqual(state["value"], 0.0)
        self.assertFalse(state["done"])


class Streaks(unittest.TestCase):
    def checkins(self, *stamps: int, **kwargs: object) -> dict:
        return {"h1": [entry(s, **(kwargs or {})) for s in stamps]}

    def test_today_done_counts_back(self) -> None:
        data = self.checkins(20260101, 20260102, 20260103)
        self.assertEqual(habits.streak(data, "h1", 20260103), 3)

    def test_an_open_today_does_not_break_the_run(self) -> None:
        # A streak must not read as broken at nine in the morning.
        data = self.checkins(20260101, 20260102)
        self.assertEqual(habits.streak(data, "h1", 20260103), 2)

    def test_a_missed_day_ends_it(self) -> None:
        data = self.checkins(20260108, 20260110, 20260111)
        self.assertEqual(habits.streak(data, "h1", 20260112), 2)

    def test_two_missed_days_is_zero(self) -> None:
        data = self.checkins(20260101)
        self.assertEqual(habits.streak(data, "h1", 20260103), 0)

    def test_nothing_at_all(self) -> None:
        self.assertEqual(habits.streak({}, "h1", 20260103), 0)

    def test_partial_and_failed_days_do_not_count(self) -> None:
        data = {
            "h1": [
                entry(20260103, value=1.0, status=2),
                entry(20260102, value=3.0, goal=8.0, status=0),
                entry(20260101, value=8.0, goal=8.0, status=1),
            ]
        }
        self.assertEqual(habits.streak(data, "h1", 20260103), 1)

    def test_a_run_survives_a_month_boundary(self) -> None:
        data = self.checkins(20260130, 20260131, 20260201)
        self.assertEqual(habits.streak(data, "h1", 20260201), 3)

    def test_an_unknown_today_is_zero_not_an_exception(self) -> None:
        self.assertEqual(habits.streak(self.checkins(20260101), "h1", None), 0)


class Due(unittest.TestCase):
    def test_a_daily_rule_is_due_every_day(self) -> None:
        for offset in range(7):
            day = habits.add_days(date(2026, 4, 6), offset)
            self.assertTrue(habits.is_due(EARLY_RISE, day), day)

    def test_byday_hides_the_other_days(self) -> None:
        monday_only = {"repeatRule": "RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO"}
        self.assertTrue(habits.is_due(monday_only, date(2026, 4, 6)))   # Monday
        self.assertFalse(habits.is_due(monday_only, date(2026, 4, 7)))  # Tuesday

    def test_no_rule_is_due(self) -> None:
        self.assertTrue(habits.is_due({}, date(2026, 4, 7)))

    def test_a_daily_rrule_is_due(self) -> None:
        self.assertTrue(habits.is_due({"repeatRule": "RRULE:FREQ=DAILY"}, date(2026, 4, 7)))

    def test_a_malformed_rule_fails_towards_showing_the_habit(self) -> None:
        self.assertTrue(habits.is_due({"repeatRule": "BYDAY="}, date(2026, 4, 7)))
        self.assertTrue(habits.is_due({"repeatRule": "BYDAY=??"}, date(2026, 4, 7)))


class NextCheckin(unittest.TestCase):
    def test_a_boolean_habit_finishes_in_one_click(self) -> None:
        self.assertEqual(habits.next_checkin(SKINCARE, None), (1.0, habits.CHECKIN_DONE))

    def test_a_quantified_habit_walks_its_step(self) -> None:
        goal, done = WATER["goal"], habits.CHECKIN_DONE
        self.assertEqual(habits.next_checkin(WATER, None), (1.0, habits.CHECKIN_UNCHECKED))
        self.assertEqual(
            habits.next_checkin(WATER, entry(20260101, value=1.0, goal=goal, status=0)),
            (2.0, habits.CHECKIN_UNCHECKED),
        )
        self.assertEqual(
            habits.next_checkin(WATER, entry(20260101, value=7.0, goal=goal, status=0)),
            (8.0, done),
        )

    def test_clicking_past_the_goal_starts_over(self) -> None:
        full = entry(20260101, value=8.0, goal=8.0, status=2)
        self.assertEqual(habits.next_checkin(WATER, full), (0.0, habits.CHECKIN_UNCHECKED))

    def test_toggle_undoes_a_finished_day(self) -> None:
        full = entry(20260101, value=1.0, status=2)
        self.assertEqual(
            habits.next_checkin(SKINCARE, full, toggle=True),
            (0.0, habits.CHECKIN_UNCHECKED),
        )

    def test_toggle_on_an_unfinished_day_behaves_like_a_click(self) -> None:
        partial = entry(20260101, value=3.0, goal=8.0, status=0)
        self.assertEqual(
            habits.next_checkin(WATER, partial, toggle=True),
            (4.0, habits.CHECKIN_UNCHECKED),
        )

    def test_an_explicit_value_wins(self) -> None:
        self.assertEqual(
            habits.next_checkin(WATER, None, value=5.0),
            (5.0, habits.CHECKIN_UNCHECKED),
        )

    def test_an_explicit_zero_unchecks(self) -> None:
        full = entry(20260101, value=1.0, status=2)
        self.assertEqual(
            habits.next_checkin(SKINCARE, full, value=0.0),
            (0.0, habits.CHECKIN_UNCHECKED),
        )


class Payload(unittest.TestCase):
    def test_shape(self) -> None:
        when = datetime(2026, 4, 7, 8, 0)
        body = habits.checkin_payload(WATER, 20260407, 3.0, 0, when=when)
        self.assertEqual(body["stamp"], 20260407)
        self.assertEqual(body["value"], 3.0)
        self.assertEqual(body["goal"], 8.0)
        self.assertEqual(body["status"], 0)
        self.assertNotIn("id", body)  # the endpoint keys on (habit, stamp) itself
        self.assertIn("time", body)
        self.assertIn("opTime", body)

    def test_status_uses_the_goal_at_write_time(self) -> None:
        when = datetime(2026, 4, 7, 8, 0)
        body = habits.checkin_payload(WATER, 20260407, 8.0, habits.CHECKIN_DONE, when=when)
        self.assertEqual(body["status"], habits.CHECKIN_DONE)


class Rows(unittest.TestCase):
    def test_every_key_is_present_and_non_null(self) -> None:
        row = habits.row(SKINCARE, {}, 20260407, today=date(2026, 4, 7))
        for key, value in row.items():
            with self.subTest(key=key):
                self.assertIsNotNone(value, f"{key} is null")

    def test_a_malformed_habit_still_yields_a_row(self) -> None:
        row = habits.row({"id": None}, {}, 20260407, today=date(2026, 4, 7))
        self.assertEqual(row["id"], "")
        self.assertFalse(row["done"])

    def test_not_a_dict_at_all(self) -> None:
        row = habits.row(None, {}, 20260407, today=date(2026, 4, 7))
        self.assertEqual(row["name"], "")

    def test_it_carries_the_streak_and_the_section_name(self) -> None:
        checkins = {"h1": [entry(20260101)]}
        row = habits.row(
            {"id": "h1", "goal": 1, "sectionId": "s1"},
            checkins,
            20260101,
            today=date(2026, 1, 1),
            sections={"s1": "早晨"},
        )
        self.assertEqual(row["streak"], 1)
        self.assertEqual(row["section"], "早晨")

    def test_archived_habits_are_dropped(self) -> None:
        self.assertEqual(habits.active([SKINCARE, {"id": "x", "status": 2}]), [SKINCARE])
        self.assertEqual(habits.active([None, "junk"]), [])


class Counts(unittest.TestCase):
    def test_remaining_counts_only_due_and_undone(self) -> None:
        rows = [
            {"due": True, "done": True, "streak": 3},
            {"due": True, "done": False, "streak": 0},
            {"due": False, "done": False, "streak": 9},
        ]
        got = habits.counts(rows)
        self.assertEqual(got["total"], 3)
        self.assertEqual(got["due"], 2)
        self.assertEqual(got["done"], 1)
        self.assertEqual(got["remaining"], 1)
        self.assertEqual(got["streakBest"], 9)


class Resolve(unittest.TestCase):
    def test_by_id(self) -> None:
        self.assertIs(habits.resolve([WATER], "h-water"), WATER)

    def test_by_exact_name(self) -> None:
        self.assertIs(habits.resolve([WATER], "喝水"), WATER)

    def test_by_partial_name(self) -> None:
        self.assertIs(habits.resolve([WATER], "喝"), WATER)

    def test_an_id_is_never_shadowed_by_an_earlier_name_match(self) -> None:
        sneaky = {"id": "other", "name": "h-water"}
        self.assertIs(habits.resolve([sneaky, WATER], "h-water"), WATER)

    def test_a_miss_raises(self) -> None:
        with self.assertRaises(KeyError):
            habits.resolve([WATER], "nope")
        with self.assertRaises(KeyError):
            habits.resolve([WATER], "")


class FakeSource:
    """Records the check-in windows asked for, and answers per window."""

    def __init__(self, habit_list, by_window=None, sections=None) -> None:
        self._habits = habit_list
        self._by_window = by_window or {}
        self._sections = sections if sections is not None else []
        self.windows: list[tuple[int, int]] = []

    def habits(self):
        return list(self._habits)

    def habit_checkins(self, ids, start, end):
        self.windows.append((start, end))
        return list(self._by_window.get((start, end), []))

    def habit_sections(self):
        return list(self._sections)


class Windowing(unittest.TestCase):
    def test_a_long_history_is_fetched_in_slices_under_the_server_cap(self) -> None:
        # The endpoint's `to` is exclusive and it clamps over 30 days, so a 29-day slice
        # leaves the sent range at 29 days and nothing gets silently dropped.
        source = FakeSource([WATER])
        habits.fetch(source, today=date(2026, 4, 30), history_days=60)
        self.assertEqual(len(source.windows), 3)  # 29 + 29 + 2
        for start, end in source.windows:
            span = (habits.day_of(end) - habits.day_of(start)).days
            self.assertLessEqual(span, habits.MAX_WINDOW_DAYS - 1, f"{start}..{end}")

    def test_the_newest_window_ends_today(self) -> None:
        source = FakeSource([WATER])
        habits.fetch(source, today=date(2026, 4, 30), history_days=30)
        self.assertEqual(source.windows[0][1], 20260430)

    def test_slices_do_not_overlap_or_leave_gaps(self) -> None:
        source = FakeSource([WATER])
        habits.fetch(source, today=date(2026, 4, 30), history_days=60)
        stamps = [habits.day_of(s) for _, s in source.windows]
        for older, newer in zip(stamps[1:], stamps[:-1]):
            self.assertEqual((newer - older).days, 29)  # contiguous, no gap

    def test_no_habits_means_no_requests(self) -> None:
        source = FakeSource([])
        snapshot = habits.fetch(source, today=date(2026, 4, 30))
        self.assertEqual(source.windows, [])
        self.assertEqual(snapshot.habits, [])
        self.assertEqual(snapshot.checkins, {})

    def test_a_source_without_the_methods_is_not_fatal(self) -> None:
        snapshot = habits.fetch(object(), today=date(2026, 4, 30))
        self.assertEqual(snapshot.habits, [])
        self.assertEqual(snapshot.sections, [])

    def test_the_raw_documents_are_kept_for_the_cache(self) -> None:
        # The merge is lossy; what the API said is what a cache has to hold.
        doc = {"habitId": WATER["id"], "year": 0, "checkins": [entry(20260430)]}
        source = FakeSource([WATER], by_window={(20260402, 20260430): [doc]})
        snapshot = habits.fetch(source, today=date(2026, 4, 30), history_days=29)
        self.assertEqual(snapshot.documents, [doc])
        self.assertEqual(snapshot.checkins[WATER["id"]][0]["stamp"], 20260430)


class WireBounds(unittest.TestCase):
    """`from`/`to` as they actually reach the wire, since the docs are wrong about `to`."""

    def capture(self, end_stamp: int) -> str:
        from unittest import mock

        from ticktick import api

        client = api.Client("fake-token")
        with mock.patch.object(client, "request", return_value=[]) as request:
            client.habit_checkins(["h1"], 20260401, end_stamp)
        return request.call_args.args[1]

    def test_an_inclusive_end_is_sent_one_day_later(self) -> None:
        # Verified live: `to` excludes its own day, so `from == to` answers nothing.
        self.assertIn("to=20260408", self.capture(20260407))

    def test_the_window_is_otherwise_untouched(self) -> None:
        path = self.capture(20260407)
        self.assertIn("from=20260401", path)
        self.assertIn("habitIds=h1", path)

    def test_a_month_boundary_rolls_over(self) -> None:
        self.assertIn("to=20260501", self.capture(20260430))

    def test_a_year_boundary_rolls_over(self) -> None:
        self.assertIn("to=20270101", self.capture(20261231))

    def test_no_habits_means_no_request(self) -> None:
        from unittest import mock

        from ticktick import api

        client = api.Client("fake-token")
        with mock.patch.object(client, "request", return_value=[]) as request:
            self.assertEqual(client.habit_checkins([], 20260401, 20260407), [])
        request.assert_not_called()


class Collect(unittest.TestCase):
    def test_payload_shape(self) -> None:
        source = FakeSource(
            [SKINCARE, {"id": "x", "name": "archived", "status": 2}],
            by_window={(20260401, 20260407): [
                {"habitId": SKINCARE["id"], "year": 0, "checkins": [entry(20260407)]}
            ]},
            sections=[{"id": "-1", "name": "默认", "sortOrder": 1}],
        )
        snapshot = habits.fetch(source, today=date(2026, 4, 7), history_days=7)
        payload = habits.collect(snapshot)

        self.assertEqual(len(payload["habits"]), 1)  # archived habit dropped
        self.assertEqual(payload["date"]["stamp"], 20260407)
        self.assertEqual(payload["counts"]["total"], 1)
        self.assertEqual(payload["counts"]["done"], 1)
        self.assertEqual(payload["counts"]["remaining"], 0)
        self.assertEqual(payload["habits"][0]["streak"], 1)
        self.assertEqual(payload["sections"], [{"id": "-1", "name": "默认"}])


if __name__ == "__main__":
    unittest.main()
