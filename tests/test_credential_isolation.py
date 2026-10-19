"""Other tools' credentials must never authenticate this plugin implicitly."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class CredentialIsolationTest(unittest.TestCase):
    def test_external_token_cannot_trigger_authenticated_requests(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            config_home = Path(tmp) / 'config'
            external = config_home / 'ticktick-cli' / 'config.json'
            external.parent.mkdir(parents=True)
            external_contents = json.dumps({'access_token': 'external-test-token'})
            external.write_text(external_contents)
            credentials = config_home / 'ticktick' / 'credentials.json'
            credentials.parent.mkdir()
            env = {**os.environ, 'XDG_CONFIG_HOME': str(config_home),
                   'XDG_STATE_HOME': str(Path(tmp) / 'state')}
            env.pop('TICKTICK_API_BASE', None)
            for cfg in ({}, {'adopt_external': True},
                        {'api_base': 'https://api.dida365.com/open/v1'},
                        {'api_base': 'https://api.ticktick.com/open/v1'}):
                with self.subTest(config=cfg):
                    credentials.write_text(json.dumps(cfg))
                    result = subprocess.run(
                        [sys.executable, '-c', '''
import contextlib
import io
import json
from unittest.mock import patch
from ticktick import api, cli, config
with patch.object(api.Client, 'request') as request:
    for args in [('status',), ('tags',), ('tasks', '--refresh')]:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            assert cli.main(list(args)) == 0
        payload = json.loads(output.getvalue())
        if args[0] == 'status':
            assert payload['authed'] is False, 'external token was adopted'
        else:
            assert payload['ok'] is False and payload['error'] == 'auth', payload
    request.assert_not_called()
cfg = config.load()
assert 'access_token' not in cfg
config.save({**cfg, 'inbox_id': 'inbox-test'})
assert 'access_token' not in json.loads(config.CONFIG_PATH.read_text())
assert config.CONFIG_PATH.stat().st_mode & 0o777 == 0o600
'''], cwd=root, env=env, capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(external.read_text(), external_contents)


if __name__ == '__main__':
    unittest.main()
