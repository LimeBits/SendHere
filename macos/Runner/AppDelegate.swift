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
      title: "打开 SendHere 窗口", action: #selector(showMainWindow), keyEquivalent: "")
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
    // Status-bar artwork follows Apple's template-image convention: macOS
    // supplies the correct light/dark tint. The mark mirrors the web icon:
    // a rounded square containing two separate, opposing horizontal arrows.
    NSColor.labelColor.setStroke()
    let body = NSBezierPath(
      roundedRect: NSRect(x: 1.1, y: 1.1, width: 13.8, height: 13.8),
      xRadius: 3.8,
      yRadius: 3.8)
    body.lineWidth = 1.35
    body.stroke()

    let arrows = NSBezierPath()
    arrows.lineWidth = 1.65
    arrows.lineCapStyle = .round
    arrows.lineJoinStyle = .round

    // Top lane: transfer to the right.
    arrows.move(to: NSPoint(x: 4.1, y: 9.7))
    arrows.line(to: NSPoint(x: 11.9, y: 9.7))
    arrows.move(to: NSPoint(x: 9.7, y: 11.8))
    arrows.line(to: NSPoint(x: 12.0, y: 9.7))
    arrows.line(to: NSPoint(x: 9.7, y: 7.6))

    // Bottom lane: transfer to the left. Keep it visibly separate from the
    // upper arrow rather than merging them into a single bidirectional line.
    arrows.move(to: NSPoint(x: 11.9, y: 6.3))
    arrows.line(to: NSPoint(x: 4.1, y: 6.3))
    arrows.move(to: NSPoint(x: 6.3, y: 8.4))
    arrows.line(to: NSPoint(x: 4.0, y: 6.3))
    arrows.line(to: NSPoint(x: 6.3, y: 4.2))
    arrows.stroke()

    image.isTemplate = true
    return image
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    StatusBarController.shared.install()
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
