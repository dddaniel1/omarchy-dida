// Unit tests for qml/Model.js — the presentation helpers the QML binds to.
//
// These are pure, total functions with no Qt in them, which is exactly why they are
// worth testing outside Qt: `tests/qml_smoke.sh` needs a live Wayland session and an
// Omarchy install, so CI cannot run it, and until now nothing checked this file at all.
// A wrong answer here renders as a blank row rather than an error.
//
// Run: node --test tests/
//
// Model.js is loaded rather than `require`d because it opens with QML's `.pragma
// library` directive, which is not JavaScript. Stripping that one line is the whole
// difference between the two runtimes.

const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

function loadModel() {
  const file = path.join(__dirname, "..", "qml", "Model.js")
  const src = fs.readFileSync(file, "utf8").replace(/^\s*\.(?:pragma|import).*$/gm, "")
  // `Qt` is only touched by the colour helpers, which are not under test here.
  const sandbox = { module: { exports: {} }, Qt: {locale: () => ({name:"en_US"})}, I18n: {tr: text => text, isChinese: () => false} }
  vm.runInNewContext(src, sandbox, { filename: file })
  return sandbox.module.exports
}

const Model = loadModel()

// Arrays that come back out of the sandbox have the sandbox's Array prototype, so
// deepStrictEqual would compare prototypes and fail on values that are identical.
const plain = (value) => Array.from(value)

// A stand-in for the array-like a Repeater hands its delegate: indexable, with a
// length, `constructor.name === "Array"` — and `Array.isArray()` false. This is what
// a nested array really looks like after crossing the QVariant boundary, and guarding
// on Array.isArray silently threw away every checklist and every reminder.
function sequence(items) {
  const wrapper = Object.create({ constructor: Array })
  items.forEach((item, i) => { wrapper[i] = item })
  wrapper.length = items.length
  return wrapper
}

test("asList accepts a real array unchanged", () => {
  const list = [1, 2, 3]
  assert.strictEqual(Model.asList(list), list)
})

test("asList unwraps an array-like that fails Array.isArray", () => {
  const wrapped = sequence(["a", "b"])
  assert.strictEqual(Array.isArray(wrapped), false, "the fixture must not be a real array")
  assert.deepStrictEqual(plain(Model.asList(wrapped)), ["a", "b"])
})

test("asList is total", () => {
  for (const value of [undefined, null, 0, 42, true, "abc", {}, { length: "no" }]) {
    assert.deepStrictEqual(plain(Model.asList(value)), [], `for ${JSON.stringify(value)}`)
  }
})

test("reminders render through an array-like, not just an array", () => {
  assert.strictEqual(Model.remindersLabel(sequence(["TRIGGER:-PT30M"])), "30 min before")
  assert.strictEqual(Model.remindersLabel(sequence(["TRIGGER:PT0S", "TRIGGER:-PT1H"])),
                     "At time +1")
  assert.strictEqual(Model.remindersLabel(sequence([])), "")
})

test("reminder offsets read the way a person would say them", () => {
  assert.strictEqual(Model.reminderLabel("TRIGGER:PT0S"), "At time")
  assert.strictEqual(Model.reminderLabel("TRIGGER:-PT60M"), "1 hour before")
  // The all-day form counts from midnight, so the day offset and the clock time are
  // two different facts: -P0DT15H0M0S is 15 hours before midnight, i.e. 09:00 the
  // day before. This is exactly what `--remind 1d` writes for an all-day task.
  assert.strictEqual(Model.reminderLabel("TRIGGER:-P0DT15H0M0S"), "1 day before, 09:00")
  assert.strictEqual(Model.reminderLabel("TRIGGER:-P1DT15H0M0S"), "2 days before, 09:00")
  assert.strictEqual(Model.reminderLabel(""), "")
  assert.strictEqual(Model.reminderLabel("nonsense"), "Reminder")
})

test("repeat rules name only the shapes worth naming", () => {
  assert.strictEqual(Model.repeatLabel("RRULE:FREQ=DAILY"), "Daily")
  assert.strictEqual(Model.repeatLabel("RRULE:FREQ=WEEKLY;INTERVAL=2"), "Every 2 weeks")
  assert.strictEqual(Model.repeatLabel("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"), "Weekdays")
  assert.strictEqual(Model.repeatLabel("ERULE:NAME=CUSTOM"), "Custom")
  assert.strictEqual(Model.repeatLabel(""), "")
})

test("a note is a note however the row spells it", () => {
  assert.strictEqual(Model.isNote({ isNote: true }), true)
  assert.strictEqual(Model.isNote({ kind: "NOTE" }), true)
  assert.strictEqual(Model.isNote({ kind: "note" }), true)
  assert.strictEqual(Model.isNote({ kind: "TEXT" }), false)
  assert.strictEqual(Model.isNote({}), false, "a task with no kind field is a to-do")
  assert.strictEqual(Model.isNote(undefined), false)
})

// The checkbox, the strikethrough and the guard that refuses to "complete" finished
// work all hang off this one answer. An open task reading as done is what the cursor
// used to fake; a done task reading as open re-completes it on Enter.
test("done is read from status or from the completed bucket", () => {
  assert.strictEqual(Model.isDone({ status: 2 }), true)
  assert.strictEqual(Model.isDone({ status: "2" }), true, "a row can arrive stringly typed")
  assert.strictEqual(Model.isDone({ status: 0, bucket: "completed" }), true,
    "the completed endpoint's rows are stamped by the helper, whatever status says")
  assert.strictEqual(Model.isDone({ status: 0, bucket: "today" }), false)
  assert.strictEqual(Model.isDone({}), false, "a row with no status is open")
  assert.strictEqual(Model.isDone(undefined), false)
})

test("sections break on identity and are headed by name", () => {
  const a = { projectId: "p1", project: "Work", bucket: "today" }
  const b = { projectId: "p2", project: "Work", bucket: "today" }
  // Two lists really can share a name; grouping on the name would merge them.
  assert.notStrictEqual(Model.sectionKey(a, "list"), Model.sectionKey(b, "list"))
  assert.strictEqual(Model.sectionLabel(a, "list"), "Work")
  assert.strictEqual(Model.sectionKey(a, "time"), Model.sectionKey(b, "time"))
  assert.strictEqual(Model.sectionLabel(a, "time"), "Today")
  // Sorted by priority or title, any heading would cut across the order asked for.
  assert.strictEqual(Model.sectionKey(a, "priority"), "")
  assert.strictEqual(Model.sectionLabel(a, "title"), "")
  assert.strictEqual(Model.sectionLabel({ projectId: "" }, "list"), "No list")
})

test("tags round-trip through one text field", () => {
  assert.deepStrictEqual(plain(Model.tagList("#work, home")), ["work", "home"])
  assert.deepStrictEqual(plain(Model.tagList("  ##urgent   urgent ")), ["urgent"], "deduped")
  assert.deepStrictEqual(plain(Model.tagList("")), [])
  assert.strictEqual(Model.tagText(["work", "home"]), "#work #home")
  assert.strictEqual(Model.tagText(sequence(["work"])), "#work")
  assert.strictEqual(Model.tagText(undefined), "")
})

test("a date field is seeded with something that cannot drift", () => {
  // Not the human label: re-committing "Mon" would move the task to *next* Monday.
  assert.strictEqual(Model.dateSeed("2026-08-15T09:00:00+02:00", false), "2026-08-15 09:00")
  assert.strictEqual(Model.dateSeed("2026-08-15T00:00:00+02:00", true), "2026-08-15")
  assert.strictEqual(Model.dateSeed("", false), "")
  assert.strictEqual(Model.dateSeed(undefined, false), "")
})

test("checklist progress reads x/y, and nothing when there is no checklist", () => {
  assert.strictEqual(Model.checklistProgress(1, 3), "1/3")
  assert.strictEqual(Model.checklistProgress(0, 0), "")
  assert.strictEqual(Model.checklistProgress(9, 3), "3/3", "clamped, never 9/3")
})

test("every helper survives being handed nothing", () => {
  assert.strictEqual(Model.squish(undefined), "")
  assert.strictEqual(Model.elide(undefined, 10), "")
  assert.strictEqual(Model.toInt("not a number"), 0)
  assert.strictEqual(Model.priorityLabel(undefined), "")
  assert.strictEqual(Model.sectionTitle(undefined), "Tasks")
  assert.strictEqual(Model.parseSummary(undefined), "")
})

// --- habits ----------------------------------------------------------------

test("a habit tally shows progress only where there is progress to show", () => {
  assert.strictEqual(Model.habitTally({ quantified: true, value: 2, goal: 8, unit: "cups" }), "2/8 cups")
  assert.strictEqual(Model.habitTally({ quantified: true, value: 1, goal: 2, unit: "" }), "1/2")
  assert.strictEqual(
    Model.habitTally({ quantified: false, value: 1, goal: 1 }),
    "",
    "a one-click habit says nothing '1/1' would not say worse"
  )
})

test("a habit tally reads whole numbers as whole numbers", () => {
  assert.strictEqual(Model.habitTally({ quantified: true, value: 8.0, goal: 8.0 }), "8/8")
  assert.strictEqual(Model.habitTally({ quantified: true, value: 0.5, goal: 2 }), "0.5/2")
})

test("a streak is only worth showing once it is one", () => {
  assert.strictEqual(Model.habitStreakLabel({ streak: 5 }), "5d")
  assert.strictEqual(Model.habitStreakLabel({ streak: 1 }), "")
  assert.strictEqual(Model.habitStreakLabel({ streak: 0 }), "")
  assert.strictEqual(Model.habitStreakLabel({}), "")
})

test("habit helpers survive being handed nothing", () => {
  assert.strictEqual(Model.habitTally(undefined), "")
  assert.strictEqual(Model.habitStreakLabel(undefined), "")
  assert.strictEqual(Model.trimNumber(undefined), "0")
  assert.strictEqual(Model.trimNumber("nonsense"), "0")
})

// --- the focus countdown ---------------------------------------------------

test("the focus clock counts seconds, and grows an hour field only when it must", () => {
  assert.strictEqual(Model.focusClock(0), "00:00")
  assert.strictEqual(Model.focusClock(59), "00:59")
  assert.strictEqual(Model.focusClock(1500), "25:00")
  assert.strictEqual(Model.focusClock(3600), "1:00:00")
  assert.strictEqual(Model.focusClock(3725), "1:02:05")
})

test("the focus clock never goes negative or reads NaN", () => {
  assert.strictEqual(Model.focusClock(-5), "00:00")
  assert.strictEqual(Model.focusClock(undefined), "00:00")
  assert.strictEqual(Model.focusClock("nonsense"), "00:00")
})

test("remaining is measured from the deadline, which is what survives a reload", () => {
  var now = 1700000000000
  assert.strictEqual(Model.focusRemaining(now + 60000, now), 60)
  assert.strictEqual(Model.focusRemaining(now - 60000, now), 0)
  assert.strictEqual(Model.focusRemaining(0, now), 0, "no deadline is no block")
  assert.strictEqual(Model.focusRemaining(undefined, now), 0)
})

test("a block is settled only once its clock has run out", () => {
  var now = 1700000000000
  assert.strictEqual(Model.focusSettled(now + 1000, now), false)
  assert.strictEqual(Model.focusSettled(now, now), true)
  assert.strictEqual(Model.focusSettled(now - 1, now), true)
  assert.strictEqual(Model.focusSettled(0, now), false, "an idle timer is not settled")
})

test("phase labels are human, including for a phase nobody recognised", () => {
  assert.strictEqual(Model.focusPhaseLabel("focus"), "Focus")
  assert.strictEqual(Model.focusPhaseLabel("shortBreak"), "Short break")
  assert.strictEqual(Model.focusPhaseLabel("longBreak"), "Long break")
  assert.strictEqual(Model.focusPhaseLabel(""), "Focus")
})

test("the tally names its staleness rather than passing it off as live", () => {
  assert.strictEqual(Model.focusTallyLabel({ count: 2, minutes: 25 }), "2 blocks · 25m")
  assert.strictEqual(Model.focusTallyLabel({ count: 1, minutes: 0 }), "1 block")
  assert.strictEqual(Model.focusTallyLabel({ count: 0 }), "0 blocks")
  assert.strictEqual(
    Model.focusTallyLabel({ count: 1, minutes: 25, source: "cache" }),
    "1 block · 25m (cached)"
  )
  assert.strictEqual(Model.focusTallyLabel(undefined), "0 blocks")
})

test("focus settings fall back to the same defaults the helper uses", () => {
  assert.strictEqual(Model.focusPrefsLabel({ focus: 50, shortBreak: 10, longBreak: 30, longInterval: 2 }),
    "50m · 10/30m every 2")
  assert.strictEqual(Model.focusPrefsLabel({}), "25m · 5/15m every 4")
  assert.strictEqual(Model.focusPrefsLabel(undefined), "25m · 5/15m every 4")
})

// --- the bar label ---------------------------------------------------------

test("the bar label keeps tasks and habits apart", () => {
  assert.strictEqual(Model.barLabel(3, 2), "3  2♦")
  assert.strictEqual(Model.barLabel(3, 0), "3")
  assert.strictEqual(Model.barLabel(0, 2), "2♦")
  assert.strictEqual(Model.barLabel(0, 0), "", "nothing due and nothing open is nothing")
})

test("the bar label survives rubbish", () => {
  assert.strictEqual(Model.barLabel(undefined, undefined), "")
  assert.strictEqual(Model.barLabel(-1, -1), "")
  assert.strictEqual(Model.barLabel("2", "1"), "2  1♦")
})

// --- pie slices and palette ------------------------------------------------

test("listColor preserves valid hex colors and falls back to palette", () => {
  assert.strictEqual(Model.listColor("#F18181", 0), "#F18181")
  assert.strictEqual(Model.listColor("#abc", 1), "#abc")
  assert.strictEqual(Model.listColor("", 0), Model.LIST_PALETTE[0])
  assert.strictEqual(Model.listColor(null, 1), Model.LIST_PALETTE[1])
})

test("pieSlices computes slice percentages and angles", () => {
  const items = [
    { name: "Work", count: 3, color: "#F18181" },
    { name: "Home", count: 1, color: "#61BD4F" }
  ]
  const slices = Model.pieSlices(items, 4)
  assert.strictEqual(slices.length, 2)
  assert.strictEqual(slices[0].label, "Work")
  assert.strictEqual(slices[0].percent, 75)
  assert.strictEqual(slices[1].label, "Home")
  assert.strictEqual(slices[1].percent, 25)
  // Total sweep angle should be 2*PI
  assert.strictEqual(slices[0].sweepAngle + slices[1].sweepAngle, Math.PI * 2)
})

test("pieSlices survives empty or missing inputs", () => {
  assert.deepStrictEqual(plain(Model.pieSlices([], 0)), [])
  assert.deepStrictEqual(plain(Model.pieSlices(undefined, 0)), [])
  assert.deepStrictEqual(plain(Model.pieSlices([{ count: 0 }], 0)), [])
})
