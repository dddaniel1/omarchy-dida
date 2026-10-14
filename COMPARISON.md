# Comparison — the two upstream TickTick plugins

Read from the vendored sources at the commits recorded in `README.md`. Line counts are
`wc -l` over the imported trees.

## At a glance

| | siam-ticktick | sotoaugusto-ticktick |
|---|---|---|
| Plugin id | `siam.ticktick` | `io.github.sotoaugusto.ticktick` |
| Version | 1.0.0 | 0.5.2 |
| Kinds | `bar-widget` | `bar-widget`, `service` |
| Upstream commits | 6 | 68 |
| Source size | ~14.7k lines total (5.3k Python, 3.0k QML/JS) | ~10.1k lines total (2.1k Python in one file, 4.2k QML/JS) |
| Tests | 215 Python unit tests + a QML smoke script | `test_cli.py` (550 lines) + `model.test.js` (1.7k lines) |
| Marketplace | not listed | listed, automated security baseline passed |
| Sign-in | OAuth (PKCE, self-registered app) **or** paste API token | paste the `t` cookie from ticktick.com |
| **Dida365** | `ticktick login --api-base https://api.dida365.com/open/v1` | cookie flow only, no `api_base` switch |
| Backend | `bin/ticktick` → `ticktick/` package (9 modules), full CLI | `bin/omarchy-ticktick`, one 2.1k-line script |

## Architecture

**siam-ticktick** splits into a real CLI and a thin QML front end:

```
qml/BarWidget.qml, Service.qml, TaskDetail.qml, TaskRow.qml, QuickAdd.qml, Model.js
        │  one JSON object per call, over a Process
bin/ticktick → ticktick/{cli,api,auth,store,views,nlp,dates,render,config,errors}.py
```

QML never speaks HTTP: even sign-in goes through the helper. All of the logic worth
testing — date bucketing, the natural-language parser, grouping, sorting, the sync
queue — is Python behind `unittest`. This is the more extensible of the two, and the
only one with a scriptable interface.

**sotoaugusto-ticktick** is a flatter design: a single `bin/omarchy-ticktick` script
plus `Service.qml` / `Panel.qml` / `Model.js`, with tests on both sides.

## Feature matrix

| Feature | siam | soto |
|---|:--:|:--:|
| Bar badge with due count, urgent colour when behind | ✅ | ✅ |
| Today / Tomorrow / Next-N views | ✅ | ✅ |
| Lists and folders | ✅ (folders, nested) | ✅ |
| Notes vs tasks (notes never counted) | ✅ | — |
| Task detail editing from the keyboard | ✅ | ✅ (edit in place) |
| Checklists / subtasks | ✅ | — |
| Tags, repeat rules, reminders | ✅ | tags (colour) |
| Natural-language quick add (`tomorrow 5pm !high #work`) | ✅ | — |
| Search, completed view | ✅ | — |
| **Offline-first cache + durable outbox** | ✅ | — |
| IPC (`omarchy-shell <id> …`) | ✅ | — |
| Scriptable CLI | ✅ | — |
| **Habit tracking with streaks / quantified habits** | — | ✅ |
| **Pomodoro focus timer, uploads focus stats** | — | ✅ |
| Due desktop notifications | — | ✅ (off by default) |
| Undo window before a completion is sent | — | ✅ |

Neither can un-complete a task: TickTick's API has no endpoint for it, so that stays a
manual step in the official app.

## What "too simple" probably means

The two plugins are complementary, and each is missing exactly what the other has:

- siam has the better *foundation* — CLI, offline queue, NLP, tests, Dida365 switch —
  but is a task list only.
- soto has the richer *surface* — habits, focus timer, notifications, undo — but no
  offline queue, no CLI, and no Dida365 story.

## Constraints worth keeping

`raycast-dida` in this same directory sets a house rule that matters here: **documented
public Open API endpoints only, and no undocumented authentication flows.** Measured
against that:

- `sotoaugusto`'s cookie-paste sign-in is not a documented flow (its own README explains
  that TickTick's risk control rejects scripted password logins, so the browser session
  was the practical route).
- `siam`'s OAuth PKCE and API-token paths are the documented ones, and its README
  already documents several undocumented-but-working endpoints it relies on
  (`/task/filter`, `/project/inbox/data`, and others).

## Candidate directions

1. **Fork siam-ticktick as the base**, make Dida365 the default rather than the flag,
   and add soto's habits and focus timer on top. Keeps the CLI, the offline queue and
   the tests.
2. **Port the Raycast extension's API layer** — `raycast-dida` already wraps all 11
   public endpoints with correct date/timezone handling; the plugin's Python API module
   is where that would land.
3. **Keep both trees vendored** and cherry-pick per feature, pulling upstream with
   `git subtree pull`.

Navigation, the untested parts of the QML, and anything that needs a live Omarchy
session are not settled here — this file records what the source says, not what the
widgets feel like to use.
