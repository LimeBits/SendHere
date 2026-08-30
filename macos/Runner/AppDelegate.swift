import Cocoa
import FlutterMacOS

/// Owns the menu bar item. A single strong static reference keeps both the
/// status item and its action target alive for the whole app lifetime; an
/// item created on a short-lived object silently disappears from the menu bar.
final class StatusBarController: NSObject {
  static let shared = StatusBarController()

  private var statusItem: NSStatusItem?
  private(set) weak var mainWindow: NSWindow?

  func remember(window: NSWindow) {
    mainWindow = window
  }

  func install() {
    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = item.button else { return }

    button.image = Self.makeIcon()
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(statusItemClicked)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    button.toolTip = "SendHere · 传到这（左键打开窗口，右键菜单）"

    statusItem = item
  }

  @objc private func statusItemClicked() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      presentMenu()
    } else {
      showMainWindow()
    }
  }

  private func presentMenu() {
    guard let statusItem else { return }
    let menu = NSMenu()
    let open = NSMenuItem(
      title: "打开 SendHere", action: #selector(showMainWindow), keyEquivalent: "")
    let quit = NSMenuItem(title: "退出 SendHere", action: #selector(quitApp), keyEquivalent: "q")
    for menuItem in [open, quit] {
      menuItem.target = self
      menu.addItem(menuItem)
      if menuItem === open { menu.addItem(NSMenuItem.separator()) }
    }

    // Attaching the menu only for this click keeps left-click as a direct
    // window activation rather than a menu toggle.
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc func showMainWindow() {
    // A menu-bar launch restores the regular app policy, which makes the
    // reopened window behave like a normal foreground application again.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let window = mainWindow ?? NSApp.windows.first
    window?.makeKeyAndOrderFront(nil)
    window?.deminiaturize(nil)
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  private static func makeIcon() -> NSImage? {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current else { return nil }
    context.shouldAntialias = true
    // A light rounded-square background restores the recognisable app mark.
    // The transfer symbol is cut out with clear blending, revealing the actual
    // menu-bar behind it rather than using a second, fixed arrow colour.
    // Use the subdued system-control grey instead of pure white so the badge
    // sits with Sonoma's other menu-bar controls rather than looking self-lit.
    NSColor(calibratedWhite: 0.84, alpha: 1).setFill()
    NSBezierPath(
      roundedRect: NSRect(x: 0.6, y: 0.6, width: 14.8, height: 14.8),
      xRadius: 4.1,
      yRadius: 4.1).fill()

    let arrow = NSBezierPath()
    arrow.lineWidth = 1.55
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round

    // One shaft with wide-open arrowheads at its ends.
    // Extend the shaft through both tips to keep all three strokes visually
    // connected at small menu-bar sizes.
    arrow.move(to: NSPoint(x: 3.5, y: 8.0))
    arrow.line(to: NSPoint(x: 12.5, y: 8.0))
    arrow.move(to: NSPoint(x: 5.6, y: 9.9))
    arrow.line(to: NSPoint(x: 3.5, y: 8.0))
    arrow.line(to: NSPoint(x: 5.6, y: 6.1))
    arrow.move(to: NSPoint(x: 10.4, y: 9.9))
    arrow.line(to: NSPoint(x: 12.5, y: 8.0))
    arrow.line(to: NSPoint(x: 10.4, y: 6.1))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.compositingOperation = .clear
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()

    image.isTemplate = false
    return image
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    StatusBarController.shared.install()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(mainWindowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: nil)
  }

  @objc private func mainWindowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          window === StatusBarController.shared.mainWindow else { return }
    // Keep transfers and the menu-bar control alive, but remove SendHere from
    // the Dock after its main window closes, matching VoxHere's behavior.
    DispatchQueue.main.async {
      NSApp.setActivationPolicy(.accessory)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    StatusBarController.shared.showMainWindow()
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
