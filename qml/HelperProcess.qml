import QtQuick
import Quickshell.Io

// Every helper call that can carry user content goes through this process.
//
// The command line is always `python3 <helper> request`; the real argv travels as
// JSON on stdin. Task titles, notes, search terms and account-management form
// values must never be visible in `/proc/<pid>/cmdline`, which is readable by
// other local users while the helper runs.
Process {
  id: root

  property string helperPath: ""
  property var requestArgs: []
  property var lastArgs: []

  stdinEnabled: true

  function startRequest(args) {
    if (running) return false
    lastArgs = args.slice()
    requestArgs = args.slice()
    command = ["python3", helperPath, "request"]
    // A previous process may have closed stdin in onStarted; each start needs
    // its own writable pipe.
    stdinEnabled = true
    running = true
    return true
  }

  onStarted: {
    write(JSON.stringify({argv: requestArgs}) + "\n")
    requestArgs = []
    // Closing stdin is what lets the helper's json.load() return instead of
    // waiting for a writer that will never come back.
    stdinEnabled = false
  }
}
