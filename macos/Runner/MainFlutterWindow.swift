import Cocoa
import FlutterMacOS

/// Native drag destination around Flutter's root view. Finder file drops are
/// resolved in the content-view hierarchy, so this parent view receives drops
/// across the conversation area while Flutter retains normal input handling.
private final class ConversationDropView: NSView {
  private static let conversationPaneMinX: CGFloat = 316

  var onFilesDropped: (([String]) -> Void)?

  private let dropOverlay = NSView()
  private let dropCard = NSVisualEffectView()
  private let dropTitle = NSTextField(labelWithString: "松手完成添加")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureDropOverlay()
    registerForDraggedTypes([.fileURL, .URL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureDropOverlay()
    registerForDraggedTypes([.fileURL, .URL])
  }

  override func layout() {
    super.layout()
    let paneWidth = max(0, bounds.width - Self.conversationPaneMinX)
    dropOverlay.frame = NSRect(
      x: Self.conversationPaneMinX, y: 0, width: paneWidth, height: bounds.height)
    dropCard.frame.origin = NSPoint(
      x: (dropOverlay.bounds.width - dropCard.bounds.width) / 2,
      y: (dropOverlay.bounds.height - dropCard.bounds.height) / 2)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateDropOverlay(for: sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateDropOverlay(for: sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    hideDropOverlay()
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    isConversationDrop(sender) && !droppedPaths(from: sender).isEmpty
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { hideDropOverlay() }
    let paths = droppedPaths(from: sender)
    guard !paths.isEmpty, isConversationDrop(sender) else { return false }
    onFilesDropped?(paths)
    return true
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    hideDropOverlay()
  }

  private func configureDropOverlay() {
    wantsLayer = true
    dropOverlay.wantsLayer = true
    dropOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
    dropOverlay.isHidden = true
    dropOverlay.autoresizingMask = []
    addSubview(dropOverlay, positioned: .above, relativeTo: nil)

    dropCard.material = .hudWindow
    dropCard.blendingMode = .withinWindow
    dropCard.state = .active
    dropCard.wantsLayer = true
    dropCard.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.90).cgColor
    dropCard.layer?.cornerRadius = 14
    dropCard.layer?.masksToBounds = true
    dropCard.frame.size = NSSize(width: 196, height: 76)
    dropOverlay.addSubview(dropCard)

    dropTitle.alignment = .center
    dropTitle.font = .systemFont(ofSize: 17, weight: .semibold)
    dropTitle.textColor = .white
    dropTitle.frame = NSRect(x: 16, y: 26, width: 164, height: 24)
    dropCard.addSubview(dropTitle)
  }

  private func updateDropOverlay(for sender: NSDraggingInfo) -> NSDragOperation {
    let acceptsDrop = !droppedPaths(from: sender).isEmpty && isConversationDrop(sender)
    dropOverlay.isHidden = !acceptsDrop
    return acceptsDrop ? .copy : []
  }

  private func isConversationDrop(_ sender: NSDraggingInfo) -> Bool {
    convert(sender.draggingLocation, from: nil).x >= Self.conversationPaneMinX
  }

  private func hideDropOverlay() {
    dropOverlay.isHidden = true
  }

  private func droppedPaths(from sender: NSDraggingInfo) -> [String] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: options) as? [URL] ?? []
    return urls.filter(\.isFileURL).map(\.path)
  }
}

private final class DesktopImagePreviewController: NSObject {
  static let shared = DesktopImagePreviewController()
  private var window: NSWindow?

  private static func makeDownloadIcon() -> NSImage {
    let size = NSSize(width: 30, height: 30)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.white.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 15, y: 24))
    arrow.line(to: NSPoint(x: 15, y: 12))
    arrow.move(to: NSPoint(x: 9, y: 18))
    arrow.line(to: NSPoint(x: 15, y: 12))
    arrow.line(to: NSPoint(x: 21, y: 18))
    arrow.stroke()

    let tray = NSBezierPath()
    tray.lineWidth = 2.5
    tray.lineCapStyle = .round
    tray.lineJoinStyle = .round
    tray.move(to: NSPoint(x: 6.5, y: 10.5))
    tray.line(to: NSPoint(x: 6.5, y: 7.5))
    tray.curve(to: NSPoint(x: 8.5, y: 6.5), controlPoint1: NSPoint(x: 6.5, y: 6.9), controlPoint2: NSPoint(x: 7.4, y: 6.5))
    tray.line(to: NSPoint(x: 21.5, y: 6.5))
    tray.curve(to: NSPoint(x: 23.5, y: 7.5), controlPoint1: NSPoint(x: 22.6, y: 6.5), controlPoint2: NSPoint(x: 23.5, y: 6.9))
    tray.line(to: NSPoint(x: 23.5, y: 10.5))
    tray.stroke()
    image.isTemplate = false
    return image
  }

  func show(path: String, name: String) throws {
    guard let image = NSImage(contentsOfFile: path) else {
      throw NSError(
        domain: "SendHere.ImagePreview", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "无法读取图片文件"])
    }
    let screenFrame = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800))
    let imageSize = image.size
    let aspectRatio = imageSize.width > 0 && imageSize.height > 0
      ? imageSize.width / imageSize.height : 1
    let maximumWidth = screenFrame.width * 0.9
    let maximumHeight = screenFrame.height * 0.9
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    if maximumWidth / maximumHeight > aspectRatio {
      contentHeight = maximumHeight
      contentWidth = contentHeight * aspectRatio
    } else {
      contentWidth = maximumWidth
      contentHeight = contentWidth / aspectRatio
    }
    let frame = NSRect(
      x: screenFrame.midX - contentWidth / 2,
      y: screenFrame.midY - contentHeight / 2,
      width: contentWidth,
      height: contentHeight)
    let preview = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    preview.title = name
    preview.isReleasedWhenClosed = false
    preview.minSize = NSSize(width: 320, height: 240)

    let contentView = NSView(frame: preview.contentView?.bounds ?? .zero)
    contentView.autoresizingMask = [.width, .height]
    let imageView = NSImageView(frame: contentView.bounds)
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    imageView.autoresizingMask = [.width, .height]
    contentView.addSubview(imageView)
    let saveButton = NSButton(
      image: Self.makeDownloadIcon(),
      target: self,
      action: #selector(saveFromPreview(_:)))
    saveButton.bezelStyle = .regularSquare
    saveButton.isBordered = false
    saveButton.imageScaling = .scaleNone
    saveButton.wantsLayer = true
    saveButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 0.64).cgColor
    saveButton.layer?.borderWidth = 0
    saveButton.layer?.cornerRadius = 24
    saveButton.toolTip = "下载到本地"
    saveButton.identifier = NSUserInterfaceItemIdentifier(path)
    saveButton.frame = NSRect(x: contentView.bounds.width - 64, y: 16, width: 48, height: 48)
    saveButton.autoresizingMask = [.minXMargin, .maxYMargin]
    contentView.addSubview(saveButton)
    preview.contentView = contentView
    preview.center()
    preview.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window = preview
  }

  @objc private func saveFromPreview(_ sender: NSButton) {
    guard let path = sender.identifier?.rawValue else { return }
    save(path: path)
  }

  func copy(path: String) throws {
    guard let image = NSImage(contentsOfFile: path) else {
      throw NSError(
        domain: "SendHere.ImagePreview", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "无法读取图片文件"])
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.writeObjects([image]) else {
      throw NSError(
        domain: "SendHere.ImagePreview", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "无法写入系统剪贴板"])
    }
  }

  func save(path: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent
    panel.canCreateDirectories = true
    panel.begin { response in
      guard response == .OK, let destination = panel.url else { return }
      do {
        let source = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: destination.path) {
          try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
      } catch {
        NSAlert(error: error).runModal()
      }
    }
  }
}

private final class ConversationContainerController: NSViewController {
  let flutterViewController: FlutterViewController
  let dropView = ConversationDropView()

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    view = dropView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    addChild(flutterViewController)
    let flutterView = flutterViewController.view
    flutterView.frame = dropView.bounds
    flutterView.autoresizingMask = [.width, .height]
    dropView.addSubview(flutterView, positioned: .below, relativeTo: dropView.subviews.first)
  }
}

class MainFlutterWindow: NSWindow {
  private var conversationDropChannel: FlutterMethodChannel?
  private var notificationChannel: FlutterMethodChannel?
  private var imagePreviewChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let containerController = ConversationContainerController(
      flutterViewController: flutterViewController)
    let windowFrame = self.frame
    self.contentViewController = containerController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    conversationDropChannel = FlutterMethodChannel(
      name: "sendhere/conversation_drop", binaryMessenger: flutterViewController.engine.binaryMessenger)
    containerController.dropView.onFilesDropped = { [weak self] paths in
      self?.conversationDropChannel?.invokeMethod("filesDropped", arguments: paths)
    }

    let deviceNameChannel = FlutterMethodChannel(
      name: "sendhere/device_name", binaryMessenger: flutterViewController.engine.binaryMessenger)
    deviceNameChannel.setMethodCallHandler { call, result in
      guard call.method == "get" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(Host.current().localizedName)
    }

    notificationChannel = FlutterMethodChannel(
      name: "sendhere/notifications", binaryMessenger: flutterViewController.engine.binaryMessenger)
    notificationChannel?.setMethodCallHandler { call, result in
      switch call.method {
      case "setUnreadCount":
        let arguments = call.arguments as? [String: Any]
        StatusBarController.shared.setUnreadCount(arguments?["count"] as? Int ?? 0)
        result(nil)
      case "show":
        let arguments = call.arguments as? [String: Any]
        StatusBarController.shared.showNotification(
          title: arguments?["title"] as? String ?? "SendHere",
          body: arguments?["body"] as? String ?? "你收到了新消息")
        result(nil)
      case "shouldNotify":
        result(StatusBarController.shared.shouldPresentIncomingNotification)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    imagePreviewChannel = FlutterMethodChannel(
      name: "sendhere/image_preview", binaryMessenger: flutterViewController.engine.binaryMessenger)
    imagePreviewChannel?.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "show":
        do {
          try DesktopImagePreviewController.shared.show(
            path: path, name: arguments["name"] as? String ?? "图片预览")
          result(nil)
        } catch {
          result(FlutterError(code: "image_unavailable", message: error.localizedDescription, details: path))
        }
      case "copy":
        do {
          try DesktopImagePreviewController.shared.copy(path: path)
          result(nil)
        } catch {
          result(FlutterError(code: "image_copy_failed", message: error.localizedDescription, details: path))
        }
      case "save":
        guard FileManager.default.fileExists(atPath: path) else {
          result(FlutterError(code: "file_missing", message: "文件已不存在", details: path))
          return
        }
        DesktopImagePreviewController.shared.save(path: path)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let registrar = flutterViewController.registrar(forPlugin: "NativeTextField")
    registrar.register(
      NativeTextViewFactory(messenger: registrar.messenger),
      withId: "sendhere/native_text_field")

    StatusBarController.shared.remember(window: self)
    StatusBarController.shared.install()

    super.awakeFromNib()
  }
}
