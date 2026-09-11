import Cocoa
import FlutterMacOS

/// Native drag destination around Flutter's root view. Finder file drops are
/// resolved in the content-view hierarchy, so this parent view receives drops
/// across the conversation area while Flutter retains normal input handling.
private final class ConversationDropView: NSView {
  var onFilesDropped: (([String]) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL, .URL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL, .URL])
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedPaths(from: sender).isEmpty ? [] : .copy
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    !droppedPaths(from: sender).isEmpty
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = droppedPaths(from: sender)
    guard !paths.isEmpty else { return false }
    // The Flutter layout reserves 300pt plus a 16pt gap for the sidebar.
    // Any position beyond it belongs to the active conversation pane.
    let location = convert(sender.draggingLocation, from: nil)
    guard location.x >= 316 else { return false }
    onFilesDropped?(paths)
    return true
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

  func show(path: String, name: String) throws {
    guard let image = NSImage(contentsOfFile: path) else {
      throw NSError(
        domain: "SendHere.ImagePreview", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "无法读取图片文件"])
    }
    let screenFrame = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800))
    let frame = NSRect(
      x: screenFrame.midX - screenFrame.width * 0.45,
      y: screenFrame.midY - screenFrame.height * 0.45,
      width: screenFrame.width * 0.9,
      height: screenFrame.height * 0.9)
    let preview = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    preview.title = name
    preview.isReleasedWhenClosed = false
    preview.minSize = NSSize(width: 480, height: 360)

    let imageView = NSImageView(frame: preview.contentView?.bounds ?? .zero)
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    imageView.autoresizingMask = [.width, .height]
    preview.contentView = imageView
    preview.center()
    preview.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window = preview
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
    dropView.addSubview(flutterView)
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
      guard call.method == "show",
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        try DesktopImagePreviewController.shared.show(
          path: path, name: arguments["name"] as? String ?? "图片预览")
        result(nil)
      } catch {
        result(FlutterError(code: "image_unavailable", message: error.localizedDescription, details: path))
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
