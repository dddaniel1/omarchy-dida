import QtQuick
import "I18n.js" as I18n
import QtQuick.Window
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

Column {
  id: root
  objectName: "managementPane"
  property var service: null
  property bool datesOnly: false
  property bool contextual: false
  property var contextResources: []
  property var initialSelection: []
  property string contextProject: ""
  property string contextTask: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property string resource: datesOnly ? "countdown" : "habit"
  property string selectedId: ""
  property string selectedTask: ""
  property var selectedIds: []
  property string confirmation: ""
  property var entries: []
  property bool detailReady: false
  property string operationWarning: ""
  property var confirmationArgs: []
  property string selectedDescription: ""
  property bool formFocus: false
  readonly property var resources: [
    {value:"habit", label:I18n.tr("Habits")}, {value:"batch", label:I18n.tr("Tasks in bulk")},
    {value:"tag", label:I18n.tr("Tags")}, {value:"folder", label:I18n.tr("List folders")},
    {value:"project", label:I18n.tr("Lists")}, {value:"column", label:I18n.tr("Board columns")},
    {value:"comment", label:I18n.tr("Task comments")}, {value:"assignment", label:I18n.tr("Task assignment")},
    {value:"focus-record", label:I18n.tr("Focus history")}, {value:"undone", label:I18n.tr("Upcoming tasks")},
    {value:"preference", label:I18n.tr("Account time zone")}, {value:"revoke", label:I18n.tr("Revoke authorization")}
  ]
  readonly property bool scoped: ["batch","column","comment","assignment","project"].indexOf(resource) >= 0
  readonly property var result: service.management.resource === (resource === "assignment" ? "member" : resource)
    ? service.management.result : null
  readonly property var records: entries
  readonly property bool editing: nameField.activeFocus || textField.activeFocus || goalField.activeFocus
    || unitField.activeFocus || repeatField.activeFocus || startField.activeFocus || endField.activeFocus
    || stepField.activeFocus || resourcePicker.popupOpen || projectPicker.popupOpen || taskPicker.popupOpen
    || priorityPicker.popupOpen || typePicker.popupOpen || repeatPicker.popupOpen
    || dueField.activeFocus || colorField.activeFocus || folderPicker.popupOpen || root.formFocus
  activeFocusOnTab: true
  signal returnToPanel()
  Keys.onPressed: function(event) {
    if (datesOnly && (event.key === Qt.Key_R || event.key === Qt.Key_S)
        && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
      if (!service.managementBusy) load()
      event.accepted = true
    }
  }
  Keys.onEscapePressed: { confirmation=""; formFocus=false; returnToPanel() }
  function focusForm() {
    formFocus=true
    if (contextual && resource === "habit") nameField.forceActiveFocus()
    else if (datesOnly || contextual) refreshButton.forceActiveFocus()
    else resourcePicker.nextItemInFocusChain(true).forceActiveFocus()
  }
  function openResource(name, task) {
    resetScope()
    priorityPicker.value="keep";dueField.text=""
    nameField.text="";textField.text="";goalField.text="1";stepField.text="1";unitField.text="";repeatPicker.value="daily"
    resource = name
    if (task) {
      contextProject=String(task.projectId || "")
      contextTask=String(task.id || "")
      projectPicker.value = String(task.projectId || "")
      taskPicker.value = String(task.id || "")
    } else { contextProject=""; contextTask=""; projectPicker.value="";taskPicker.value="" }
    selectedIds = initialSelection.slice()
    if (name === "project" && task && task.projectId) {
      selectedId=String(task.projectId)
      service.manage(["project","get","--project",selectedId])
    }
    Qt.callLater(root.load)
  }
  function resetScope() {
    if (!service) return
    service.managementScope++
    entries=[]; selectedId=""; selectedIds=[]; confirmation=""; detailReady=false; selectedDescription=""
  }
  spacing: Style.spacing.md

  function base(action) {
    var args = [resource, action]
    if (projectPicker.value) args = args.concat(["--project", projectPicker.value])
    if (selectedId) args = args.concat(["--id", selectedId])
    if (taskPicker.value) args = args.concat(["--task", taskPicker.value])
    return args
  }
  function load() {
    confirmation = ""
    if (resource === "revoke") return
    var args = base(resource === "preference" ? "get" : "list")
    if (resource === "assignment") args[0] = "member"
    if (resource === "focus-record" || resource === "undone") {
      args = args.concat(["--start", startField.text, "--end", endField.text])
      if (resource === "focus-record") args = args.concat(["--type", typePicker.value])
    }
    service.manage(args)
  }
  function save(action) {
    if ((resource === "comment" || resource === "assignment") && !validTask()) return
    var args = base(action)
    if (nameField.visible) args = args.concat(["--name", nameField.text.trim()])
    if (resource === "habit") {
      args = args.concat(["--goal", goalField.text, "--step", stepField.text,
                          "--unit", unitField.text])
      if (repeatPicker.value !== "custom") args = args.concat(["--repeat",repeatPicker.value])
    }
    if (resource === "comment" || (resource === "batch" && action === "add"))
      args = args.concat(["--content", textField.text])
    if (resource === "assignment") args = args.concat(["--username", selectedId])
    if (resource === "project") {
      if (colorField.text.trim()) args = args.concat(["--color",colorField.text.trim()])
      if (folderPicker.value !== "keep") args = args.concat(["--group",folderPicker.value])
    }
    if (resource === "batch" && action !== "add") {
      args = args.concat(["--ids", selectedIds.join(",")])
      if (action === "edit") {
        if (priorityPicker.value !== "keep") args = args.concat(["--priority", priorityPicker.value])
        if (dueField.text.trim()) args = args.concat(["--end",dueField.text.trim()])
      }
    }
    service.manage(args)
  }
  function validTask() {
    var tasks = service.tasks || []
    for (var i=0;i<tasks.length;i++) if (tasks[i].id === taskPicker.value && tasks[i].projectId === projectPicker.value) return true
    service.managementError=I18n.tr("Choose a task from the selected list.")
    return false
  }
  function choose(item) {
    selectedId = String(resource === "assignment" ? item.username || "" : item.id || "")
    detailReady = false
    confirmation = ""
    if (resource === "comment") selectedDescription = String(item.title || "")
    nameField.text = String(item.name || item.label || "")
    if (resource === "habit") {
      goalField.text = String(item.goal || 1)
      stepField.text = String(item.step || 1)
      unitField.text = String(item.unit || "")
      repeatField.text = String(item.repeatRule || "RRULE:FREQ=DAILY;INTERVAL=1")
      var rules = {"RRULE:FREQ=DAILY;INTERVAL=1":"daily","RRULE:FREQ=WEEKLY;INTERVAL=1":"weekly","RRULE:FREQ=MONTHLY;INTERVAL=1":"monthly"}
      repeatPicker.value = rules[repeatField.text] || "custom"
      service.manage(["habit", "get", "--id", selectedId])
    }
    if (resource === "focus-record") service.manage(base("get").concat(["--type",typePicker.value]))
    if (resource === "project") {
      var pid = selectedId
      projectPicker.value = pid
      selectedId = pid
      colorField.text = String(item.color || "")
      service.manage(["project","get","--project",pid])
    }
  }
  onResourceChanged: {
    resetScope()
    selectedId = ""; selectedIds = []; confirmation = ""; entries = []; nameField.text = ""
    textField.text = ""; goalField.text = "1"; stepField.text = "1"; unitField.text = ""
    repeatPicker.value = "daily"
    if (contextual && contextProject) {
      projectPicker.value=contextProject
      taskPicker.value=contextTask
    }
    if (["habit","tag","folder","project","preference","countdown"].indexOf(resource) >= 0)
      Qt.callLater(root.load)
  }
  onDatesOnlyChanged: resource = datesOnly ? "countdown" : "habit"
  Connections {
    target: root.service
    function onManagementChanged() {
      var payload = root.service.management
      if (payload.resource !== (root.resource === "assignment" ? "member" : root.resource)) return
      if (payload.action === "list") root.entries = Array.isArray(payload.result) ? payload.result : []
      else if (payload.action === "get" && root.selectedId) {
        var item = payload.result || {}
        if (String(item.id || "") !== root.selectedId) return
        if (root.resource === "habit") {
          nameField.text = String(item.name || "")
          goalField.text = String(item.goal || 1); stepField.text = String(item.step || 1)
          unitField.text = String(item.unit || "")
          var rules = {"RRULE:FREQ=DAILY;INTERVAL=1":"daily","RRULE:FREQ=WEEKLY;INTERVAL=1":"weekly","RRULE:FREQ=MONTHLY;INTERVAL=1":"monthly"}
          repeatPicker.value = rules[item.repeatRule] || "custom"
        }
        if (root.resource === "project") {
          nameField.text = String(item.name || ""); colorField.text = String(item.color || "")
          folderPicker.value = "keep"
        }
        root.detailReady = true
        if (root.resource === "focus-record") root.selectedDescription =
          String(item.startTime || "") + " → " + String(item.endTime || "")
          + "\n" + String(item.note || "")
      }
      else if (payload.action !== "get" && payload.resource !== "revoke") {
        root.operationWarning = String(payload.warning || "")
        var failed = (payload.result || {}).failed || Object.keys((payload.result || {}).id2error || {})
        root.selectedIds = failed; root.selectedId = ""; root.load()
      }
    }
  }
  Component.onCompleted: load()
  Connections {
    target: root.Window.window
    function onActiveFocusItemChanged() {
      if (!root.visible || (root.service.view !== "manage" && root.service.view !== "countdown")) return
      var window = root.Window.window
      var item = window ? window.activeFocusItem : null
      var node = item, inside = false
      while (node) { if (node === root) { inside=true; break }; node=node.parent }
      if (!inside) { root.formFocus=false; return }
      root.formFocus=true
      var flick = root.parent ? root.parent.parent : null
      if (item && flick && flick.contentY !== undefined) {
        var p = item.mapToItem(root,0,0)
        if (p.y < flick.contentY) flick.contentY=p.y
        else if (p.y + item.height > flick.contentY + flick.height)
          flick.contentY=Math.min(Math.max(0,flick.contentHeight-flick.height),p.y+item.height-flick.height)
      }
    }
  }

  Dropdown {
    id: resourcePicker
    objectName: "managementResource"
    visible: !root.datesOnly && (!root.contextual || root.contextResources.length > 1)
    width: parent.width
    label: I18n.tr("Manage")
    showLabel: false
    options: root.contextual ? root.resources.filter(function(r){return root.contextResources.indexOf(r.value)>=0}) : root.resources
    value: root.resource
    foreground: root.foreground
    fontFamily: root.fontFamily
    onChanged: function(value) { root.resource = value }
  }
  Binding { target:resourcePicker; property:"value"; value:root.resource }
  Text {
    width: parent.width
    text: root.datesOnly ? I18n.tr("Important dates from Dida365. Manage these dates in Dida365.")
      : root.resource === "batch" ? I18n.tr("Choose tasks from one list (up to 50), or add one task per line.")
      : root.resource === "revoke" ? I18n.tr("Revoking authorization invalidates this token everywhere it is used, including other tools sharing it.")
      : root.resource === "habit" ? (root.contextual ? I18n.tr("Set a goal and schedule for this habit.") : I18n.tr("Select a habit to edit, or create a new one below."))
      : root.resource === "comment" ? I18n.tr("Keep progress notes with a task.")
      : root.resource === "assignment" ? I18n.tr("Choose a member of the shared list, then assign the task.")
      : I18n.tr("Select an entry to manage it.")
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
  Dropdown {
    id: projectPicker
    objectName: "managementProject"
    visible: root.scoped && !(root.contextual && (root.resource === "comment" || root.resource === "assignment" || root.resource === "batch" || root.resource === "column"))
    width: parent.width
    label: I18n.tr("List")
    options: (root.service.projects || []).map(function(p) { return {value:p.id, label:p.name} })
    foreground: root.foreground
    fontFamily: root.fontFamily
    onChanged: {
      taskPicker.value = ""
      root.resetScope(); nameField.text=""; colorField.text=""; folderPicker.value="keep"
      if (root.resource === "project" && value) { root.selectedId=value; root.service.manage(["project","get","--project",value]) }
    }
  }
  Dropdown {
    id: taskPicker
    objectName: "managementTask"
    visible: !root.contextual && (root.resource === "comment" || root.resource === "assignment")
    width: parent.width
    label: I18n.tr("Task")
    options: (root.service.tasks || []).filter(function(t) { return t.projectId === projectPicker.value }).map(function(t) { return {value:t.id,label:t.title} })
    foreground: root.foreground
    fontFamily: root.fontFamily
    onChanged: root.resetScope()
  }
  Flow {
    visible: root.resource === "focus-record" || root.resource === "undone"
    width: parent.width
    spacing: Style.spacing.sm
    TextField { id:startField; width:parent.width; placeholderText:I18n.tr("Start (ISO date and time)"); text:new Date(Date.now()-7*86400000).toISOString(); foreground:root.foreground; onTextEdited:root.resetScope() }
    TextField { id:endField; width:parent.width; placeholderText:I18n.tr("End (ISO date and time)"); text:new Date().toISOString(); foreground:root.foreground; onTextEdited:root.resetScope() }
    Dropdown { id:typePicker; visible:root.resource === "focus-record"; width:parent.width; options:[{value:"0",label:I18n.tr("Pomodoro")},{value:"1",label:I18n.tr("Stopwatch")}]; value:"0"; foreground:root.foreground; onChanged:root.resetScope() }
  }
  Button {
    id: refreshButton
    objectName: "managementRefresh"
    focusable: true
    visible: root.resource !== "revoke" && !(root.contextual && root.resource === "habit")
    text: root.service.managementBusy ? I18n.tr("Loading…") : I18n.tr("Refresh")
    enabled: !root.service.managementBusy
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.load()
  }
  Text {
    visible: root.operationWarning !== ""
    width:parent.width
    text:root.operationWarning
    wrapMode:Text.WordWrap
    textFormat:Text.PlainText
    color:Color.urgent
    font.family:root.fontFamily
  }
  Text {
    objectName:"managementError"
    visible: root.service.managementError !== ""
    width: parent.width
    text: root.service.managementError
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: root.fontFamily
  }
  Text {
    visible: root.resource === "preference" && root.result !== null
    text: I18n.tr("Account time zone: ") + String((root.result || {}).timeZone || I18n.tr("Unavailable"))
    color: root.foreground
    font.family: root.fontFamily
  }
  Repeater {
    model: root.contextual && root.resource === "habit" ? [] : root.records
    delegate: Button {
      required property var modelData
      width: root.width
      leftAlign: true
      text: root.shortLabel(modelData)
        + (root.resource === "countdown" ? " · " + root.dateLabel(modelData.date) : "")
      selected: root.resource === "batch" ? root.selectedIds.indexOf(modelData.id) >= 0 : root.selectedId === String(root.resource === "assignment" ? modelData.username || "" : modelData.id || "")
      focusable: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: {
        if ((root.resource === "comment" || root.resource === "assignment") && !root.validTask()) return
        if (root.resource === "countdown" || root.resource === "undone") return
        if (root.resource === "batch") {
          var ids = root.selectedIds.slice(), at = ids.indexOf(modelData.id)
          if (at >= 0) ids.splice(at,1); else if (ids.length < 50) ids.push(modelData.id)
          root.selectedIds = ids
        } else root.choose(modelData)
      }
    }
  }
  function shortLabel(item) {
    var title = String(item.name || item.title || item.displayName || item.username || item.startTime || "Untitled")
    var max = Math.max(14, Math.floor(root.width / Style.font.body * 1.6) - 4)
    if (title.length > max) title = title.slice(0,max-1) + "…"
    if (resource === "focus-record") title += " · " + Math.round(Number(item.duration || 0)/60000) + " min"
    if (resource === "undone" && item.dueDate) title += " · " + String(item.dueDate).slice(0,10)
    return title
  }
  Text {
    visible: root.selectedDescription !== ""
    width:parent.width
    text:root.selectedDescription
    textFormat:Text.PlainText
    wrapMode:Text.Wrap
    color:root.foreground
    font.family:root.fontFamily
    font.pixelSize:Style.font.bodySmall
  }
  function dateLabel(stamp) {
    var s = String(stamp || "")
    if (!/^\d{8}$/.test(s)) return "Date unavailable"
    var day = new Date(Number(s.slice(0,4)),Number(s.slice(4,6))-1,Number(s.slice(6,8)))
    var now = new Date()
    var delta = Math.round((Date.UTC(day.getFullYear(),day.getMonth(),day.getDate())
      - Date.UTC(now.getFullYear(),now.getMonth(),now.getDate())) / 86400000)
    return s.slice(0,4) + "-" + s.slice(4,6) + "-" + s.slice(6,8)
      + (delta === 0 ? " · Today" : delta > 0 ? " · In " + delta + " days" : " · " + (-delta) + " days ago")
  }
  Text {
    visible: root.result !== null && root.records.length === 0 && ["countdown","comment","folder","habit","tag","column","focus-record","undone"].indexOf(root.resource) >= 0
    text: I18n.tr("No entries yet.")
    color: root.foreground
    font.family: root.fontFamily
  }
  Text {
    visible: nameField.visible
    text: root.selectedId ? I18n.tr("Edit selected") : I18n.tr("New ") + (root.resource === "habit" ? I18n.tr("habit") : I18n.tr("entry"))
    color: root.foreground
    font.family: root.fontFamily
    font.bold: true
  }
  TextField {
    id: nameField
    objectName: "managementName"
    visible: ["habit","tag","folder","column","project"].indexOf(root.resource) >= 0
    width: parent.width
    placeholderText: I18n.tr("Name")
    foreground: root.foreground
    font.family: root.fontFamily
    maximumLength: 1000
  }
  TextField {
    id:colorField; visible:root.resource === "project"; width:parent.width
    placeholderText:I18n.tr("List color (#RRGGBB)"); foreground:root.foreground
  }
  Dropdown {
    id:folderPicker; visible:root.resource === "project"; width:parent.width; label:I18n.tr("Folder")
    options:[{value:"keep",label:I18n.tr("Keep current folder")}].concat((root.service.groups || []).map(function(g){return {value:g.id,label:g.name}}))
    value:"keep"
    foreground:root.foreground
  }
  Flow {
    visible: root.resource === "habit"
    width: parent.width
    spacing: Style.spacing.sm
    Column {
      width:(parent.width - Style.spacing.sm) / 2
      spacing:Style.spacing.xs
      Text { text:I18n.tr("Goal"); color:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.caption }
      TextField { id:goalField; width:parent.width; text:"1"; placeholderText:I18n.tr("e.g. 8"); foreground:root.foreground }
    }
    Column {
      width:(parent.width - Style.spacing.sm) / 2
      spacing:Style.spacing.xs
      Text { text:I18n.tr("Per check-in"); color:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.caption }
      TextField { id:stepField; width:parent.width; text:"1"; placeholderText:I18n.tr("e.g. 1"); foreground:root.foreground }
    }
    TextField { id:unitField; width:parent.width; placeholderText:I18n.tr("Unit (optional, e.g. glasses)"); foreground:root.foreground }
    TextField { id:repeatField; visible:false; text:"RRULE:FREQ=DAILY;INTERVAL=1" }
    Dropdown {
      id:repeatPicker; width:parent.width; label:I18n.tr("Repeat"); value:"daily"
      options:[{value:"daily",label:I18n.tr("Daily")},{value:"weekly",label:I18n.tr("Weekly")},{value:"monthly",label:I18n.tr("Monthly")},{value:"custom",label:I18n.tr("Keep existing schedule")}]
      foreground:root.foreground
    }
  }
  QQC.TextArea {
    id: textField
    visible: root.resource === "comment" || root.resource === "batch"
    width: parent.width
    height: Style.space(100)
    placeholderText: root.resource === "batch" ? I18n.tr("One new task per line") : I18n.tr("Write a progress note")
    wrapMode: TextEdit.Wrap
    color: root.foreground
    font.family: root.fontFamily
    background: Rectangle { color: Color.background; border.color: root.foreground; border.width: 1; radius: Style.cornerRadius }
  }
  Dropdown {
    id:priorityPicker
    objectName:"managementPriority"
    visible: root.resource === "batch"
    width: parent.width
    label: I18n.tr("Priority for selected tasks")
    options:[{value:"keep",label:I18n.tr("Keep existing priority")},{value:"0",label:I18n.tr("None")},{value:"1",label:I18n.tr("Low")},{value:"3",label:I18n.tr("Medium")},{value:"5",label:I18n.tr("High")}]
    value:"keep"
    foreground:root.foreground
  }
  TextField {
    id:dueField; visible:root.resource === "batch"; width:parent.width
    objectName:"managementDue"
    placeholderText:I18n.tr("Optional due date for selected tasks (e.g. tomorrow)"); foreground:root.foreground
  }
  Flow {
    width: parent.width
    spacing: Style.spacing.sm
    enabled: !root.service.managementBusy
    Button {
      focusable: true
      objectName: "managementCreate"
      visible: ["habit","tag","folder","column","comment","batch"].indexOf(root.resource) >= 0
        && !(root.contextual && root.resource === "habit" && root.selectedId !== "")
      text: root.resource === "comment" ? I18n.tr("Add comment") : root.resource === "batch" ? I18n.tr("Add tasks") : I18n.tr("Create")
      enabled: nameField.visible ? nameField.text.trim() !== "" : textField.text.trim() !== ""
      foreground: root.foreground
      onClicked: root.save("add")
    }
    Button {
      focusable: true
      objectName: "managementSave"
      visible: ["habit","folder","column","project","assignment","batch"].indexOf(root.resource) >= 0
        && !(root.contextual && root.resource === "habit" && root.selectedId === "")
      text: root.resource === "assignment" ? I18n.tr("Assign") : I18n.tr("Save changes")
      enabled: root.resource === "batch" ? root.selectedIds.length > 0
        : root.resource === "project" || root.resource === "habit" ? root.detailReady : root.selectedId !== ""
      foreground: root.foreground
      onClicked: root.save("edit")
    }
    Button {
      focusable: true
      objectName: "managementComplete"
      visible: root.resource === "batch"
      text: I18n.tr("Complete ") + root.selectedIds.length + I18n.tr(" selected")
      enabled: root.selectedIds.length > 0
      foreground: root.foreground
      onClicked: root.save("complete")
    }
    Button {
      focusable: true
      objectName: "managementDelete"
      visible: ["folder","comment","focus-record","assignment","revoke"].indexOf(root.resource) >= 0
      text: root.resource === "revoke" ? I18n.tr("Revoke authorization…") : root.resource === "assignment" ? I18n.tr("Remove assignee…") : I18n.tr("Delete selected…")
      enabled: root.resource === "revoke" || (root.resource === "assignment" ? !!taskPicker.value && !!projectPicker.value : root.selectedId !== "")
      foreground: Color.urgent
      onClicked: {
        root.confirmation = root.resource === "revoke" ? "revoke" : "delete"
        if ((root.resource === "comment" || root.resource === "assignment") && !root.validTask()) { root.confirmation=""; return }
        root.confirmationArgs = root.base(root.confirmation).concat(["--yes"])
        if (root.resource === "focus-record") root.confirmationArgs = root.confirmationArgs.concat(["--type",typePicker.value])
      }
    }
    Button { focusable:true; visible:root.selectedId !== ""; text:I18n.tr("Cancel edit"); foreground:root.foreground; onClicked:{root.selectedId="";root.detailReady=false;nameField.text=""} }
  }
  Flow {
    visible: root.confirmation !== ""
    width: parent.width
    spacing: Style.spacing.sm
    Text { width:parent.width; text:I18n.tr("This action cannot be undone. Continue?"); wrapMode:Text.WordWrap; color:Color.urgent; font.family:root.fontFamily }
    Button {
      focusable: true
      objectName: "managementConfirm"
      text:I18n.tr("Confirm"); foreground:Color.urgent; enabled:!root.service.managementBusy
      onClicked: {
        root.service.manage(root.confirmationArgs); root.confirmation=""
      }
    }
    Button { focusable:true; text:I18n.tr("Cancel"); foreground:root.foreground; onClicked:root.confirmation="" }
  }
}
