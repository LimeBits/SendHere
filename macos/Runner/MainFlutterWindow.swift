import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let registrar = flutterViewController.registrar(forPlugin: "NativeTextField")
    registrar.register(
      NativeTextViewFactory(messenger: registrar.messenger),
      withId: "sendhere/native_text_field")

    StatusBarController.shared.remember(window: self)
    StatusBarController.shared.install()

    super.awakeFromNib()
  }
}
