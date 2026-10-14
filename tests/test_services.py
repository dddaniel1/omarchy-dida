"""Tests for the service a sign-in targets: Dida365 vs the international TickTick.

This fork makes api.dida365.com the default and derives everything else — OAuth
endpoints, the developer console link, the stored `api_base` — from whatever base is in
play. A mistake here is not a broken widget, it is a token sent to the wrong service:
TickTick and Dida365 have separate accounts and separate app registries, and a token
minted on one is a 401 on the other.
"""

import os
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from ticktick import api, auth  # noqa: E402


class Defaults(unittest.TestCase):
    def test_default_base_is_dida365(self) -> None:
        self.assertEqual(api.DEFAULT_BASE, api.DIDA_BASE)
        self.assertIn("api.dida365.com", api.DEFAULT_BASE)

    def test_international_base_still_reachable(self) -> None:
        self.assertIn("api.ticktick.com", api.INTL_BASE)

    def test_module_level_oauth_defaults_match_the_default_base(self) -> None:
        self.assertEqual((auth.AUTHORIZE_URL, auth.TOKEN_URL), auth.oauth_urls(api.DEFAULT_BASE))


class SiteDomain(unittest.TestCase):
    def test_classifies_each_base(self) -> None:
        self.assertEqual(api.site_domain(api.DIDA_BASE), "dida365.com")
        self.assertEqual(api.site_domain(api.INTL_BASE), "ticktick.com")

    def test_empty_base_falls_back_to_the_default_service(self) -> None:
        self.assertEqual(api.site_domain(""), "dida365.com")

    def test_unknown_base_keeps_the_international_domain(self) -> None:
        # A proxy or a local mock. Guessing a domain it does not have would be worse
        # than the conservative answer.
        self.assertEqual(api.site_domain("http://127.0.0.1:9999/open/v1"), "ticktick.com")


class OAuthEndpoints(unittest.TestCase):
    def test_urls_follow_the_base(self) -> None:
        self.assertEqual(
            auth.oauth_urls(api.DIDA_BASE),
            ("https://dida365.com/oauth/authorize", "https://dida365.com/oauth/token"),
        )
        self.assertEqual(
            auth.oauth_urls(api.INTL_BASE),
            ("https://ticktick.com/oauth/authorize", "https://ticktick.com/oauth/token"),
        )

    def test_developer_console_follows_the_base(self) -> None:
        self.assertEqual(
            auth.developer_console(api.DIDA_BASE), "https://developer.dida365.com/manage"
        )
        self.assertEqual(
            auth.developer_console(api.INTL_BASE), "https://developer.ticktick.com/manage"
        )

    def test_authorize_cannot_open_the_other_services_app_console(self) -> None:
        # No client id + no TTY means the usage error, which must name the console for
        # the service being signed in to.
        with mock.patch.object(sys, "stdin", None):
            with self.assertRaises(Exception) as caught:
                auth.authorize(client_id="", api_base=api.INTL_BASE)
        self.assertIn("developer.ticktick.com", str(caught.exception))


class ResolveBase(unittest.TestCase):
    def test_config_wins_over_the_default(self) -> None:
        self.assertEqual(api.resolve_base({"api_base": api.INTL_BASE}), api.INTL_BASE)

    def test_env_wins_over_config(self) -> None:
        with mock.patch.dict(os.environ, {"TICKTICK_API_BASE": api.INTL_BASE}):
            self.assertEqual(api.resolve_base({"api_base": api.DIDA_BASE}), api.INTL_BASE)

    def test_no_override_is_empty_not_the_default(self) -> None:
        # Callers pass this to Client(base=...); a falsy value must leave the class
        # default alone rather than pin an instance to a guessed host.
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("TICKTICK_API_BASE", None)
            self.assertEqual(api.resolve_base({}), "")


if __name__ == "__main__":
    unittest.main()
