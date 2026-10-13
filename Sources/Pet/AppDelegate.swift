import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = PetController()
        controller.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // A small floppy-eared face that stays legible in the menu bar.
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                let leftEar = NSBezierPath()
                leftEar.move(to: CGPoint(x: 5.4, y: 13.6))
                leftEar.curve(to: CGPoint(x: 2.1, y: 6.5), controlPoint1: CGPoint(x: 2.4, y: 14.1), controlPoint2: CGPoint(x: 1.1, y: 8.1))
                leftEar.curve(to: CGPoint(x: 5.2, y: 7.8), controlPoint1: CGPoint(x: 3.2, y: 5.4), controlPoint2: CGPoint(x: 5, y: 6.3))
                leftEar.close()
                let rightEar = NSBezierPath()
                rightEar.move(to: CGPoint(x: 12.6, y: 13.6))
                rightEar.curve(to: CGPoint(x: 15.9, y: 6.5), controlPoint1: CGPoint(x: 15.6, y: 14.1), controlPoint2: CGPoint(x: 16.9, y: 8.1))
                rightEar.curve(to: CGPoint(x: 12.8, y: 7.8), controlPoint1: CGPoint(x: 14.8, y: 5.4), controlPoint2: CGPoint(x: 13, y: 6.3))
                rightEar.close()
                NSColor.black.setFill()
                leftEar.fill(); rightEar.fill()
                let face = NSBezierPath(ovalIn: CGRect(x: 4.2, y: 4.2, width: 9.6, height: 10.7))
                face.lineWidth = 1.5
                NSColor.black.setStroke()
                face.stroke()
                NSBezierPath(ovalIn: CGRect(x: 6.3, y: 10, width: 1.2, height: 1.2)).fill()
                NSBezierPath(ovalIn: CGRect(x: 10.5, y: 10, width: 1.2, height: 1.2)).fill()
                NSBezierPath(ovalIn: CGRect(x: 7.7, y: 7.7, width: 2.6, height: 1.8)).fill()
                let muzzle = NSBezierPath()
                muzzle.lineWidth = 0.9
                muzzle.lineCapStyle = .round
                muzzle.move(to: CGPoint(x: 9, y: 7.7)); muzzle.line(to: CGPoint(x: 9, y: 6.7))
                muzzle.curve(to: CGPoint(x: 7.5, y: 6.1), controlPoint1: CGPoint(x: 8.6, y: 6.2), controlPoint2: CGPoint(x: 8, y: 6.1))
                muzzle.move(to: CGPoint(x: 9, y: 6.7))
                muzzle.curve(to: CGPoint(x: 10.5, y: 6.1), controlPoint1: CGPoint(x: 9.4, y: 6.2), controlPoint2: CGPoint(x: 10, y: 6.1))
                muzzle.stroke()
                return true
            }
            image.isTemplate = true
            button.image = image
            button.toolTip = "Pet — settings, apps and Stash"
        }
        let menu = NSMenu()
        menu.delegate = controller
        statusItem.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.savePosition()
    }

    /// Opening Pet.app again brings up the home/settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showHome()
        return false
    }
}
