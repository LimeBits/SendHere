import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSDraggingDestination {
  private var conversationDropChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    registerForDraggedTypes([.fileURL, .URL])
    conversationDropChannel = FlutterMethodChannel(
      name: "sendhere/conversation_drop", binaryMessenger: flutterViewController.engine.binaryMessenger)

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

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedPaths(from: sender).isEmpty ? [] : .copy
  }

  func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    !droppedPaths(from: sender).isEmpty
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = droppedPaths(from: sender)
    guard !paths.isEmpty else { return false }
    // The left sidebar is 300pt wide. Treat all remaining window space as the
    // active conversation drop zone, including the message history above input.
    let location = convertPoint(fromScreen: sender.draggingLocation)
    guard location.x >= 316 else { return false }
    conversationDropChannel?.invokeMethod("filesDropped", arguments: paths)
    return true
  }

  private func droppedPaths(from sender: NSDraggingInfo) -> [String] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: options) as? [URL] ?? []
    return urls.filter(\.isFileURL).map(\.path)
  }
}
