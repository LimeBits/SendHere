import Cocoa
import FlutterMacOS

/// Native drag destination around Flutter's root view. A Finder drag targets
/// the content view hierarchy rather than NSWindow, so hosting the Flutter
/// view inside this container lets the whole conversation pane accept files.
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

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Keep normal mouse/keyboard interaction entirely with Flutter. Dragging
    // destinations are still resolved through this registered parent view.
    subviews.reversed().first(where: { $0.frame.contains(point) })?.hitTest(
      convert(point, to: subviews.last)) ?? super.hitTest(point)
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

class MainFlutterWindow: NSWindow {
  private var conversationDropChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    let dropView = ConversationDropView(frame: windowFrame)
    dropView.autoresizingMask = [.width, .height]
    flutterViewController.view.frame = dropView.bounds
    flutterViewController.view.autoresizingMask = [.width, .height]
    dropView.addSubview(flutterViewController.view)

    self.contentViewController = flutterViewController
    self.contentView = dropView
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    conversationDropChannel = FlutterMethodChannel(
      name: "sendhere/conversation_drop", binaryMessenger: flutterViewController.engine.binaryMessenger)
    dropView.onFilesDropped = { [weak self] paths in
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

    let registrar = flutterViewController.registrar(forPlugin: "NativeTextField")
    registrar.register(
      NativeTextViewFactory(messenger: registrar.messenger),
      withId: "sendhere/native_text_field")

    StatusBarController.shared.remember(window: self)
    StatusBarController.shared.install()

    super.awakeFromNib()
  }
}
