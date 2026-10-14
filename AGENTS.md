# AGENTS.md — omarchy-dida

## Project boundaries

- The plugin is at the **repository root** — `manifest.json`, `qml/`, `ticktick/`,
  `bin/`, `tests/`. It must stay there: `omarchy plugin add` clones a repo and requires
  `manifest.json` at the clone root, so nesting the plugin breaks the install and update
  lifecycle.
- `sources/` holds vendored upstream code, imported as `git subtree`s. Treat it as a
  reference copy: read it freely, but keep upstream changes coming in via
  `git subtree pull` so history stays intact. Nothing in `sources/` is loaded by the
  shell.
- The fork diverged from `sources/siam-ticktick`, so a subtree pull into that prefix
  does not update the plugin. Merge upstream changes by diffing the two trees by hand.
- Before editing anything, decide whether the change belongs in the plugin, in a
  vendored tree, or upstream. Only the plugin ships.
- The target account is **Dida365** (`api.dida365.com`), not `api.ticktick.com`.
  Anything that hard-codes the international host is a bug for this repo.

## Platform facts

- Plugins in this repo only run on **Omarchy 4 (Quattro)** with the Quickshell shell.
  There is no shell to load them into on Omarchy 3.x.
- The manifest contract is `schemaVersion: 1`; the marketplace rejects any other value.
- Plugin code hot-reloads on save; `omarchy-shell shell rescanPlugins` forces a reload.
- Never edit `/usr/share/omarchy/` — it is package-owned and overwritten on update.

## API and data safety

- Do not log, hard-code, commit, or expose an API token.
- Credentials and the task cache are `0600` files under `~/.config/ticktick/` and
  `~/.local/state/ticktick/`. Keep them that way, and keep signing out deleting the
  cache — it holds task titles.
- Prefer documented public Open API endpoints, as `../raycast-dida/AGENTS.md` requires.
  If an undocumented endpoint is genuinely needed, document why next to the call.
- The API has **no PATCH**: an update replaces the whole task, checklist included.
  Preserve fields the edit did not mean to touch.
- All-day due dates are midnight in the *task's* timezone; reading them as UTC shifts
  every all-day task by a day.
- Rate limiting arrives as HTTP 500 with `exceed_query_limit`, not 429.

## Code and UX conventions

- Match the upstream you are extending: Python logic stays testable and outside QML,
  QML stays presentation. Do not put HTTP in QML.
- Keep user-facing errors actionable and free of credentials.
- Destructive actions (deleting a task is permanent through this API) keep a
  confirmation.
