import 'dart:io';

import 'package:flutter/services.dart';

/// Returns the user-facing device name exposed by the native platform.
/// `Platform.localHostname` may be `localhost` on iOS and is only a fallback.
class DeviceName {
  static const _channel = MethodChannel('sendhere/device_name');

  static Future<String> current() async {
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final name = await _channel.invokeMethod<String>('get');
        if (name != null && name.trim().isNotEmpty) return name.trim();
      } on PlatformException {
        // Keep local transfer available if native name lookup is unavailable.
      }
    }

    final hostname = Platform.localHostname.trim();
    if (Platform.isIOS && (hostname.isEmpty || hostname == 'localhost')) {
      return 'iPhone';
    }
    return hostname;
  }
}
