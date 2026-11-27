import Flutter
import UIKit

/// Writes one line into the same `Documents/launch.log` the Dart side uses.
///
/// The Dart log only starts once the Flutter engine runs, so a launch that dies
/// before `main()` leaves no trace at all. These native breadcrumbs tell apart
/// "dyld/signature refused to start the app" (no native lines) from "the engine
/// or the first frame blew up" (native lines, no `boot`).
func sendHereLaunchBreadcrumb(_ line: String) {
  guard let directory = FileManager.default.urls(
    for: .documentDirectory, in: .userDomainMask
  ).first else { return }
  let url = directory.appendingPathComponent("launch.log")
  let stamp = ISO8601DateFormatter().string(from: Date())
  guard let data = "\(stamp)  \(line)\n".data(using: .utf8) else { return }
  if let handle = try? FileHandle(forWritingTo: url) {
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    handle.write(data)
  } else {
    try? data.write(to: url)
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    sendHereLaunchBreadcrumb("native: didFinishLaunching")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    sendHereLaunchBreadcrumb("native: engine ready")
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
