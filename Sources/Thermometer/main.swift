import AppKit
import Foundation

if CommandLine.arguments.contains("--diagnostics") {
    let reader = HardwareSensorReader()
    let snapshot = reader.sample()
    print("Thermometer diagnostics")
    print("CPU: \(snapshot.cpuC.map { String(format: "%.2f °C", $0) } ?? "unavailable")")
    print("GPU: \(snapshot.gpuC.map { String(format: "%.2f °C", $0) } ?? "unavailable")")
    print("Storage: \(snapshot.storageC.map { String(format: "%.2f °C", $0) } ?? "unavailable")")
    print("Battery: \(snapshot.batteryC.map { String(format: "%.2f °C", $0) } ?? "unavailable")")
    if snapshot.fans.isEmpty {
        print("Fans: unavailable")
    } else {
        for fan in snapshot.fans {
            print("Fan \(fan.index): \(Int(fan.rpm.rounded())) RPM")
        }
    }
    print("Sources: \(snapshot.sourceSummary)")
    reader.diagnosticLines().forEach { print("- \($0)") }
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
