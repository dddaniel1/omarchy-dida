const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")
const path = require("node:path")

function load(locale) {
  const context = {module:{exports:{}}, Qt:{locale:() => ({name:locale})}}
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,"../qml/I18n.js"),"utf8").replace(/^\.pragma.*$/m,""),context)
  return context
}
test("Chinese locales translate UI while other locales fall back to English", () => {
  for (const locale of ["zh_CN","zh_TW","zh-Hans-CN"]) {
    const i = load(locale)
    assert.equal(i.tr("Today"),"今天")
    assert.equal(i.tr("This action cannot be undone. Continue?"),"此操作无法撤销，是否继续？")
    assert.equal(i.tr("User task title"),"User task title")
    assert.equal(i.dateLabel("tomorrow 15:00"),"明天 15:00")
  }
  for (const locale of ["en_US","de_DE","C"]) assert.equal(load(locale).tr("Today"),"Today")
})
test("Chinese presentation retains recurrence and reminder meaning", () => {
  const context=load("zh_CN")
  context.I18n={tr:context.tr,isChinese:context.isChinese}
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,"../qml/Model.js"),"utf8").replace(/^\.(?:pragma|import).*$/gm,""),context)
  assert.equal(context.repeatLabel("RRULE:FREQ=WEEKLY;INTERVAL=2"),"每 2 周")
  assert.equal(context.reminderLabel("TRIGGER:-PT60M"),"提前 1 小时")
  assert.equal(context.focusPhaseLabel("shortBreak"),"短休息")
})
