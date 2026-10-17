"""Management actions preserve task data and surface partial server failures."""
import io
import unittest
from unittest.mock import Mock, patch

from ticktick import api, cli, focus, manage
from ticktick.errors import UsageError


class Management(unittest.TestCase):
    def run_action(self, *argv, client=None, stdin=""):
        client = client or Mock()
        args = cli._build_parser().parse_args(["manage", *argv])
        with patch.object(manage.config, "load", return_value={"access_token": "fake"}), \
             patch.object(manage.api, "Client", return_value=client), \
             patch.object(manage.store, "load", return_value={}), \
             patch.object(manage.store, "save_quietly"), patch("sys.stdin", io.StringIO(stdin)):
            return manage.run(args), client

    def test_batch_edit_preserves_checklist_and_other_fields(self):
        client = Mock()
        client.task.return_value = {"id": "t", "projectId": "p", "items": [{"id": "i"}],
                                    "content": "Keep this", "priority": 0}
        client.batch_tasks.return_value = {"id2etag": {"t": "etag"}, "id2error": {}}
        self.run_action("batch", "edit", "--project", "p", "--ids", "t",
                        "--priority", "5", client=client)
        sent = client.batch_tasks.call_args.kwargs["update"][0]
        self.assertEqual(sent["items"], [{"id": "i"}])
        self.assertEqual(sent["content"], "Keep this")
        self.assertEqual(sent["priority"], 5)

    def test_batch_partial_failure_is_visible(self):
        client = Mock()
        client.batch_tasks.return_value = {"id2etag": {}, "id2error": {"t": "NO_PROJECT_PERMISSION"}}
        payload, _ = self.run_action("batch", "add", stdin='{"add":[{"title":"Hello"}]}', client=client)
        self.assertIn("NO_PROJECT_PERMISSION", payload["warning"])

    def test_complete_does_not_silently_drop_task_51(self):
        with self.assertRaises(UsageError):
            self.run_action("batch", "complete", "--project", "p", "--ids", ",".join(map(str, range(51))))

    def test_destructive_action_requires_confirmation(self):
        with self.assertRaises(UsageError):
            self.run_action("comment", "delete", "--project", "p", "--task", "t", "--id", "c")

    def test_revoke_clears_private_cache_and_timer_after_server_accepts(self):
        with patch.object(manage.auth, "logout") as logout, \
             patch.object(manage.store, "STATE_PATH") as state_path, \
             patch.object(manage.store, "FOCUS_PATH") as focus_path:
            payload, client = self.run_action("revoke", "revoke", "--yes")
        client.revoke_token.assert_called_once()
        logout.assert_called_once()
        state_path.unlink.assert_called_once_with(missing_ok=True)
        focus_path.unlink.assert_called_once_with(missing_ok=True)
        self.assertTrue(payload["result"]["revoked"])

    def test_habit_edit_preserves_unedited_settings(self):
        client = Mock()
        client.habit.return_value = {"id": "h", "name": "Water", "reminders": ["09:00"], "goal": 8}
        client.update_habit.return_value = {"id": "h"}
        self.run_action("habit", "edit", "--id", "h", "--name", "Drink water", client=client)
        self.assertEqual(client.update_habit.call_args.kwargs["reminders"], ["09:00"])

    def test_due_only_edit_preserves_priority(self):
        client = Mock()
        client.task.return_value = {"id": "t", "projectId": "p", "priority": 5}
        client.batch_tasks.return_value = {"id2error": {}}
        self.run_action("batch", "edit", "--project", "p", "--ids", "t", "--end", "tomorrow", client=client)
        self.assertEqual(client.batch_tasks.call_args.kwargs["update"][0]["priority"], 5)

    def test_habit_unit_can_be_cleared_or_preserved(self):
        for flags, expected in (([], "cups"), (["--unit", ""], "")):
            with self.subTest(flags=flags):
                client = Mock()
                client.habit.return_value = {"id": "h", "unit": "cups", "reminders": ["09:00"]}
                client.update_habit.return_value = {"id": "h"}
                self.run_action("habit", "edit", "--id", "h", "--name", "Water", *flags, client=client)
                self.assertEqual(client.update_habit.call_args.kwargs["unit"], expected)
                self.assertEqual(client.update_habit.call_args.kwargs["reminders"], ["09:00"])

    def test_habit_accepts_human_repeat_preset(self):
        client = Mock()
        client.create_habit.return_value = {"id": "h"}
        self.run_action("habit", "add", "--name", "Read", "--repeat", "weekly", client=client)
        self.assertIn("FREQ=WEEKLY", client.create_habit.call_args.kwargs["repeatRule"])

    def test_invalid_date_range_does_not_reach_server(self):
        with self.assertRaises(UsageError):
            self.run_action("undone", "list", "--start", "2026-01-01", "--end", "2026-02-01")

    def test_partial_completion_reports_uncompleted_ids(self):
        client = Mock()
        client.complete_tasks.return_value = ["a"]
        payload, _ = self.run_action("batch", "complete", "--project", "p", "--ids", "a,b", client=client)
        self.assertEqual(payload["result"]["failed"], ["b"])
        self.assertIn("b", payload["warning"])

    def test_read_and_write_resources_dispatch(self):
        cases = [
            (("countdown", "list"), "countdowns"),
            (("habit", "get", "--id", "h"), "habit"),
            (("tag", "add", "--name", "home"), "create_tag"),
            (("folder", "add", "--name", "Home"), "create_project_group"),
            (("folder", "edit", "--id", "g", "--name", "Life"), "update_project_group"),
            (("folder", "delete", "--id", "g", "--yes"), "delete_project_group"),
            (("project", "get", "--project", "p"), "project"),
            (("column", "list", "--project", "p"), "columns"),
            (("column", "add", "--project", "p", "--name", "Doing"), "create_column"),
            (("column", "edit", "--project", "p", "--id", "c", "--name", "Done"), "update_column"),
            (("comment", "list", "--project", "p", "--task", "t"), "comments"),
            (("comment", "add", "--project", "p", "--task", "t", "--content", "Progress"), "add_comment"),
            (("comment", "delete", "--project", "p", "--task", "t", "--id", "c", "--yes"), "delete_comment"),
            (("member", "list", "--project", "p"), "members"),
            (("assignment", "edit", "--project", "p", "--task", "t", "--username", "me"), "assign_task"),
            (("assignment", "delete", "--project", "p", "--task", "t", "--yes"), "assign_task"),
            (("focus-record", "get", "--id", "f", "--type", "1"), "focus_record"),
            (("focus-record", "delete", "--id", "f", "--yes"), "delete_focus"),
        ]
        for argv, method in cases:
            with self.subTest(argv=argv):
                client = Mock()
                getattr(client, method).return_value = {}
                self.run_action(*argv, client=client)
                getattr(client, method).assert_called_once()


class Stopwatch(unittest.TestCase):
    def test_pause_resume_and_save_count_only_work(self):
        timer = focus.start({}, phase=focus.TIMING, now_ms=1000, task_id="task")
        timer = focus.pause(timer, now_ms=11000)
        self.assertEqual(focus.remaining_ms(timer, 90000), 10000)
        timer = focus.resume(timer, now_ms=21000)
        self.assertFalse(focus.settled(timer, now_ms=31000))
        timer, record = focus.complete(timer, now_ms=31000)
        self.assertEqual(record["type"], 1)
        self.assertEqual(record["duration"], 20)
        self.assertEqual(record["pauseDuration"], 10)
        self.assertEqual(record["taskId"], "task")
        self.assertEqual(timer["phase"], focus.IDLE)

    def test_save_while_paused_excludes_current_pause(self):
        timer = focus.start({}, phase=focus.TIMING, now_ms=1000)
        timer = focus.pause(timer, now_ms=11000)
        _, record = focus.complete(timer, now_ms=99000)
        self.assertEqual(record["duration"], 10)


class Transport(unittest.TestCase):
    def test_new_endpoints_use_open_api(self):
        client = api.Client("test-token")
        cases = [
            (lambda: client.preferences(), "POST", "/preference"),
            (lambda: client.countdowns(), "GET", "/countdown"),
            (lambda: client.complete_tasks("p", ["t"]), "POST", "/task/completeTasks"),
            (lambda: client.batch_tasks(add=[], update=[]), "POST", "/task/batch"),
            (lambda: client.undone_tasks(startDate="a", endDate="b"), "POST", "/task/undone"),
            (lambda: client.add_comment("p", "t", "Hello"), "POST", "/project/p/task/t/comment"),
            (lambda: client.delete_comment("p", "t", "c"), "DELETE", "/project/p/task/t/comment/c"),
            (lambda: client.members("p"), "GET", "/project/p/members"),
            (lambda: client.assign_task("p", "t", "me"), "POST", "/task/assign"),
            (lambda: client.assign_task("p", "t"), "POST", "/task/unassign"),
            (lambda: client.create_column("p", name="Doing"), "POST", "/project/p/column"),
            (lambda: client.update_column("p", "c", name="Done"), "POST", "/project/p/column/c"),
            (lambda: client.habit("h"), "GET", "/habit/h"),
            (lambda: client.create_habit(name="Read"), "POST", "/habit"),
            (lambda: client.update_habit("h", name="Read"), "POST", "/habit/h"),
            (lambda: client.focus_record("f", 1), "GET", "/focus/f?type=1"),
        ]
        for call, verb, path in cases:
            with self.subTest(path=path), patch.object(client, "request", return_value={}) as request:
                call()
                self.assertEqual(request.call_args.args[:2], (verb, path))

    def test_revoke_uses_domestic_origin_and_form_body(self):
        client = api.Client("test-token", base="https://api.dida365.com/open/v1")
        with patch.object(client, "_send") as send:
            client.revoke_token()
        method, url, body, headers = send.call_args.args
        self.assertEqual((method, url), ("POST", "https://api.dida365.com/oauth/revoke"))
        self.assertIn(b'name="token"', body)
        self.assertIn(b"test-token", body)
        self.assertTrue(headers["Content-Type"].startswith("multipart/form-data"))

    def test_identifiers_are_encoded_as_path_segments(self):
        client = api.Client("test-token")
        with patch.object(client, "request", return_value=[]) as request:
            client.comments("p/other", "task?x")
        self.assertEqual(request.call_args.args, ("GET", "/project/p%2Fother/task/task%3Fx/comments"))
