import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var documentController: UIDocumentInteractionController?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    DispatchQueue.main.async { [weak self] in
      self?.configureChannels()
    }
  }

  private func configureChannels() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }

    let deviceNameChannel = FlutterMethodChannel(
      name: "sendhere/device_name", binaryMessenger: controller.binaryMessenger)
    deviceNameChannel.setMethodCallHandler { call, result in
      guard call.method == "get" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
      result(name.isEmpty ? UIDevice.current.model : name)
    }

    let fileChannel = FlutterMethodChannel(
      name: "sendhere/mobile_file", binaryMessenger: controller.binaryMessenger)
    fileChannel.setMethodCallHandler { [weak self, weak controller] call, result in
      guard call.method == "open",
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(code: "file_missing", message: "文件已不存在", details: path))
        return
      }

      let documentController = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
      self?.documentController = documentController
      guard let view = controller?.view else {
        result(FlutterError(code: "view_unavailable", message: "无法显示文件", details: nil))
        return
      }
      documentController.presentOptionsMenu(
        from: view.bounds, in: view, animated: true)
      result(nil)
    }
  }
}
