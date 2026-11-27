import 'dart:ui';

import 'package:flutter/material.dart';

import 'src/launch_log.dart';
import 'src/send_here_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Report instead of dying silently: iOS leaves no crash report behind when
  // the app is killed during startup, so anything that escapes here is written
  // to launch.log — visible in the Files app — before the frame is aborted.
  FlutterError.onError = (details) {
    LaunchLog.error('FlutterError', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    LaunchLog.error('uncaught', error, stack);
    return true;
  };

  // Awaiting this puts a `boot` line on disk before the first widget is built,
  // which is what makes a launch failure visible at all.
  await LaunchLog.start();
  LaunchLog.mark('boot: runApp');
  runApp(const SendHereApp());
}
