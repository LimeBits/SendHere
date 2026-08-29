import 'dart:io';

import 'package:flutter/services.dart';

/// Returns the user-facing computer name configured in macOS System Settings.
/// `Platform.localHostname` is only a network host name and often omits it.
class DeviceName {
  static const _channel = MethodChannel('sendhere/device_name');

  static Future<String> current() async {
    if (!Platform.isMacOS) return Platform.localHostname;
    try {
      final name = await _channel.invokeMethod<String>('get');
      if (name != null && name.trim().isNotEmpty) return name.trim();
    } on PlatformException {
      // Keep local transfer available if native name lookup is unavailable.
    }
    return Platform.localHostname;
  }
}
