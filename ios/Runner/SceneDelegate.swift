import Flutter
import UIKit
import UserNotifications

class SceneDelegate: FlutterSceneDelegate {
  private var documentController: UIDocumentInteractionController?
  private var notificationAuthorizationRequested = false

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

    let notificationChannel = FlutterMethodChannel(
      name: "sendhere/notifications", binaryMessenger: controller.binaryMessenger)
    notificationChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setUnreadCount":
        let arguments = call.arguments as? [String: Any]
        UIApplication.shared.applicationIconBadgeNumber = arguments?["count"] as? Int ?? 0
        result(nil)
      case "show":
        let arguments = call.arguments as? [String: Any]
        self?.showNotification(
          title: arguments?["title"] as? String ?? "SendHere",
          body: arguments?["body"] as? String ?? "你收到了新消息")
        result(nil)
      case "getPermission":
        self?.notificationPermissionStatus { result($0) }
      case "requestPermission":
        self?.requestNotificationPermission { result($0) }
      case "openSettings":
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
          result(FlutterError(code: "settings_unavailable", message: "无法打开系统设置", details: nil))
          return
        }
        UIApplication.shared.open(settingsURL)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let fileChannel = FlutterMethodChannel(
      name: "sendhere/mobile_file", binaryMessenger: controller.binaryMessenger)
    fileChannel.setMethodCallHandler { [weak self, weak controller] call, result in
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(code: "file_missing", message: "文件已不存在", details: path))
        return
      }

      if call.method == "saveImage" {
        guard let image = UIImage(contentsOfFile: path) else {
          result(FlutterError(code: "image_unavailable", message: "无法读取图片文件", details: path))
          return
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        result(nil)
        return
      }
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
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

  private func notificationPermissionStatus(completion: @escaping (String) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      completion(Self.permissionLabel(settings.authorizationStatus))
    }
  }

  private func requestNotificationPermission(completion: @escaping (String) -> Void) {
    notificationAuthorizationRequested = true
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { _, _ in
      self.notificationPermissionStatus(completion: completion)
    }
  }

  private static func permissionLabel(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized:
      return "authorized"
    case .provisional:
      return "provisional"
    case .denied:
      return "denied"
    case .ephemeral:
      return "ephemeral"
    case .notDetermined:
      return "notDetermined"
    @unknown default:
      return "notDetermined"
    }
  }

  private func showNotification(title: String, body: String) {
    let scheduleNotification = {
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false))
      UNUserNotificationCenter.current().add(request)
    }

    guard !notificationAuthorizationRequested else {
      scheduleNotification()
      return
    }
    requestNotificationPermission { permission in
      if permission == "authorized" || permission == "provisional" {
        scheduleNotification()
      }
    }
  }
}
