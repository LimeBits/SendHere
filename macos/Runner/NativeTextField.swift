import Cocoa
import FlutterMacOS

/// A real `NSTextView` exposed to Flutter as a platform view.
///
/// Flutter draws its own text field and never becomes a native text control,
/// so macOS dictation and third-party speech input methods, which insert text
/// into the focused *native* responder, have nothing to write into. Hosting an
/// actual `NSTextView` restores the standard macOS input path: input methods,
/// dictation, marked (preedit) text, and paste all work as usual.
/// `AppKitView` is hosted inside Flutter's key-event hierarchy. Explicitly
/// forwarding Command-V here prevents the Flutter view from swallowing paste
/// before the native editor receives it.
private func droppedFilePaths(from sender: NSDraggingInfo) -> [String] {
  let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
  let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
  return urls.filter(\.isFileURL).map(\.path)
}

final class SendHereTextView: NSTextView {
  var onFilesDropped: (([String]) -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedFilePaths(from: sender).isEmpty ? super.draggingEntered(sender) : .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedFilePaths(from: sender).isEmpty ? super.draggingUpdated(sender) : .copy
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    !droppedFilePaths(from: sender).isEmpty || super.prepareForDragOperation(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = droppedFilePaths(from: sender)
    guard !paths.isEmpty else { return super.performDragOperation(sender) }
    onFilesDropped?(paths)
    return true
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    super.concludeDragOperation(sender)
    window?.makeFirstResponder(self)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "v" {
      paste(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

final class SendHereScrollView: NSScrollView {
  var onFilesDropped: (([String]) -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedFilePaths(from: sender).isEmpty ? super.draggingEntered(sender) : .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedFilePaths(from: sender).isEmpty ? super.draggingUpdated(sender) : .copy
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    !droppedFilePaths(from: sender).isEmpty || super.prepareForDragOperation(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = droppedFilePaths(from: sender)
    guard !paths.isEmpty else { return super.performDragOperation(sender) }
    onFilesDropped?(paths)
    return true
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    super.concludeDragOperation(sender)
    if let editor = documentView as? NSTextView {
      window?.makeFirstResponder(editor)
    }
  }

  override func mouseDown(with event: NSEvent) {
    if let editor = documentView as? NSTextView {
      window?.makeFirstResponder(editor)
    }
    super.mouseDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "v",
       let editor = documentView as? NSTextView {
      window?.makeFirstResponder(editor)
      editor.paste(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

final class NativeTextView: NSObject, NSTextViewDelegate {
  private let scrollView = SendHereScrollView()
  private let textView = SendHereTextView()
  private let channel: FlutterMethodChannel
  private var isApplyingCompose = false
  private var attachmentMetadata: [ObjectIdentifier: (path: String, name: String)] = [:]

  init(viewId: Int64, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "sendhere/native_text_field/\(viewId)", binaryMessenger: messenger)
    super.init()

    textView.delegate = self
    let onFilesDropped: ([String]) -> Void = { [weak self] paths in
      NSLog("[SendHere.Input] Dropped %d file(s)", paths.count)
      self?.channel.invokeMethod("filesDropped", arguments: paths)
    }
    textView.registerForDraggedTypes([.fileURL, .URL])
    textView.onFilesDropped = onFilesDropped
    scrollView.registerForDraggedTypes([.fileURL, .URL])
    scrollView.onFilesDropped = onFilesDropped
    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = .systemFont(ofSize: 13)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.textContainerInset = NSSize(width: 6, height: 8)
    textView.autoresizingMask = [.width]
    // The surrounding Flutter UI is currently light-only, so pin the native
    // view to the light appearance instead of following the system setting.
    textView.appearance = NSAppearance(named: .aqua)
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    textView.textColor = .textColor
    textView.insertionPointColor = .textColor

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = true
    scrollView.borderType = .bezelBorder
    scrollView.appearance = NSAppearance(named: .aqua)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "setText":
        let text = call.arguments as? String ?? ""
        NSLog("[SendHere.Input] Native setText: %d characters", text.count)
        self.isApplyingCompose = true
        self.textView.string = text
        self.attachmentMetadata.removeAll()
        self.isApplyingCompose = false
        self.textView.needsDisplay = true
        self.reportContentHeight()
        result(nil)
      case "setCompose":
        self.applyCompose(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "getText":
        result(self.textView.string)
      case "focus":
        self.textView.window?.makeFirstResponder(self.textView)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func view() -> NSView {
    return scrollView
  }

  private func applyCompose(_ compose: [String: Any]) {
    let items = compose["items"] as? [[String: String]] ?? []
    let draft = compose["draft"] as? String ?? ""
    let content = NSMutableAttributedString()
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = 10

    isApplyingCompose = true
    attachmentMetadata.removeAll()
    for item in items {
      if item["type"] == "text", let text = item["text"] {
        // Text must be rendered exactly as the user wrote it. Adding a newline
        // here used to make each round-trip through Flutter grow another line.
        content.append(NSAttributedString(
          string: text,
          attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: paragraph]))
      } else if item["type"] == "file", let filePath = item["path"] {
        // Attachments occupy their own visual line without making that newline
        // part of the user's text model.
        if content.length > 0 && !content.string.hasSuffix("\n") {
          content.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
        }
        let attachment = NSTextAttachment()
        let name = item["name"] ?? URL(fileURLWithPath: filePath).lastPathComponent
        attachment.image = composeFileImage(path: filePath, name: name)
        attachmentMetadata[ObjectIdentifier(attachment)] = (path: filePath, name: name)
        content.append(NSAttributedString(attachment: attachment))
        content.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
      }
    }
    if !draft.isEmpty {
      content.append(NSAttributedString(
        string: draft,
        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]))
    }
    textView.textStorage?.setAttributedString(content)
    textView.setSelectedRange(NSRange(location: content.length, length: 0))
    isApplyingCompose = false
    textView.needsDisplay = true
    reportContentHeight()
  }

  private func reportContentHeight() {
    guard let container = textView.textContainer,
          let layoutManager = textView.layoutManager else { return }
    layoutManager.ensureLayout(for: container)
    let usedHeight = layoutManager.usedRect(for: container).height
    let height = ceil(usedHeight + textView.textContainerInset.height * 2)
    channel.invokeMethod("contentHeightChanged", arguments: height)
  }

  private func composeFileImage(path: String, name: String) -> NSImage {
    let size = NSSize(width: 330, height: 74)
    let image = NSImage(size: size)
    image.lockFocus()
    // Do not use controlBackgroundColor here: it follows the system appearance
    // and becomes almost black on some macOS configurations. Compose attachments
    // should match SendHere's light sent-file bubble instead.
    let background = NSColor(
      calibratedRed: 0.89, green: 0.90, blue: 0.97, alpha: 1)
    background.setFill()
    NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()
    let titleRect = NSRect(x: 14, y: 39, width: 250, height: 20)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    paragraph.maximumLineHeight = 22
    paragraph.minimumLineHeight = 22
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 15),
      .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
      .paragraphStyle: paragraph]
    // NSTextAttachment cards have a fixed inline height. Draw exactly one
    // baseline and truncate long names in the middle, rather than allowing
    // AppKit to wrap a second line that gets clipped by the attachment bounds.
    NSAttributedString(string: name, attributes: attributes).draw(
      with: titleRect,
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    let sizeRect = NSRect(x: 14, y: 18, width: 250, height: 16)
    let sizeAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12),
      .foregroundColor: NSColor(calibratedWhite: 0.38, alpha: 1)]
    NSAttributedString(string: fileSizeDescription(for: path), attributes: sizeAttributes).draw(in: sizeRect)
    let icon = NSWorkspace.shared.icon(forFile: path)
    icon.size = NSSize(width: 38, height: 38)
    icon.draw(in: NSRect(x: 278, y: 18, width: 38, height: 38))
    image.unlockFocus()
    return image
  }

  private func fileSizeDescription(for path: String) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let byteCount = attributes[.size] as? NSNumber else {
      return "文件"
    }
    return ByteCountFormatter.string(fromByteCount: byteCount.int64Value, countStyle: .file)
  }

  func textDidChange(_ notification: Notification) {
    guard !isApplyingCompose else { return }
    let items = serializeCompose()
    NSLog("[SendHere.Input] Native compose changed: %d item(s)", items.count)
    // One edit produces one state update. Sending a second textChanged event
    // here raced composeChanged and could force Flutter to rebuild the view.
    channel.invokeMethod("composeChanged", arguments: items)
    reportContentHeight()
  }

  private func serializeCompose() -> [[String: String]] {
    guard let storage = textView.textStorage else { return [] }
    var items: [[String: String]] = []
    var pendingText = ""


    var index = 0
    while index < storage.length {
      var range = NSRange(location: 0, length: 0)
      let attachment = storage.attribute(.attachment, at: index, effectiveRange: &range) as? NSTextAttachment
      if let attachment, let metadata = attachmentMetadata[ObjectIdentifier(attachment)] {
        // The newline placed immediately before an attachment is layout-only.
        if pendingText.hasSuffix("\n") {
          pendingText.removeLast()
        }
        if !pendingText.isEmpty {
          items.append(["type": "text", "text": pendingText])
          pendingText = ""
        }
        items.append(["type": "file", "path": metadata.path, "name": metadata.name])
        index = NSMaxRange(range)
        // The newline after an attachment is also layout-only. Do not save it
        // into the following text fragment, otherwise it compounds on rebuild.
        if index < storage.length,
           (storage.string as NSString).substring(with: NSRange(location: index, length: 1)) == "\n" {
          index += 1
        }
        continue
      }
      let character = (storage.string as NSString).substring(with: NSRange(location: index, length: 1))
      pendingText += character
      index += 1
    }
    if !pendingText.isEmpty {
      items.append(["type": "text", "text": pendingText])
    }
    return items
  }

  func textView(
    _ textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    // Enter sends, Option/Shift + Enter inserts a newline. `insertNewline:`
    // only arrives after the input method has committed any marked text, so
    // Chinese/Japanese candidate selection is never intercepted.
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      let flags = NSApp.currentEvent?.modifierFlags ?? []
      if flags.contains(.option) || flags.contains(.shift) {
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
      }
      channel.invokeMethod("submit", arguments: "")
      return true
    }
    return false
  }
}

final class NativeTextViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  // The platform view owns the channel handler, so it must outlive `create`.
  private var views: [NativeTextView] = []

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let view = NativeTextView(viewId: viewId, messenger: messenger)
    views.append(view)
    return view.view()
  }
}
