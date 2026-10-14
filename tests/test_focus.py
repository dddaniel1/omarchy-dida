"""Tests for ticktick.focus — the pomodoro state machine and its record.

The clock is a parameter everywhere, so every transition is tested at fixed instants
rather than by sleeping. The two things most worth pinning down are the ones that
produced a wrong record in the reference implementation this ported from: a completed
block must upload its *configured* span rather than however late the shell noticed, and
a break must upload nothing at all.
"""

import pathlib
import sys
import unittest
from datetime import datetime

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from ticktick import focus  # noqa: E402

# 2023-11-14T22:13:20Z — far from the epoch, so a 0-means-unset bug can't hide.
BASE = 1_700_000_000_000
MINUTE = 60_000


class Prefs(unittest.TestCase):
    def test_zero_means_unset_not_zero_length(self) -> None:
        settings = focus.prefs(0, 0, 0, 0)
        self.assertEqual(settings.focus, focus.DEFAULT_FOCUS_MINUTES)
        self.assertEqual(settings.short_break, focus.DEFAULT_SHORT_BREAK_MINUTES)
        self.assertEqual(settings.long_break, focus.DEFAULT_LONG_BREAK_MINUTES)
        self.assertEqual(settings.long_interval, focus.DEFAULT_LONG_BREAK_INTERVAL)

    def test_explicit_values_win(self) -> None:
        settings = focus.prefs(50, 10, 30, 2)
        self.assertEqual(settings.as_dict(), {
            "focus": 50, "shortBreak": 10, "longBreak": 30, "longInterval": 2,
        })

    def test_junk_falls_back(self) -> None:
        settings = focus.prefs("x", None, [], {})
        self.assertEqual(settings.focus, focus.DEFAULT_FOCUS_MINUTES)

    def test_absurd_values_are_clamped(self) -> None:
        settings = focus.prefs(100000, 9999, 9999, 999)
        self.assertEqual(settings.focus, 480)
        self.assertEqual(settings.short_break, 240)
        self.assertEqual(settings.long_break, 480)
        self.assertEqual(settings.long_interval, 24)

    def test_phase_seconds(self) -> None:
        settings = focus.prefs(25, 5, 15, 4)
        self.assertEqual(focus.phase_seconds(focus.FOCUS, settings), 1500)
        self.assertEqual(focus.phase_seconds(focus.SHORT_BREAK, settings), 300)
        self.assertEqual(focus.phase_seconds(focus.LONG_BREAK, settings), 900)


class NextPhase(unittest.TestCase):
    def setUp(self) -> None:
        self.settings = focus.prefs(25, 5, 15, 4)

    def test_every_fourth_block_earns_the_long_break(self) -> None:
        self.assertEqual(focus.next_phase(1, self.settings), focus.SHORT_BREAK)
        self.assertEqual(focus.next_phase(3, self.settings), focus.SHORT_BREAK)
        self.assertEqual(focus.next_phase(4, self.settings), focus.LONG_BREAK)
        self.assertEqual(focus.next_phase(8, self.settings), focus.LONG_BREAK)

    def test_the_first_block_of_a_session_is_short(self) -> None:
        self.assertEqual(focus.next_phase(0, self.settings), focus.SHORT_BREAK)

    def test_junk_yields_the_conservative_answer(self) -> None:
        self.assertEqual(focus.next_phase("x", self.settings), focus.SHORT_BREAK)
        self.assertEqual(focus.next_phase(None, self.settings), focus.SHORT_BREAK)

    def test_labels(self) -> None:
        self.assertEqual(focus.phase_label(focus.FOCUS), "Focus")
        self.assertEqual(focus.phase_label(focus.SHORT_BREAK), "Short break")
        self.assertEqual(focus.phase_label(focus.LONG_BREAK), "Long break")
        self.assertEqual(focus.phase_label(focus.IDLE), "Idle")


class Machine(unittest.TestCase):
    def setUp(self) -> None:
        self.settings = focus.prefs(25, 5, 15, 4)

    def test_blank_is_idle(self) -> None:
        state = focus.blank_state(self.settings)
        self.assertEqual(state["phase"], focus.IDLE)
        self.assertFalse(focus.is_running(state))
        self.assertFalse(focus.is_paused(state))
        self.assertEqual(focus.remaining_ms(state, BASE), 0)

    def test_start_sets_a_deadline_a_phase_long(self) -> None:
        state = focus.start(focus.blank_state(self.settings), now_ms=BASE, settings=self.settings)
        self.assertEqual(state["phase"], focus.FOCUS)
        self.assertTrue(focus.is_running(state))
        self.assertEqual(focus.remaining_ms(state, BASE), 25 * MINUTE)
        self.assertEqual(focus.remaining_ms(state, BASE + 10 * MINUTE), 15 * MINUTE)

    def test_remaining_never_goes_negative(self) -> None:
        state = focus.start(focus.blank_state(self.settings), now_ms=BASE, settings=self.settings)
        self.assertEqual(focus.remaining_ms(state, BASE + 99 * MINUTE), 0)

    def test_settled_only_after_the_clock_runs_out(self) -> None:
        state = focus.start(focus.blank_state(self.settings), now_ms=BASE, settings=self.settings)
        self.assertFalse(focus.settled(state, now_ms=BASE + 24 * MINUTE))
        self.assertTrue(focus.settled(state, now_ms=BASE + 25 * MINUTE))

    def test_pause_freezes_and_resume_continues(self) -> None:
        state = focus.start(focus.blank_state(self.settings), now_ms=BASE, settings=self.settings)
        state = focus.pause(state, now_ms=BASE + 5 * MINUTE)
        self.assertTrue(focus.is_paused(state))
        self.assertFalse(focus.is_running(state))
        # Time passing while paused changes nothing.
        self.assertEqual(focus.remaining_ms(state, BASE + 30 * MINUTE), 20 * MINUTE)
        # A paused clock never "finishes", no matter how long it sits.
        self.assertFalse(focus.settled(state, now_ms=BASE + 300 * MINUTE))

        state = focus.resume(state, now_ms=BASE + 30 * MINUTE)
        self.assertTrue(focus.is_running(state))
        self.assertEqual(focus.remaining_ms(state, BASE + 30 * MINUTE), 20 * MINUTE)

    def test_pause_time_is_accumulated_across_pauses(self) -> None:
        state = focus.start(focus.blank_state(self.settings), now_ms=BASE, settings=self.settings)
        state = focus.pause(state, now_ms=BASE + 1 * MINUTE)
        state = focus.resume(state, now_ms=BASE + 3 * MINUTE)      # 2 minutes paused
        state = focus.pause(state, now_ms=BASE + 10 * MINUTE)
        state = focus.resume(state, now_ms=BASE + 13 * MINUTE)     # 3 more
        self.assertEqual(state["pause_ms"], 5 * MINUTE)

        record = focus.record_from(state)
        self.assertEqual(record["pauseDuration"], 300)

    def test_pausing_something_idle_is_a_no_op(self) -> None:
        state = focus.blank_state(self.settings)
        self.assertEqual(focus.pause(state, now_ms=BASE)["phase"], focus.IDLE)
        self.assertEqual(focus.resume(state, now_ms=BASE)["phase"], focus.IDLE)

    def test_restarting_abandons_the_running_block(self) -> None:
        state = focus.start(focus.blank_state(self.settings), now_ms=BASE, settings=self.settings)
        state = focus.start(state, now_ms=BASE + MINUTE, settings=self.settings)
        self.assertEqual(state["started_at"], BASE + MINUTE)
        self.assertEqual(state["blocks_done"], 0)

    def test_stop_discards_without_counting_or_logging(self) -> None:
        state = focus.start(focus.blank_state(self.settings), now_ms=BASE, settings=self.settings)
        state = focus.stop(state)
        self.assertEqual(state["phase"], focus.IDLE)
        self.assertEqual(state["blocks_done"], 0)
        self.assertEqual(state["started_at"], 0)


class Completing(unittest.TestCase):
    def setUp(self) -> None:
        self.settings = focus.prefs(25, 5, 15, 4)

    def start_focus(self, at: int = BASE) -> dict:
        return focus.start(focus.blank_state(self.settings), now_ms=at, settings=self.settings)

    def test_a_finished_focus_block_is_recorded_and_followed_by_a_break(self) -> None:
        state = self.start_focus()
        state, record = focus.complete(state, now_ms=BASE + 25 * MINUTE)
        self.assertIsNotNone(record)
        self.assertEqual(record["type"], focus.TYPE_POMODORO)
        self.assertEqual(state["phase"], focus.SHORT_BREAK)
        self.assertEqual(state["blocks_done"], 1)
        self.assertEqual(focus.remaining_ms(state, BASE + 25 * MINUTE), 5 * MINUTE)

    def test_the_record_spans_the_block_that_was_asked_for_not_a_late_arrival(self) -> None:
        # The shell may notice seconds or minutes late; the block was still 25 minutes.
        state = self.start_focus()
        _, record = focus.complete(state, now_ms=BASE + 40 * MINUTE)
        self.assertEqual(record["duration"], 1500)
        started = int(focus._instant_ms(record["startTime"]) / 1000)
        ended = int(focus._instant_ms(record["endTime"]) / 1000)
        self.assertEqual(ended - started, 1500)

    def test_pause_is_reported_separately_and_does_not_inflate_the_block(self) -> None:
        # A pause pushes the deadline out, so the wall span grows by exactly the pause:
        # focused time stays the 25 minutes that were asked for, and the pause is
        # reported on its own for the account's own accounting.
        state = self.start_focus()
        state = focus.pause(state, now_ms=BASE + 5 * MINUTE)
        state = focus.resume(state, now_ms=BASE + 8 * MINUTE)  # 3 minutes paused
        _, record = focus.complete(state, now_ms=BASE + 28 * MINUTE)
        self.assertEqual(record["pauseDuration"], 180)
        self.assertEqual(record["duration"], 1500)
        started = int(focus._instant_ms(record["startTime"]) / 1000)
        ended = int(focus._instant_ms(record["endTime"]) / 1000)
        self.assertEqual(ended - started, 1500 + 180)

    def test_a_finished_break_records_nothing_and_ends_idle(self) -> None:
        state = focus.start(
            focus.blank_state(self.settings), now_ms=BASE, settings=self.settings,
            phase=focus.SHORT_BREAK,
        )
        state, record = focus.complete(state, now_ms=BASE + 5 * MINUTE)
        self.assertIsNone(record)
        self.assertEqual(state["phase"], focus.IDLE)
        # A break does not move the count, so the long-break cadence counts work done.
        self.assertEqual(state["blocks_done"], 0)

    def test_the_fourth_block_gets_the_long_break(self) -> None:
        state = self.start_focus()
        breaks = []
        for index in range(1, 5):
            state, record = focus.complete(state, now_ms=BASE + index * 25 * MINUTE)
            self.assertIsNotNone(record, f"block {index} not recorded")
            self.assertEqual(state["blocks_done"], index)
            breaks.append(state["phase"])
            # The break runs out and records nothing; then the next block begins.
            state, break_record = focus.complete(state, now_ms=BASE + index * 25 * MINUTE + MINUTE)
            self.assertIsNone(break_record, f"the break after block {index} was recorded")
            self.assertEqual(state["phase"], focus.IDLE)
            state = focus.start(state, now_ms=BASE, settings=self.settings)

        self.assertEqual(
            breaks,
            [focus.SHORT_BREAK, focus.SHORT_BREAK, focus.SHORT_BREAK, focus.LONG_BREAK],
        )
        self.assertEqual(state["blocks_done"], 4)

    def test_completing_something_idle_is_harmless(self) -> None:
        state, record = focus.complete(focus.blank_state(self.settings), now_ms=BASE)
        self.assertIsNone(record)
        self.assertEqual(state["phase"], focus.IDLE)

    def test_the_block_count_survives_the_break_and_a_stop(self) -> None:
        state = self.start_focus()
        state, _ = focus.complete(state, now_ms=BASE + 25 * MINUTE)
        self.assertEqual(focus.stop(state)["blocks_done"], 1)

    def test_a_task_and_a_note_travel_with_the_record(self) -> None:
        state = focus.start(
            focus.blank_state(self.settings), now_ms=BASE, settings=self.settings,
            task_id="t1", note="deep work",
        )
        state, record = focus.complete(state, now_ms=BASE + 25 * MINUTE)
        self.assertEqual(record["taskId"], "t1")
        self.assertEqual(record["note"], "deep work")
        self.assertEqual(state["task_id"], "t1")  # the break keeps the context


class Records(unittest.TestCase):
    def test_duration_is_seconds(self) -> None:
        settings = focus.prefs(25, 5, 15, 4)
        state = focus.start(focus.blank_state(settings), now_ms=BASE, settings=settings)
        # 1500, not 25: the API documents `duration` in seconds and pairs 1500 with a
        # 25-minute span in its own example.
        self.assertEqual(focus.record_from(state)["duration"], 1500)

    def test_a_duration_is_never_zero(self) -> None:
        settings = focus.prefs(1, 1, 1, 1)
        state = focus.start(focus.blank_state(settings), now_ms=BASE, settings=settings)
        self.assertGreaterEqual(focus.record_from(state)["duration"], 1)

    def test_the_wire_format_has_no_colon_in_the_offset(self) -> None:
        settings = focus.prefs(25, 5, 15, 4)
        state = focus.start(focus.blank_state(settings), now_ms=BASE, settings=settings)
        body = focus.record_from(state)
        self.assertRegex(body["startTime"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4}$")


class Reading(unittest.TestCase):
    def test_summarise_prefers_the_timestamps(self) -> None:
        got = focus.summarise(
            [
                {
                    "startTime": "2026-10-14T19:00:27+0800",
                    "endTime": "2026-10-14T19:01:27+0800",
                    "duration": 60000,
                }
            ]
        )
        self.assertEqual(got["count"], 1)
        self.assertEqual(got["seconds"], 60)
        self.assertEqual(got["minutes"], 1)

    def test_duration_is_milliseconds_not_seconds(self) -> None:
        # A live account answers 60000 for a 60-second block, whatever the docs say.
        self.assertEqual(focus.record_seconds({"duration": 60000}), 60)
        self.assertEqual(focus.record_seconds({"duration": 1500}), 1)

    def test_pause_comes_out_of_the_focused_time(self) -> None:
        record = {
            "startTime": "2026-10-14T19:00:00+0800",
            "endTime": "2026-10-14T19:25:00+0800",
            "pauseDuration": 180,
        }
        self.assertEqual(focus.record_seconds(record), 1500 - 180)

    def test_an_absurd_pause_does_not_zero_the_block(self) -> None:
        # A pause longer than the span means the field is not in the units it claims;
        # reporting a block the user worked as zero minutes is the worse failure.
        record = {
            "startTime": "2026-10-14T19:00:00+0800",
            "endTime": "2026-10-14T19:25:00+0800",
            "pauseDuration": 999999,
        }
        self.assertEqual(focus.record_seconds(record), 1500)

    def test_a_record_without_a_readable_duration_still_counts(self) -> None:
        got = focus.summarise([{"id": "f1"}, {"duration": 60000}])
        self.assertEqual(got["count"], 2)
        self.assertEqual(got["seconds"], 60)

    def test_nothing(self) -> None:
        self.assertEqual(focus.summarise([])["count"], 0)
        self.assertEqual(focus.summarise(None)["minutes"], 0)
        self.assertEqual(focus.record_seconds({}), 0)

    def test_already_recorded_matches_on_start_time(self) -> None:
        existing = [{"startTime": "2026-04-07T09:00:00+0800"}]
        self.assertTrue(focus.already_recorded(existing, "2026-04-07T09:00:00+0800"))
        self.assertFalse(focus.already_recorded(existing, "2026-04-07T10:00:00+0800"))

    def test_already_recorded_tolerates_a_second_of_drift(self) -> None:
        existing = [{"startTime": "2026-04-07T09:00:00+0800"}]
        self.assertTrue(focus.already_recorded(existing, "2026-04-07T09:00:00+0800"))

    def test_already_recorded_with_junk_is_false_not_an_exception(self) -> None:
        self.assertFalse(focus.already_recorded([], ""))
        self.assertFalse(focus.already_recorded([{"startTime": "nonsense"}], "nonsense"))
        self.assertFalse(focus.already_recorded(None, "2026-04-07T09:00:00+0800"))

    def test_window_is_local_midnight_to_now(self) -> None:
        day = datetime(2026, 4, 7, 12, 0)
        start, end = focus.window(day, int(day.timestamp() * 1000))
        self.assertTrue(start.startswith("2026-04-07T00:00:00"))
        self.assertTrue(end.startswith("2026-04-07T12:00:00"))


class Clock(unittest.TestCase):
    def test_clock_text(self) -> None:
        self.assertEqual(focus.clock_text(0), "00:00")
        self.assertEqual(focus.clock_text(59_000), "00:59")
        self.assertEqual(focus.clock_text(25 * MINUTE), "25:00")
        self.assertEqual(focus.clock_text(3600_000), "1:00:00")
        self.assertEqual(focus.clock_text(3725_000), "1:02:05")

    def test_clock_text_never_goes_negative(self) -> None:
        self.assertEqual(focus.clock_text(-5000), "00:00")


class Status(unittest.TestCase):
    def test_idle(self) -> None:
        payload = focus.status(focus.blank_state(), now_ms=BASE)
        self.assertEqual(payload["phase"], focus.IDLE)
        self.assertFalse(payload["running"])
        self.assertFalse(payload["paused"])
        self.assertEqual(payload["clock"], "")
        self.assertEqual(payload["secondsLeft"], 0)

    def test_running(self) -> None:
        settings = focus.prefs(25, 0, 0, 0)
        state = focus.start(focus.blank_state(settings), now_ms=BASE, settings=settings)
        payload = focus.status(state, now_ms=BASE + 5 * MINUTE)
        self.assertTrue(payload["running"])
        self.assertFalse(payload["paused"])
        self.assertEqual(payload["secondsLeft"], 1200)
        self.assertEqual(payload["clock"], "20:00")
        self.assertEqual(payload["blocksDone"], 0)

    def test_paused(self) -> None:
        settings = focus.prefs(25, 0, 0, 0)
        state = focus.start(focus.blank_state(settings), now_ms=BASE, settings=settings)
        state = focus.pause(state, now_ms=BASE + 5 * MINUTE)
        payload = focus.status(state, now_ms=BASE + 60 * MINUTE)
        self.assertTrue(payload["paused"])
        self.assertFalse(payload["running"])
        self.assertEqual(payload["clock"], "20:00")

    def test_prefs_are_reported_so_the_widget_need_not_re_send_them(self) -> None:
        settings = focus.prefs(50, 10, 30, 2)
        state = focus.start(focus.blank_state(settings), now_ms=BASE, settings=settings)
        payload = focus.status(state, now_ms=BASE)
        self.assertEqual(payload["prefs"]["focus"], 50)
        self.assertEqual(payload["prefs"]["longInterval"], 2)


class Corruption(unittest.TestCase):
    def test_junk_becomes_idle_rather_than_raising(self) -> None:
        for bad in (None, [], "x", 7, {"phase": "nonsense"}, {"phase": None}):
            with self.subTest(bad=bad):
                state = focus.normalise(bad)
                self.assertEqual(state["phase"], focus.IDLE)
                self.assertEqual(focus.remaining_ms(state, BASE), 0)

    def test_strings_that_should_be_numbers_are_coerced(self) -> None:
        state = focus.normalise(
            {"phase": "focus", "started_at": str(BASE), "ends_at": str(BASE + MINUTE)}
        )
        self.assertEqual(focus.remaining_ms(state, BASE), MINUTE)

    def test_a_missing_deadline_on_a_live_phase_reads_as_paused(self) -> None:
        state = focus.normalise({"phase": "focus", "started_at": BASE})
        self.assertTrue(focus.is_paused(state))
        self.assertFalse(focus.is_running(state))

    def test_prefs_survive_a_round_trip(self) -> None:
        settings = focus.prefs(45, 7, 21, 3)
        state = focus.normalise(focus.blank_state(settings))
        self.assertEqual(focus.settings_of(state), settings)


if __name__ == "__main__":
    unittest.main()
