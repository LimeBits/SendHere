import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'update_checker.dart';

/// A tiny on-device breadcrumb trail for diagnosing launch failures.
///
/// When iOS kills an app during startup it leaves nothing behind: no `.ips`
/// crash report, no console. This writes one line per boot stage into
/// `Documents/launch.log`, which is visible in the Files app because the app
/// already sets `UIFileSharingEnabled`. The last line therefore tells us how
/// far the next launch got:
///
/// * ends at `boot` — the engine never reached `runApp`
/// * ends at `home.initState` — the fault is in the first widget tree
/// * ends at `state.loaded` — the fault is in persisted data or the server
///
/// Writes are synchronous and swallow every error: the log must never be the
/// reason SendHere fails to start. The file keeps the last [_maxLines] lines
/// so it cannot grow without bound.
class LaunchLog {
  LaunchLog._();

  static File? _file;
  static const int _maxLines = 300;

  /// Called once from `main`, before `runApp`.
  static Future<void> start() async {
    try {
      final documents = await getApplicationDocumentsDirectory();
      final file = File(path.join(documents.path, 'launch.log'));
      _file = file;
      if (await file.exists()) {
        final lines = await file.readAsLines();
        if (lines.length > _maxLines) {
          final kept = lines.sublist(lines.length - _maxLines);
          await file.writeAsString('${kept.join('\n')}\n');
        }
      }
      mark('──────── SendHere build $sendHereBuildNumber');
    } catch (_) {
      // Logging is best effort only.
    }
  }

  /// Appends a stage marker. Safe to call from anywhere, including before
  /// [start] finished (the line is simply dropped).
  static void mark(String stage) {
    final file = _file;
    if (file == null) return;
    try {
      file.writeAsStringSync(
        '${DateTime.now().toIso8601String()}  $stage\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Ignore: a failed write must not affect the app.
    }
  }

  /// Records an error with the first few stack frames.
  static void error(String label, Object error, StackTrace? stack) {
    mark('$label: $error');
    if (stack == null) return;
    final frames = stack.toString().split('\n').take(6).join('\n    ');
    mark('    $frames');
  }
}
