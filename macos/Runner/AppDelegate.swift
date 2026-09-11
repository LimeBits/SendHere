import Cocoa
import FlutterMacOS
import UserNotifications

/// Owns the menu bar item. A single strong static reference keeps both the
/// status item and its action target alive for the whole app lifetime; an
/// item created on a short-lived object silently disappears from the menu bar.
final class StatusBarController: NSObject {
  static let shared = StatusBarController()

  private var statusItem: NSStatusItem?
  private(set) weak var mainWindow: NSWindow?
  private var notificationAuthorizationRequested = false

  func remember(window: NSWindow) {
    mainWindow = window
  }

  func install() {
    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let button = item.button else { return }

    button.image = Self.makeIcon()
    button.imagePosition = .imageLeft
    button.target = self
    button.action = #selector(statusItemClicked)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    button.toolTip = "SendHere · 传到这（左键打开窗口，右键菜单）"

    statusItem = item
    requestNotificationAuthorization()
  }

  func setUnreadCount(_ count: Int) {
    guard let button = statusItem?.button else { return }
    button.title = count > 0 ? " \(min(count, 99))" : ""
    button.toolTip = count > 0
      ? "SendHere · \(count) 条未读消息（左键打开窗口，右键菜单）"
      : "SendHere · 传到这（左键打开窗口，右键菜单）"
  }

  func showNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  private func requestNotificationAuthorization() {
    guard !notificationAuthorizationRequested else { return }
    notificationAuthorizationRequested = true
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound]) { _, _ in }
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
    // Like VoxHere, use a monochrome template rather than a fixed light-grey
    // mark. AppKit then supplies the correct contrast for both light and dark
    // menu bars, including the older macOS 12 status-bar appearance.
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current else { return nil }
    context.shouldAntialias = true

    NSColor.black.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: 0.6, y: 0.6, width: 14.8, height: 14.8),
      xRadius: 4.1,
      yRadius: 4.1).fill()

    let arrow = NSBezierPath()
    arrow.lineWidth = 1.55
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round

    // A bidirectional transfer mark cut out from the template silhouette.
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
    // This callback is invoked only after the final app window genuinely
    // closed. Retain the process for transfers and the menu-bar item, then
    // switch to accessory mode so macOS removes SendHere from the Dock.
    NSApp.setActivationPolicy(.accessory)
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
