import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let controller = AppController()
    application.delegate = controller
    application.setActivationPolicy(.regular)
    application.run()
}
