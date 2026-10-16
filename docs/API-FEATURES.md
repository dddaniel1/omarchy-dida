# Additional Dida365 features

The sidebar's **Dates** view reads the account's important dates. Habits has Add/Edit,
task details has Comments/Assignee, and task lists offer Select → Actions for bulk
operations. List settings lives beside the selected list; Lists… in the sidebar
contains lists, folders and tags. Focus history sits with the timer. Account time
zone and authorization revocation live under Settings. There is no Manage navigation.
The existing Focus control also offers a persistent stopwatch: pause/resume it, then
choose **Save** to upload a timing record. Discard never uploads a record.

Management operations require a connection. The existing task edits and habit check-ins
continue to use their durable offline queue. New management writes are sent once;
after an ambiguous network failure, reload before creating the same entry again.
Sync any pending offline changes before using management writes; the helper refuses
to edit account data while the outbox is nonempty, so queued work cannot overwrite it.

## CLI

All management commands return the existing JSON envelope. `--text` still selects
human output; comment/import content uses `--content`.

```sh
ticktick manage countdown list
ticktick manage habit add --name Read --goal 1
ticktick manage habit edit --id HABIT --name Reading --goal 20 --unit minutes
ticktick manage tag add --name errands
ticktick manage folder add --name Personal
ticktick manage folder edit --id FOLDER --name Life
ticktick manage project get --project LIST
ticktick manage project edit --project LIST --group FOLDER --color '#8AADF4'
ticktick manage column list --project LIST
ticktick manage column add --project LIST --name Doing
ticktick manage column edit --project LIST --id COLUMN --name Done
ticktick manage comment list --project LIST --task TASK
ticktick manage comment add --project LIST --task TASK --content 'Draft ready'
ticktick manage member list --project LIST
ticktick manage assignment edit --project LIST --task TASK --username MEMBER
ticktick manage assignment delete --project LIST --task TASK --yes
ticktick manage batch complete --project LIST --ids TASK1,TASK2
ticktick manage batch edit --project LIST --ids TASK1,TASK2 --priority 5 --end tomorrow
ticktick manage batch add --project LIST --content 'First task'
ticktick manage undone list --start 2026-10-16T00:00:00+08:00 --end 2026-10-23T00:00:00+08:00
ticktick focus start --phase timing
ticktick focus pause
ticktick focus resume
ticktick focus complete
ticktick manage focus-record list --start 2026-10-16T00:00:00+08:00 --end 2026-10-17T00:00:00+08:00 --type 1
ticktick manage focus-record get --id RECORD --type 1
ticktick manage preference get
```

For structured import, `manage batch add` without `--content` reads a JSON object
from stdin with `add` and/or `update` arrays. Each array permits at most 50 tasks.
Updates first fetch and merge each original task, preserving checklist and other fields.
Batch completion takes at most 50 IDs from one list; partial failures are returned
in `warning` and the result instead of being presented as complete success.

Deletion of folders, comments and focus records requires `--yes`. Token revocation
requires `ticktick manage revoke revoke --yes`; it invalidates the token for every
tool sharing it and removes this plugin's local task cache and timer state.

The current documented API only reads countdowns. It does not document countdown
writes, tag edit/delete, column deletion or habit deletion; those actions are not
offered. Search filters remain subject to the server limitations recorded in api.py.

Reference: <https://developer.dida365.com/docs/openapi.md>.
