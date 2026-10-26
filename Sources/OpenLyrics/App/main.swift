import AppKit

// `--lookup` prints what the lyrics sources find for a track and exits (see Diagnostics).
Diagnostics.runLookupIfRequested()
Diagnostics.runSnapshotIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
