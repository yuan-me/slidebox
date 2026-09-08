import AppKit

if CommandLine.arguments.contains("--self-test") {
    do { try runChecks() } catch { fputs("Self-check failed: \(error)\n", stderr); exit(1) }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.run()
    }
}
