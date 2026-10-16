# Dida365 UI extension

## Current contextual navigation

The sidebar keeps Today, Inbox, Next 7 days, All tasks and Done directly visible;
Tomorrow is a shortcut in the Next 7 days header. Personal lists follow after a
small gap without a My lists wrapper. Individual folders can collapse and their
children are indented. Settings opens a home page with Account settings and List
settings, covering list/folder/tag/column management. Back returns from a section
to Settings, then back to the original view.
The search icon sits inside the input with reserved text padding.
Tools starts collapsed and contains Habits and Dates. Statistics is available
from the focus ellipsis, alongside Focus history; when focus is
disabled it is available under Tools instead. Settings remains pinned below focus.
Disclosure state is stored locally in `dida-sidebar.ini` under the XDG config
directory. Selecting a hidden destination through a shortcut reveals its group.
Arrow navigation previews destinations but leaves disclosure toggles for Enter.
The interface follows Qt's system locale: Chinese locales use Simplified Chinese,
and other locales fall back to English. User task titles and list names stay as
entered. The plugin translates its controls and presentation helpers; raw server
errors and some Python-generated descriptions can retain their original wording.
Completed tasks can be restored by clicking their checkbox. The helper fetches
the full task, updates status to 0 with completedTime cleared, and checks the server
state before reporting success. Restoration requires a connection. A temporary
Dida365 task verified this update path while preserving content and checklist items.

Task start/due fields offer a themed calendar popup alongside text entry. Selecting
a date preserves an explicit HH:mm time; date-only values stay date-only. The
calendar follows the system locale and supports month navigation, arrows, Enter,
Today, Escape and outside-click dismissal. Unfinished task rows also expose a
stopwatch action alongside pomodoro on hover or keyboard selection. Both use the
shared timer, link its record to the task, and refuse to replace an active timer.
`bash tests/sidebar_ui.sh` covers grouping, disclosures, contextual actions,
hidden-view reveal and keyboard traversal against a fake backend.

The following paragraphs record the preceding flat navigation implementation.

Sidebar layout refinement: Lists and Focus history now use the same full-width
navigation rows as task views. Lists sits immediately after Inbox, so it is visible
in the default-height pane. Settings is a single full-width row pinned below the
focus timer, replacing the uneven Lists…/Settings button flow. Idle focus uses one
row with stopwatch and pomodoro actions; its previous extra text rows no longer
consume navigation height. The height budget reserves search, timer, Settings and
their actual gaps, while the remaining navigation scrolls.

Manage is no longer a sidebar destination. Habits exposes Add habit and per-row
Edit; task details exposes Comments and Assignee; task lists expose Select and
Actions with up to 50 tasks from one list. The task checkbox selects instead of
completing while selection mode is active. Changing lists cancels selection.
Lists… groups list/folder/tag organization, the active list has List… settings,
Focus history sits with the timer, and Settings holds time zone, revoke and sign-out.

Editors reuse the same form implementation with the global resource selector hidden
for a single action. Every entry resets prior edit state. Back preserves the source
view and selected list even when moving between tools. The 12-case interaction suite
and contextual Quickshell smoke cover repeated entry, nested return and selection reset.
The sections below retain the earlier implementation and acceptance history.

This records the existing Omarchy 4 interface extended for personal use. The mode is
**Operate**: choose a scope, read account data and make a deliberate change. Visual
authority remains the incumbent `qs.Ui` / `qs.Commons` implementation; this is not a
new design system or a replacement for `DESIGN.md`.

## Inherited tokens and components

| Source | Actual use |
| --- | --- |
| `Color.foreground`, `Color.background`, `Color.accent` | Theme-owned text, backgrounds and control accents; the panel passes its foreground to child panes. No fixed plugin palette. |
| `Color.urgent` | Management errors, warnings and destructive confirmation actions; existing task rows also use it for overdue metadata. |
| `Style.font.family`, `body`, `bodySmall`, `caption`, `subtitle` | Shared shell typography for controls, explanatory text, metadata and the focus clock. The shell family defaults to the system monospace alias; it is not a pinned font. |
| `Style.spacing` and `Style.space()` | Existing compact rhythm, control padding and scalable geometry. Management uses `md` between sections, `sm` between actions and `xs` within field groups. |
| `Style.cornerRadius`, shared state fills and borders | Theme-owned shape, hover/cursor, selected, pressed and active-focus treatments. Depth comes from surfaces, borders and state fills rather than a new shadow treatment. |

The installed shell defines fallback spacing (`xs` 3, `sm` 4, `md` 6 and `lg` 8)
and font sizes (`caption` 10, `bodySmall` 11, `body` 12, `subtitle` 13), but theme
overrides and scaling can change them. These are source defaults, not measurements
of the screenshots. Canonical definitions live in the installed shell's
`Commons/Style.qml` and `Commons/Color.qml`.

`Button`, `TextField` and `Dropdown` remain the standard shell controls. Buttons
support selected rows and opt-in Tab/Enter/Space operation; fields and dropdowns
use the shared focus border and fill. Dropdowns retain their own keyboard-operated
popup. Sidebar and task rows use `CursorSurface`; task project chips use
`BorderSurface`, and the sidebar keeps `PanelSeparator` and `PanelToolTip`.
`QuickAdd.qml` supplies the incumbent full-width input and wrapped read-back pattern.
One local exception is management's Qt Controls `TextArea`: it uses theme foreground,
background and corner radius, but its one-pixel foreground border does not implement
the kit's state-dependent field chrome.

## Layout, focus and scope

`Sidebar.qml` adds **Dates** and **Manage** to the existing navigation. Folder
headings remain outside the selectable cursor sequence, navigation scrolls above
the pinned focus controls, and the existing overflow thumb remains in use.

`ManagePane.qml` is one vertical form inside `BarWidget.qml`'s clipped `Flickable`:
resource selector, explanation, applicable list/task or date-range scope, Refresh,
feedback, records, editor and actions. Full-width controls and wrapped explanations
use available pane width; action `Flow`s wrap. Habit goal and per-check-in fields
share two equal columns with visible labels. Record labels are shortened using a
width estimate, so truncation is not a measured text-fit guarantee. Dates are a
read-only resource with an explicit instruction to manage them in Dida365; current
code adds calendar dates and relative-day labels.

Tab from panel navigation enters the management dropdown's actual trigger. Its `editing` state covers
focused fields, open dropdowns and focus anywhere inside the form, suspending the
panel key catcher. Active-focus changes attempt to scroll the focused control into
view. Escape clears confirmation/form focus and returns keys to the panel. This is
covered by the management interaction acceptance suite, including keyboard activation,
Escape, mouse submission and scrolling focused actions into view.

Resource, list and task changes clear selection/detail state and increment
`Service.managementScope`. Requests carry that scope; responses from an earlier
scope do not replace the pane's results. Submitted writes still report their outcome
and apply authentication/cache effects after a scope change. Matching resource and
selected record ID checks further gate detail updates.
Habit/list saves wait for full detail; bulk selection is limited to 50 tasks in one
list. Partial failures retain failed IDs and expose warnings. Destructive actions
capture their arguments before showing inline Confirm/Cancel controls; authorization
revocation also explains its effect on other tools sharing the token.

`TaskDetail.qml` keeps the inherited inline editor and adds a Comments entry into
management. Due/start and repeat/reminder grids switch from two columns to one below
`Style.space(300)` of local width. Text-field bindings wait until focus leaves before
reapplying task values, and collapsing a detail closes its dropdowns.

## Evidence and limits

The documentation pass inspected `ManagePane.qml`, `Sidebar.qml`, `TaskDetail.qml`,
`QuickAdd.qml`, `TaskRow.qml`, their panel/service integration and the installed shell
controls. It follows impeccable's document guidance to describe observed tokens and
components without inventing palette values or a new visual identity. The launcher
found no `PRODUCT.md` or `DESIGN.md`; the existing QML and explicit preservation brief
provide the scoped extension context.

First-pass captures in `/tmp/opencode/dida-ui-review/` are `manage.png`,
`manage-narrow.png` and `dates.png` (also supplied in the review). They show inherited
typography, bordered fields, sidebar selection and the desktop pane arrangement.
They also show the earlier implementation: a Load action, unlabeled numeric habit
inputs, a raw recurrence field, centered date rows and a partly clipped Manage row.
Current source uses Refresh, labeled habit fields, recurrence presets and left-aligned
record buttons. Those captures therefore cannot establish that the current layout,
focus scrolling or clipping fixes render correctly.

The initial reviewer inspected `/tmp/opencode/dida-ui-verified/`: Dates showed
day distances and management showed labeled fields and recurrence presets, but the
management captures were scrolled and could not verify the complete form. Scope and
destructive-target safety findings were resolved in a final source verdict. The
391-test Python suite (one skipped), 29 model tests, manifest/API validators and real Quickshell
smoke passed. A subsequent acceptance suite, `bash tests/management_ui.sh`, runs
11 Qt interaction cases inside Quickshell with fake account data: keyboard resource
selection, Enter submission, mouse submission, loaded habit details, project/task
reset, priority preservation, assignment username, confirmation/cancellation,
focus scrolling, empty/error/partial-failure states and resource layouts at
420/600/680 logical widths. It fails on missing completion, failed assertions or
unexpected QML diagnostics. Offscreen captures establish layout only; they do not
establish the actual desktop theme. No measured contrast ratio, WCAG certification,
complete screen-reader or all-theme/scale coverage is claimed. API capability coverage is
tracked separately in `API-FEATURES.md`; this document does not certify every Dida
endpoint or live account operation.

The resumed native capture batch at `/tmp/opencode/dida-acceptance-reviewed/`
contains valid management frames at 680 and 600 logical panel widths and a Dates
frame with the correct view. These were opened and checked against the actual
Omarchy theme. The form remains vertically scrollable; interaction tests verify
that its lower action buttons are scrolled into view when focused. The resource
selector is kept synchronized by an explicit Binding after keyboard changes.
The screenshot harness now rejects missing captures and wrong-view captures rather
than reporting a successful batch with skipped frames.

Final independent verdict: **SHIP for the reviewed management UI acceptance scope**.
The reviewer opened all four native frames under
`/tmp/opencode/dida-acceptance-native-final/`: management at 680/600, the scrolled
form bottom with repeat and both actions fully visible, and Dates. The 11 passing
interaction cases also cover deferred/error/mismatched habit details keeping Save
disabled and the actual error Text being visible. No material issue remained in
those named acceptance gaps. This is bounded UI approval, not a live API write audit.
