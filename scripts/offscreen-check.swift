import AppKit
import Foundation

// This helper never creates an NSApplication or window. It watches only its child PID.
// Usage: offscreen-check APP_EXECUTABLE APP_LOG REPORT_JSON --library TEMP_LIBRARY --snapshot PNG [preview flags]
let arguments = CommandLine.arguments
guard arguments.count >= 8 else {
    fputs("Usage: offscreen-check APP_EXECUTABLE APP_LOG REPORT_JSON --library TEMP_LIBRARY --snapshot PNG [preview flags]\n", stderr)
    exit(2)
}
let childArguments = Array(arguments.dropFirst(4))
func hasValue(_ flag: String) -> Bool {
    guard let index = childArguments.firstIndex(of: flag), index + 1 < childArguments.count else { return false }
    return !childArguments[index + 1].hasPrefix("--")
}
guard hasValue("--snapshot"), hasValue("--library"), !childArguments.contains("--integration-report") else {
    fputs("Only --snapshot launches with an explicit isolated --library are accepted.\n", stderr)
    exit(2)
}

let process = Process()
let logURL = URL(fileURLWithPath: arguments[2])
let reportURL = URL(fileURLWithPath: arguments[3])
var report: [String: Any] = ["passed": false]
var activationEventObserved = false
var frontmostObserved = false
var interruptedSignal: Int32 = 0
var timedOut = false
var signalSources: [DispatchSourceSignal] = []
let started = ProcessInfo.processInfo.systemUptime
let notifications = NSWorkspace.shared.notificationCenter
let observer = notifications.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
    if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
       process.processIdentifier > 0, app.processIdentifier == process.processIdentifier {
        activationEventObserved = true
    }
}

func observeFrontmost() {
    if process.processIdentifier > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier {
        frontmostObserved = true
    }
}

do {
    guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
        throw NSError(domain: "OffscreenCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create app log"])
    }
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }
    process.executableURL = URL(fileURLWithPath: arguments[1])
    process.arguments = childArguments
    process.standardOutput = log
    process.standardError = log
    process.standardInput = FileHandle.nullDevice
    try process.run()
    report["pid"] = process.processIdentifier

    // Install after launch so the child does not inherit ignored termination signals.
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { interruptedSignal = number }
        source.resume()
        signalSources.append(source)
    }

    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while process.isRunning {
        observeFrontmost()
        timedOut = ProcessInfo.processInfo.systemUptime >= deadline
        if timedOut || interruptedSignal != 0 || activationEventObserved || frontmostObserved { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    if process.isRunning {
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
            observeFrontmost()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    // Drain activation events queued immediately before the child exited.
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    observeFrontmost()
    try log.synchronize()

    let output = try String(contentsOf: logURL, encoding: .utf8)
    let pattern = #"^Offscreen snapshot: windows=(\d+), visible=(\d+), active=(true|false), policy=(\d+)\s*$"#
    let expression = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    let matches = expression.matches(in: output, range: range)
    var failures: [String] = []
    if matches.count == 1, let match = matches.first {
        let source = output as NSString
        let windows = Int(source.substring(with: match.range(at: 1)))!
        let visible = Int(source.substring(with: match.range(at: 2)))!
        let active = source.substring(with: match.range(at: 3)) == "true"
        let policy = Int(source.substring(with: match.range(at: 4)))!
        report["internalWindows"] = windows
        report["visibleWindows"] = visible
        report["active"] = active
        report["activationPolicy"] = policy
        // SwiftUI may allocate invisible helper windows. Only visible windows fail.
        if visible != 0 { failures.append("The app reported visible windows") }
        if active { failures.append("The app reported active=true") }
        if policy != 2 { failures.append("The app did not use activation policy prohibited (2)") }
    } else {
        failures.append("Expected exactly one offscreen window-state report in the app log")
    }
    if activationEventObserved { failures.append("NSWorkspace emitted an activation event for the child PID") }
    if frontmostObserved { failures.append("The child PID became the frontmost application") }
    if timedOut { failures.append("Snapshot exceeded 30 seconds") }
    if interruptedSignal != 0 { failures.append("Check interrupted by signal \(interruptedSignal)") }
    if process.terminationStatus != 0 || process.terminationReason != .exit {
        failures.append("Snapshot process did not exit normally with status 0")
    }
    report["exit"] = process.terminationStatus
    report["terminationReason"] = process.terminationReason == .exit ? "exit" : "signal"
    report["failures"] = failures
    report["passed"] = failures.isEmpty
} catch {
    if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    report["failures"] = [error.localizedDescription]
}

notifications.removeObserver(observer)
for source in signalSources { source.cancel() }
report["activationEventObserved"] = activationEventObserved
report["frontmostObserved"] = frontmostObserved
report["activated"] = activationEventObserved || frontmostObserved
report["timedOut"] = timedOut
report["durationSeconds"] = ProcessInfo.processInfo.systemUptime - started
report["appLog"] = logURL.path
do {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: reportURL, options: .atomic)
} catch {
    fputs("Cannot write monitor report: \(error.localizedDescription)\n", stderr)
    exit(2)
}
exit(report["passed"] as? Bool == true ? 0 : 1)
