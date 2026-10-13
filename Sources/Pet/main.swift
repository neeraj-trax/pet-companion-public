import AppKit

// Hidden helper used by build-app.sh to render the app icon from the pet itself.
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    IconRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-poses"), i + 1 < CommandLine.arguments.count {
    IconRenderer.renderPoses(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-ring-live"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    RingPreview.renderLive(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-ring-appear"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    RingPreview.renderAppear(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-ring-corners"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    RingPreview.renderCorners(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-stash"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    StashPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-home"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    HomePreview.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-bed"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    DogBedPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-bed-empty"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    DogBedPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), occupied: false)
    exit(0)
}

if CommandLine.arguments.contains("--snapshot") {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("in.vellabs.pet.snapshot"), object: nil, userInfo: nil, deliverImmediately: true)
    print("asked the running Pet to write \(NSTemporaryDirectory())pet-debug/")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, lives in the menu bar

if CommandLine.arguments.contains("--selftest") {
    let controller = PetController()
    controller.start()
    exit(controller.selfTest() ? 0 : 1)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
