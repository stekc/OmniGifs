import AppKit

@main
@MainActor
enum OmniGifsMain {
    static func main() {
        if CommandLine.arguments.contains("--omnigifs-text-embedding-worker") {
            TextEmbeddingWorkerRuntime.run()
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
