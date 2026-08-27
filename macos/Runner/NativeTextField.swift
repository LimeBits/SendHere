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
final class SendHereTextView: NSTextView {
  override var acceptsFirstResponder: Bool { true }

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
  override var acceptsFirstResponder: Bool { true }

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

  init(viewId: Int64, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "sendhere/native_text_field/\(viewId)", binaryMessenger: messenger)
    super.init()

    textView.delegate = self
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
        self.textView.string = call.arguments as? String ?? ""
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

  func textDidChange(_ notification: Notification) {
    channel.invokeMethod("textChanged", arguments: textView.string)
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
      channel.invokeMethod("submit", arguments: textView.string)
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
