import QtQuick
import QtTest
import qs.Commons
import "plugin" as Plugin

Item {
  id: root
  width: 260
  height: 620
  Rectangle { anchors.fill: parent; color: Color.background }
  QtObject {
    id: backend
    property string view: "today"
    property string projectFilter: ""
    property string search: ""
    property var counts: ({today:3,overdue:2,total:8,upcoming:4})
    property var projects: [{id:"inbox123",name:"Inbox",count:3},
      {id:"personal",name:"Personal",count:3},
      {id:"work",name:"University work",groupId:"school",count:1}]
    property var groups: [{id:"school",name:"University"}]
    property int habitBadge: 2
    property int countdownCount: 3
    property bool showFocus: true
    property bool authed: true
    property bool focusActive: false
    property bool focusRunning: false
    property bool focusPaused: false
    property bool focusTiming: false
    property var focusState: ({})
    property string focusClockText: "25:00"
    property int focusBlocksDone: 0
    property var focusTally: ({})
  }
  Plugin.Sidebar {
    id: sidebar
    anchors.fill: parent
    anchors.margins: 12
    service: backend
    onViewSelected: function(value) { backend.view=value }
    onProjectSelected: function(id) { backend.view="project"; backend.projectFilter=id }
  }
  SignalSpy { id: organizeSpy; target:sidebar; signalName:"organizeRequested" }
  SignalSpy { id: historySpy; target:sidebar; signalName:"focusHistoryRequested" }
  Plugin.DatePicker { id: calendar; parent: root }
  Plugin.TaskDetail {
    id: detail
    width: root.width
    visible: false
    task: ({id:"t",projectId:"p",dueIso:"2026-12-31T17:45:00+0800",startIso:"2026-12-30T09:15:00+0800"})
  }
  SignalSpy { id: dueSpy; target:detail; signalName:"dueRequested" }
  SignalSpy { id: startSpy; target:detail; signalName:"startRequested" }
  SignalSpy { id: dateSpy; target:calendar; signalName:"dateSelected" }
  TestCase {
    id: acceptance
    name: "SidebarAcceptance"
    when: false
    function index(key) { return sidebar.navItems.findIndex(function(item) { return item.key===key }) }
    function choose(key) { var at=index(key); verify(at>=0,key); sidebar.activateAt(at) }
    function control(name) { var item=findChild(sidebar,name); verify(item!==null,name); return item }
    function test_navigation() {
      calendar.seed="2026-12-31 17:45"; calendar.open(); wait(20)
      compare(calendar.selectedDate.getMonth(),11)
      calendar.moveMonth(1); compare(calendar.displayedMonth.getFullYear(),2027)
      calendar.choose(new Date(2027,0,2)); compare(dateSpy.signalArguments[0][0],"2027-01-02 17:45")
      calendar.seed=""; calendar.open(); wait(20)
      calendar.choose(new Date(2026,1,3)); compare(dateSpy.signalArguments[1][0],"2026-02-03")
      calendar.open(); wait(20); keyClick(Qt.Key_Escape); wait(20)
      compare(calendar.opened,false); compare(dateSpy.count,2)
      detail.visible=true
      var dueButton=findChild(detail,"taskDueCalendar"), startButton=findChild(detail,"taskStartCalendar")
      verify(dueButton!==null && startButton!==null)
      dueButton.clicked(); wait(20); verify(detail.editing)
      var duePicker=findChild(detail,"taskDuePicker")
      duePicker.choose(new Date(2027,0,2))
      compare(dueSpy.signalArguments[0][0],"2027-01-02 17:45")
      startButton.clicked(); wait(20)
      findChild(detail,"taskStartPicker").choose(new Date(2027,0,1))
      compare(startSpy.signalArguments[0][0],"2027-01-01 09:15")
      detail.visible=false
      compare(sidebar.viewOrder.slice(0,4).map(function(v){return v.value}).join(","),"today,inbox,next,all")
      compare(index("v:tomorrow"),-1)
      verify(index("v:completed")>=0)
      compare(index("more"),-1)
      compare(index("lists"),-1)
      compare(index("v:habits"),-1)
      compare(index("v:stats"),-1)
      compare(sidebar.navItems.filter(function(item){return item.id==="inbox123"}).length,0)
      choose("v:completed"); compare(backend.view,"completed")
      choose("tools"); choose("v:habits"); compare(backend.view,"habits")
      choose("v:countdown"); compare(backend.view,"countdown")
      compare(sidebar.navItems[index("v:countdown")].count,3)
      choose("tools"); compare(index("v:habits"),-1)
      backend.view="habits"; verify(index("v:habits")>=0)
      choose("tools")
      choose("h:school"); compare(index("p:work"),-1)
      choose("h:school"); verify(index("p:work")>=0)
      verify(index("p:personal")>=0)
      choose("p:work"); compare(backend.projectFilter,"work")
      var search=control("sidebarSearch"), icon=control("sidebarSearchIcon")
      compare(icon.parent,search)
      verify(search.leftPadding>icon.x+icon.width)
      control("sidebarFocusMore").clicked()
      control("sidebarFocusHistory").chosen(); compare(historySpy.count,1)
      control("sidebarStats").chosen(); compare(backend.view,"stats")
      backend.showFocus=false; backend.view="today"; backend.view="stats"
      verify(index("v:stats")>=0)
      backend.showFocus=true; backend.view="today"
      choose("tools")
      sidebar.cursorIndex=-1; sidebar.moveCursor(1)
      compare(sidebar.navItems[sidebar.cursorIndex].value,"today")
      for (var i=0;i<sidebar.navItems.length;i++) {
        sidebar.moveCursor(1)
        verify(sidebar.navItems[sidebar.cursorIndex].kind!=="header")
      }
      sidebar.activateAt(0); compare(backend.view,"today")
      control("sidebarFocusMore").clicked()
    }
  }
  Timer {
    interval: 200
    running: true
    onTriggered: {
      try { acceptance.test_navigation(); console.log("ACCEPTANCE PASS grouped navigation") }
      catch (error) { console.error("ACCEPTANCE FAIL " + error); Qt.callLater(Qt.quit); return }
      calendar.seed="2026-12-31 17:45"; calendar.open()
      calendar.contentItem.grabToImage(function(image) {
        image.saveToFile(Qt.resolvedUrl("captures/calendar.png").toString().replace("file://",""))
      })
      sidebar.grabToImage(function(image) {
        image.saveToFile(Qt.resolvedUrl("captures/sidebar.png").toString().replace("file://",""))
        console.log("ACCEPTANCE COMPLETE"); Qt.callLater(Qt.quit)
      })
    }
  }
}
