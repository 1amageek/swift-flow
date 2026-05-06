import Foundation

enum LiveNodeDebugLog {
    private static let startUptime = ProcessInfo.processInfo.systemUptime

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startUptime)
        let timestamp = String(format: "+%.3fs", elapsed)
        print("[SwiftFlow.LiveNode \(timestamp)] \(message())")
        #endif
    }
}
