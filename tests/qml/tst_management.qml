import QtQuick
import "plugin/I18n.js" as I18n
import QtTest
import qs.Commons
import "plugin" as Plugin

Item {
  width: 680
  height: 420
  Rectangle { anchors.fill:parent; color:Color.background }
  QtObject {
    id: backend
    property string view: "manage"
    property int managementScope: 0
    property bool managementBusy: false
    property string managementError: ""
    property var management: ({})
    property var calls: []
    property bool deferDetails: false
    property var projects: [{id:"p",name:"Personal"},{id:"q",name:"Work"}]
    property var groups: [{id:"g",name:"Life"}]
    property var tasks: [{id:"t",projectId:"p",title:"Read"}]
    function manage(args) {
      calls = calls.concat([args])
      var resource=args[0], action=args[1], result={}
      if (deferDetails && resource === "habit" && action === "get") return
      if (action === "list") {
        if (resource === "habit") result=[{id:"h",name:"Drink water",goal:8,step:1,unit:"glasses",repeatRule:"RRULE:FREQ=DAILY;INTERVAL=1"}]
        else if (resource === "countdown") result=[{id:"d",name:"Trip to Kyoto",date:20261112}]
        else if (resource === "comment") result=[{id:"c",title:"A long progress note that wraps naturally and remains readable when selected."}]
        else if (resource === "batch") result=tasks
        else if (resource === "member") result=[{id:"account-id",username:"me@example.com",displayName:"Me"}]
        else if (resource === "focus-record") result=[{id:"f",startTime:"2026-10-16T09:00:00+0800",duration:1500000}]
        else result=[{id:"entry",name:"Personal"}]
      } else if (action === "get") {
        result=resource === "habit" ? {id:"h",name:"Drink water",goal:8,step:1,unit:"glasses",repeatRule:"RRULE:FREQ=DAILY;INTERVAL=1"}
          : resource === "preference" ? {timeZone:"Asia/Shanghai"} : {id:"p",name:"Personal",color:"#8AADF4"}
      }
      management={ok:true,resource:resource,action:action,result:result,warning:""}
    }
  }
  Flickable {
    id: flick
    anchors.fill:parent
    anchors.margins:16
    clip:true
    contentWidth:width
    contentHeight:pane.implicitHeight
    Plugin.ManagePane { id:pane; width:flick.width; service:backend }
  }
  TestCase {
    id: acceptance
    name:"ManagementAcceptance"
    when:false
    Component.onCompleted: console.log("ACCEPTANCE test case ready")
    function control(name) { var item=findChild(pane,name); verify(item !== null,name); return item }
    function test_countdown_refresh_shortcuts() {
      pane.datesOnly=true; backend.view="countdown"; pane.resource="countdown"
      wait(20)
      control("managementRefresh").forceActiveFocus()
      var keys=[Qt.Key_R, Qt.Key_S]
      for (var i=0; i<keys.length; i++) {
        backend.calls=[]
        keyClick(keys[i])
        compare(backend.calls.length,1)
        compare(backend.calls[0][0],"countdown")
        compare(backend.calls[0][1],"list")
      }
    }
    function init() {
      pane.datesOnly=false; backend.view="manage"; pane.resource="habit"; pane.selectedId=""
      backend.calls=[]; backend.managementError=""; pane.operationWarning=""; flick.contentY=0
      backend.deferDetails=false
      backend.managementBusy=false; pane.resetHabit()
      pane.contextual=false;pane.contextResources=[];pane.initialSelection=[]
      wait(20)
    }
    function test_keyboard_resource_picker() {
      pane.focusForm()
      keyClick(Qt.Key_Return)
      tryCompare(control("managementResource"),"popupOpen",true)
      keyClick(Qt.Key_Down)
      keyClick(Qt.Key_Return)
      tryCompare(pane,"resource","batch")
      keyClick(Qt.Key_Escape)
      compare(pane.formFocus,false)
    }
    function test_create_from_keyboard() {
      var name=control("managementName")
      name.forceActiveFocus(); name.text="Read every day"
      var create=control("managementCreate")
      verify(create.enabled)
      create.forceActiveFocus(); keyClick(Qt.Key_Return)
      var calls=backend.calls.filter(function(c){return c[0]==="habit" && c[1]==="add"})
      compare(calls.length,1)
      verify(calls[0].indexOf("Read every day")>=0)
    }
    function test_habit_detail_gate() {
      backend.deferDetails=true
      pane.choose({id:"h",name:"Incomplete"})
      compare(pane.detailReady,false)
      verify(!control("managementSave").enabled)
      backend.managementError="Details unavailable. Refresh to retry."
      verify(!control("managementSave").enabled)
      backend.management={resource:"habit",action:"get",result:{id:"other",name:"Wrong habit"}}
      compare(pane.detailReady,false)
      verify(!control("managementSave").enabled)
      backend.deferDetails=false
      backend.manage(["habit","get","--id","h"])
      compare(pane.detailReady,true)
      compare(control("managementName").text,"Drink water")
      verify(control("managementSave").enabled)
      pane.save("edit")
      var sent=backend.calls.filter(function(c){return c[1]==="edit"})[0]
      compare(sent[sent.indexOf("--goal")+1],"8")
    }
    function test_habit_simple_enter_and_success() {
      pane.contextual=true; pane.openResource("habit",null); wait(20)
      var name=control("managementName")
      compare(control("habitMode").value,"complete")
      verify(!control("habitGoal").visible)
      name.text="早睡"; name.forceActiveFocus(); keyClick(Qt.Key_Return)
      var sent=backend.calls.filter(function(c){return c[1]==="add"})[0]
      compare(sent[sent.indexOf("--goal")+1],"1")
      compare(sent[sent.indexOf("--step")+1],"1")
      compare(name.text,"")
      compare(control("habitNotice").text,I18n.tr("Habit added"))
    }
    function test_habit_quantity_validation_and_retry() {
      pane.contextual=true; pane.openResource("habit",null); wait(20)
      var quantity=control("habitQuantityMode")
      verify(quantity.visible)
      verify(control("habitCompleteMode").visible)
      quantity.forceActiveFocus(); keyClick(Qt.Key_Return)
      compare(control("habitMode").value,"quantity")
      verify(control("habitGoal").visible)
      control("managementName").text="喝水"
      control("habitGoal").text="0"
      verify(!control("managementCreate").enabled)
      var before=backend.calls.length
      pane.save("add"); compare(backend.calls.length,before)
      control("habitGoal").text="8"; control("habitStep").text=""
      verify(!control("managementCreate").enabled)
      control("habitStep").text="0.5"; control("habitUnit").text="杯"
      verify(control("managementCreate").enabled)
      backend.managementBusy=true
      pane.save("add"); compare(backend.calls.length,before)
      backend.managementError="Try again"
      backend.managementBusy=false
      compare(control("managementName").text,"喝水")
      compare(control("habitGoal").text,"8")
      pane.save("add")
      var sent=backend.calls.filter(function(c){return c[1]==="add"})[0]
      compare(sent[sent.indexOf("--step")+1],"0.5")
      compare(sent[sent.indexOf("--unit")+1],"杯")
      compare(control("habitMode").value,"complete")
    }
    function test_habit_custom_schedule_preserved_and_cancel_resets() {
      backend.deferDetails=true
      pane.choose({id:"h",name:"Read"})
      backend.management={resource:"habit",action:"get",result:{id:"h",name:"Read",goal:20,step:5,unit:"pages",repeatRule:"RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"}}
      compare(control("habitMode").value,"quantity")
      pane.save("edit")
      var sent=backend.calls.filter(function(c){return c[1]==="edit"})[0]
      compare(sent.indexOf("--repeat"),-1)
      pane.choose({id:"h",name:"Water",goal:8,unit:"cups"})
      control("managementCancel").clicked()
      compare(control("habitMode").value,"complete")
      compare(control("habitGoal").text,"1")
      compare(control("habitUnit").text,"")
    }
    function test_project_switch_clears_task_and_confirmation() {
      pane.openResource("comment",backend.tasks[0]); wait(20)
      compare(control("managementTask").value,"t")
      pane.choose({id:"c",title:"Progress"})
      var del=control("managementDelete")
      del.clicked(); verify(pane.confirmation!=="")
      var project=control("managementProject")
      project.value="q"; project.changed("q")
      compare(control("managementTask").value,"")
      compare(pane.selectedId,""); compare(pane.confirmation,"")
      pane.save("add")
      compare(backend.managementError,I18n.tr("Choose a task from the selected list."))
    }
    function test_bulk_date_does_not_clear_priority() {
      pane.openResource("batch",backend.tasks[0]); wait(20)
      pane.selectedIds=["t"]
      pane.save("edit")
      var sent=backend.calls[backend.calls.length-1]
      compare(sent.indexOf("--priority"),-1)
    }
    function test_assignment_uses_username() {
      pane.openResource("assignment",backend.tasks[0]); wait(20)
      pane.choose({id:"wrong-id",username:"me@example.com"})
      pane.save("edit")
      var sent=backend.calls[backend.calls.length-1]
      compare(sent[sent.indexOf("--username")+1],"me@example.com")
    }
    function test_confirmation_cancel_and_keyboard_confirm() {
      pane.openResource("comment",backend.tasks[0]); wait(20)
      pane.choose({id:"c",title:"Progress"})
      control("managementDelete").clicked()
      verify(pane.confirmation!=="")
      var before=backend.calls.length
      pane.forceActiveFocus(); keyClick(Qt.Key_Escape)
      compare(pane.confirmation,""); compare(backend.calls.length,before)
      control("managementDelete").clicked()
      control("managementConfirm").forceActiveFocus(); keyClick(Qt.Key_Return)
      var sent=backend.calls.filter(function(c){return c[0]==="comment" && c[1]==="delete"})[0]
      verify(sent.indexOf("--yes")>=0)
      compare(sent[sent.indexOf("--id")+1],"c")
    }
    function test_focus_scrolls_action_into_view() {
      flick.anchors.fill=undefined
      flick.height=160
      pane.resource="habit"; pane.load(); wait(20)
      control("managementName").text="Read"
      control("managementCreate").forceActiveFocus(); wait(20)
      verify(flick.contentY>0)
      var pos=control("managementCreate").mapToItem(flick.contentItem,0,0)
      verify(pos.y+control("managementCreate").height<=flick.contentY+flick.height+1)
      flick.height=388
    }
    function test_empty_error_partial_failure() {
      pane.resource="batch"
      backend.management={resource:"batch",action:"list",result:[]}
      compare(pane.records.length,0)
      backend.managementError="Connection unavailable. Refresh to retry."
      var error=control("managementError")
      verify(error.visible)
      compare(error.text,backend.managementError)
      backend.management={resource:"batch",action:"edit",result:{id2error:{t:"NO_PROJECT_PERMISSION"}},warning:"One task failed"}
      compare(pane.selectedIds.length,1)
      compare(pane.selectedIds[0],"t")
      compare(pane.operationWarning,"One task failed")
    }
    function test_all_resources_and_widths() {
      for (var width of [680,600,420]) {
        flick.anchors.fill=undefined; flick.width=width-32; flick.height=388
        for (var entry of pane.resources) {
          pane.resource=entry.value; wait(10)
          verify(pane.width<=flick.width)
          verify(isFinite(pane.implicitHeight))
          verify(pane.implicitHeight>0)
          compare(control("managementResource").value,entry.value)
        }
      }
    }
    function test_mouse_select_and_create() {
      pane.resource="habit"; pane.load()
      var field=control("managementName")
      mouseClick(field,10,10); verify(field.activeFocus)
      field.text="Walk outside"
      var button=control("managementCreate")
      flick.contentY=Math.max(0,flick.contentHeight-flick.height); wait(20)
      mouseClick(button,button.width/2,button.height/2)
      verify(backend.calls.some(function(c){return c[0]==="habit" && c[1]==="add" && c.indexOf("Walk outside")>=0}))
    }
    function test_contextual_entry_hides_global_selector() {
      pane.contextual=true;pane.contextResources=["comment"]
      pane.openResource("comment",backend.tasks[0]);wait(20)
      verify(!control("managementResource").visible)
      verify(!control("managementProject").visible)
      verify(!control("managementTask").visible)
      compare(control("managementProject").value,"p")
      compare(control("managementTask").value,"t")
      pane.initialSelection=["t"];pane.contextResources=["batch"]
      pane.openResource("batch",backend.tasks[0]);wait(20)
      compare(pane.selectedIds[0],"t")
      control("managementPriority").value="5";control("managementDue").text="tomorrow"
      pane.openResource("batch",backend.tasks[0])
      compare(control("managementPriority").value,"keep")
      compare(control("managementDue").text,"")
      pane.contextResources=["habit"]
      pane.openResource("habit",null);pane.choose({id:"h",name:"Water"})
      verify(pane.selectedId!=="")
      pane.openResource("habit",null)
      compare(pane.selectedId,"");compare(pane.detailReady,false)
      compare(control("managementName").text,"")
    }
  }
  Timer {
    interval:200; running:true
    onTriggered: {
      var tests=["test_countdown_refresh_shortcuts","test_keyboard_resource_picker","test_create_from_keyboard","test_habit_detail_gate",
        "test_habit_simple_enter_and_success","test_habit_quantity_validation_and_retry","test_habit_custom_schedule_preserved_and_cancel_resets",
        "test_project_switch_clears_task_and_confirmation","test_bulk_date_does_not_clear_priority",
        "test_assignment_uses_username","test_confirmation_cancel_and_keyboard_confirm",
        "test_focus_scrolls_action_into_view","test_empty_error_partial_failure","test_all_resources_and_widths",
        "test_mouse_select_and_create","test_contextual_entry_hides_global_selector"]
      for (var name of tests) {
        try { acceptance.init(); acceptance[name](); console.log("ACCEPTANCE PASS " + name) }
        catch(e) { console.error("ACCEPTANCE FAIL " + name + ": " + e); Qt.callLater(Qt.quit); return }
      }
      captureStep.running=true
    }
  }
  Timer {
    id:captureStep
    property int step:0
    readonly property var names:["manage-680-top","manage-680-bottom","manage-600-top","manage-600-bottom","dates","habit-420-simple","habit-420-quantity","habit-680-quantity"]
    interval:150
    onTriggered: {
      if (step>=names.length) { console.log("ACCEPTANCE COMPLETE"); Qt.callLater(Qt.quit); return }
      flick.anchors.fill=undefined; flick.width=(step<2 || step===7 ? 680 : step>=5 ? 420 : 600)-32; flick.height=388
      pane.datesOnly=step===4; backend.view=step===4?"countdown":"manage"
      pane.resource=step===4?"countdown":"habit"; pane.load()
      if (step>=5) {
        pane.contextual=true; pane.openResource("habit",null)
        acceptance.control("managementName").text=step===5 ? I18n.tr("Go to bed early") : I18n.tr("Drink water")
        if (step>=6) {
          acceptance.control("habitMode").value="quantity"
          acceptance.control("habitGoal").text="8"
          acceptance.control("habitUnit").text=I18n.tr("glasses")
        }
      }
      Qt.callLater(function(){
        flick.contentY=step<5 && step%2===1?Math.max(0,flick.contentHeight-flick.height):0
        captureReady.restart()
      })
    }
  }
  Timer {
    id:captureReady; interval:100
    onTriggered: {
      flick.grabToImage(function(image){
        var path=Qt.resolvedUrl("captures/"+captureStep.names[captureStep.step]+".png").toString().replace("file://","")
        if (!image.saveToFile(path)) { console.error("ACCEPTANCE FAIL capture"); Qt.callLater(Qt.quit); return }
        console.log("ACCEPTANCE CAPTURE "+captureStep.names[captureStep.step]); captureStep.step++; captureStep.restart()
      })
    }
  }
}
