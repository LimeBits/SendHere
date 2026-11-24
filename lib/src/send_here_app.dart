import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_name.dart';
import 'local_transfer_server.dart';
import 'message_text.dart';
import 'nearby_device_service.dart';
import 'native_text_field.dart';
import 'message_history.dart';
import 'outbox.dart';
import 'transfer_event.dart';
import 'update_checker.dart';

const _mobileFileChannel = MethodChannel('sendhere/mobile_file');
const _notificationChannel = MethodChannel('sendhere/notifications');
const _imagePreviewChannel = MethodChannel('sendhere/image_preview');

Future<void> _openReceivedFile(BuildContext context, String filePath) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', filePath]);
      return;
    }
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', filePath]);
      return;
    }
    if (Platform.isIOS || Platform.isAndroid) {
      await _mobileFileChannel.invokeMethod<void>('open', {'path': filePath});
    }
  } on PlatformException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? '无法打开文件')),
      );
    }
  }
}

Future<void> _saveImageToDevice(
  BuildContext context,
  String filePath,
  String fileName,
) async {
  try {
    if (Platform.isMacOS) {
      await _imagePreviewChannel.invokeMethod<void>('save', {
        'path': filePath,
        'name': fileName,
      });
    } else if (Platform.isWindows) {
      final destination = await getSaveLocation(suggestedName: fileName);
      if (destination == null) return;
      await File(filePath).copy(destination.path);
      await Process.run('explorer.exe', ['/select,', destination.path]);
    } else {
      await _mobileFileChannel.invokeMethod<void>('saveImage', {
        'path': filePath,
        'name': fileName,
      });
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('图片已保存')));
    }
  } on PlatformException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? '无法保存图片')),
      );
    }
  }
}

void _showTopToast(BuildContext context, String message) {
  final overlay = Overlay.of(context);
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      top: MediaQuery.paddingOf(context).top + 18,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Material(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(message, style: const TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future<void>.delayed(const Duration(seconds: 2), entry.remove);
}

Future<void> _copyImageToClipboard(
  BuildContext context,
  String filePath,
) async {
  if (!Platform.isMacOS) return;
  try {
    await _imagePreviewChannel.invokeMethod<void>('copy', {'path': filePath});
    if (context.mounted) _showTopToast(context, '图片已复制');
  } on PlatformException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? '无法复制图片')),
      );
    }
  }
}

Future<void> _showImageActions(
  BuildContext context,
  String filePath,
  String fileName, {
  Offset? position,
}) async {
  if (Platform.isMacOS) {
    final anchor = position ?? Offset.zero;
    final menuPosition = RelativeRect.fromLTRB(
      anchor.dx,
      anchor.dy,
      MediaQuery.sizeOf(context).width - anchor.dx,
      MediaQuery.sizeOf(context).height - anchor.dy,
    );
    final action = await showMenu<String>(
      context: context,
      position: menuPosition,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      menuPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      items: const [
        _RoundedMenuItem(value: 'copy', child: Text('复制图片')),
        _RoundedMenuItem(value: 'save', child: Text('下载到本地')),
      ],
    );
    if (action == 'copy' && context.mounted) {
      await _copyImageToClipboard(context, filePath);
    }
    if (action == 'save' && context.mounted) {
      await _saveImageToDevice(context, filePath, fileName);
    }
    return;
  }
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('保存图片'),
          onTap: () => Navigator.of(sheetContext).pop('save'),
        ),
      ),
    ),
  );
  if (action == 'save' && context.mounted) {
    await _saveImageToDevice(context, filePath, fileName);
  }
}

Future<void> _showImagePreview(
  BuildContext context,
  String filePath,
  String fileName,
) async {
  if (Platform.isMacOS) {
    try {
      await _imagePreviewChannel.invokeMethod<void>('show', {
        'path': filePath,
        'name': fileName,
      });
      return;
    } on PlatformException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? '无法打开图片预览')),
        );
      }
      return;
    }
  }
  await Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (_, animation, __) => FadeTransition(
        opacity: animation,
        child: _ImagePreviewPage(filePath: filePath, fileName: fileName),
      ),
    ),
  );
}

class _ImagePreviewPage extends StatefulWidget {
  const _ImagePreviewPage({required this.filePath, required this.fileName});

  final String filePath;
  final String fileName;

  @override
  State<_ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<_ImagePreviewPage> {
  final _transformationController = TransformationController();
  Offset? _dragStart;
  int _activePointers = 0;
  bool _closing = false;

  bool get _mobile => Platform.isIOS || Platform.isAndroid;

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers++;
    _dragStart = _activePointers == 1 ? event.position : null;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_mobile || _activePointers != 1 || _dragStart == null) return;
    if (_transformationController.value.getMaxScaleOnAxis() > 1.02) return;
    final delta = event.position - _dragStart!;
    if (delta.dy > 120 && delta.dy > delta.dx.abs() * 1.25) _close();
  }

  void _handlePointerEnd(PointerEvent event) {
    if (_activePointers > 0) _activePointers--;
    if (_activePointers == 0) _dragStart = null;
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _mobile ? _close : null,
            child: Listener(
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerEnd,
              onPointerCancel: _handlePointerEnd,
              child: InteractiveViewer(
                transformationController: _transformationController,
                minScale: 0.8,
                maxScale: 5,
                child: Center(
                  child: Image.file(
                    File(widget.filePath),
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Text(
                      '无法显示 ${widget.fileName}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Material(
                  color: const Color(0xA32D2D30),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _saveImageToDevice(
                      context,
                      widget.filePath,
                      widget.fileName,
                    ),
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(
                        Icons.file_download_outlined,
                        size: 30,
                        color: Colors.white,
                        semanticLabel: '保存到相册',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SendHereApp extends StatelessWidget {
  const SendHereApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SendHere',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const SendHereHome(),
      );
}

class SendHereHome extends StatefulWidget {
  const SendHereHome({super.key});

  @override
  State<SendHereHome> createState() => _SendHereHomeState();
}

class _SendHereHomeState extends State<SendHereHome>
    with WidgetsBindingObserver {
  final _events = <TransferEvent>[];
  final _textController = TextEditingController();
  final _nearby = NearbyDeviceService();
  final _connectedPeers = <String, _PeerDevice>{};
  final _drafts = <String, String>{};
  final _pendingItems = <String, List<_PendingItem>>{};
  final _outbox = Outbox();
  final _history = MessageHistory();
  final _sendingOutboxDeviceIds = <String>{};
  Directory? _outboxDirectory;
  LocalTransferServer? _server;
  StreamSubscription<TransferEvent>? _subscription;
  StreamSubscription<List<NearbyDevice>>? _nearbySubscription;
  Timer? _tailscaleReconnectTimer;
  final _connectingPeerIds = <String>{};
  final _discoveredComputerIds = <String>{};
  String? _address;
  String? _tailscaleAddress;
  bool _qrUseTailscale = false;
  String? _error;
  String? _selectedPeerId;
  bool _phoneQrExpanded = false;
  bool _showMobileConversation = false;
  bool _restartingForForeground = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  final _unreadCounts = <String, int>{};
  String? _notificationPermission;

  int get _unreadCount =>
      _unreadCounts.values.fold(0, (total, count) => total + count);

  static const _recentDevicesKey = 'sendhere-recent-devices';
  static const _unreadCountsKey = 'sendhere-unread-counts';
  static const _qrUseTailscaleKey = 'sendhere-qr-use-tailscale';
  static const _skippedUpdateBuildKey = 'sendhere-skipped-update-build';
  static const _updateCheckInterval = Duration(hours: 6);
  static const _updateChannel = MethodChannel('sendhere/update');
  static const _conversationDropChannel =
      MethodChannel('sendhere/conversation_drop');
  Timer? _updateTimer;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _conversationDropChannel.setMethodCallHandler((call) async {
      if (call.method == 'filesDropped') {
        final paths = (call.arguments as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList();
        await _addFilesToPending(paths);
      }
    });
    _updateChannel.setMethodCallHandler((call) async {
      if (call.method == 'checkForUpdates') {
        await _checkForUpdate(manual: true);
      }
    });
    _loadInitialState().whenComplete(() async {
      await _updateNotificationBadge();
      await _refreshNotificationPermission(request: true);
      await _startServer();
      unawaited(_checkForUpdate());
      _updateTimer = Timer.periodic(_updateCheckInterval, (_) {
        unawaited(_checkForUpdate());
      });
    });
  }

  /// Checks GitHub for a newer build. The automatic check runs on launch and
  /// then every few hours while the app stays open. A manual check (menu item)
  /// always shows its result, including "already latest" and failures, and it
  /// ignores the "skip this version" choice.
  Future<void> _checkForUpdate({bool manual = false}) async {
    if (!Platform.isMacOS || _checkingUpdate) return;
    _checkingUpdate = true;
    try {
      final result = await UpdateChecker.check();
      if (!mounted) return;
      if (result.status == UpdateStatus.failed) {
        if (manual) {
          await _showUpdateMessage('检查更新失败', '无法连接 GitHub，请稍后再试。');
        }
        return;
      }
      if (result.status == UpdateStatus.upToDate) {
        if (manual) {
          await _showUpdateMessage('已是最新版本', 'SendHere build $sendHereBuildNumber 已是最新。');
        }
        return;
      }
      final update = result.update!;
      final prefs = await SharedPreferences.getInstance();
      if (!manual && prefs.getInt(_skippedUpdateBuildKey) == update.build) return;
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('发现新版本 ${update.tag}'),
          content: Text(
            '当前是 build $sendHereBuildNumber，最新是 build ${update.build}。\n'
            '下载 DMG 后，把 SendHere 拖到“应用程序”里覆盖旧版本即可。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'skip'),
              child: const Text('跳过此版本'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'later'),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'open'),
              child: const Text('下载更新'),
            ),
          ],
        ),
      );
      if (action == 'skip') {
        await prefs.setInt(_skippedUpdateBuildKey, update.build);
      } else if (action == 'open') {
        await Process.run('open', [update.url]);
      }
    } finally {
      _checkingUpdate = false;
    }
  }

  Future<void> _showUpdateMessage(String title, String body) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS || Platform.isAndroid) {
        unawaited(_refreshNotificationPermission());
        unawaited(_restartAfterForeground());
      }
    }
  }

  Future<void> _saveUnreadCounts() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_unreadCountsKey, jsonEncode(_unreadCounts));
  }

  Future<void> _refreshNotificationPermission({bool request = false}) async {
    if (!Platform.isIOS) return;
    try {
      final permission = await _notificationChannel.invokeMethod<String>(
        request ? 'requestPermission' : 'getPermission',
      );
      if (mounted && permission != null) {
        setState(() => _notificationPermission = permission);
      }
    } on PlatformException {
      // Notification permissions are optional for local network transfers.
    }
  }

  Future<void> _openNotificationSettings() async {
    if (!Platform.isIOS) return;
    try {
      await _notificationChannel.invokeMethod<void>('openSettings');
    } on PlatformException {
      // Nothing else can be done if iOS declines to open Settings.
    }
  }

  Future<void> _updateNotificationBadge() async {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    try {
      await _notificationChannel
          .invokeMethod<void>('setUnreadCount', {'count': _unreadCount});
    } on PlatformException {
      // Notifications are an enhancement and must not interrupt transfers.
    }
  }

  Future<void> _notifyIncomingMessage(TransferEvent event) async {
    final deviceId = event.deviceId;
    if (deviceId == null || event.direction != TransferDirection.received) {
      return;
    }
    var macOSWindowInactive = false;
    if (Platform.isMacOS) {
      try {
        macOSWindowInactive =
            await _notificationChannel.invokeMethod<bool>('shouldNotify') ??
                false;
      } on PlatformException {
        // If the native state cannot be read, keep the conservative default.
      }
    }
    final viewingConversation = _lifecycleState == AppLifecycleState.resumed &&
        _selectedPeerId == deviceId &&
        (!Platform.isIOS && !Platform.isAndroid || _showMobileConversation) &&
        !macOSWindowInactive;
    if (viewingConversation) return;
    if (mounted) {
      setState(() {
        _unreadCounts.update(deviceId, (count) => count + 1, ifAbsent: () => 1);
      });
    }
    unawaited(_saveUnreadCounts());
    await _updateNotificationBadge();
    if (macOSWindowInactive ||
        (_lifecycleState != AppLifecycleState.resumed && Platform.isIOS)) {
      final name = event.clientName ?? _connectedPeers[deviceId]?.name ?? '设备';
      final body = event.type == TransferEventType.file
          ? '向你发送了文件：${event.fileName ?? '文件'}'
          : event.text ?? '向你发送了一条消息';
      try {
        await _notificationChannel.invokeMethod<void>('show', {
          'title': name,
          'body': body,
        });
      } on PlatformException {
        // The transfer has completed even when notification permission is off.
      }
    }
  }

  /// Returning to the foreground must not rebuild a working server. Rebuilding
  /// discards the QR token and every browser session, so other phones that
  /// were connected through the web page lose access. Restart only when the
  /// server is actually gone.
  Future<void> _restartAfterForeground() async {
    if (_restartingForForeground) return;
    final server = _server;
    if (server != null && server.isRunning) return;
    _restartingForForeground = true;
    try {
      await _startServer();
    } finally {
      _restartingForForeground = false;
    }
  }

  Future<void> _loadInitialState() async {
    _outboxDirectory = await getApplicationSupportDirectory();
    await _outbox.load();
    await _history.load(_outboxDirectory!);
    final outboxIds = _outbox.items.map((item) => item.id).toSet();
    // _events is newest-first. Pending outbox items take precedence over a
    // stale history entry sharing their transferId.
    _events
      ..addAll(_history.items
          .where((event) =>
              event.transferId == null || !outboxIds.contains(event.transferId))
          .map((event) => event.withoutUnkeptSentCopy()))
      ..addAll(_outbox.items.map(_eventForOutbox))
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _loadRecentDevices();
    final preferences = await SharedPreferences.getInstance();
    final rawUnreadCounts = preferences.getString(_unreadCountsKey);
    if (rawUnreadCounts == null) return;
    try {
      final decoded = jsonDecode(rawUnreadCounts) as Map<String, dynamic>;
      _unreadCounts.addAll(decoded.map(
        (deviceId, count) => MapEntry(deviceId, (count as num).toInt()),
      ));
    } catch (_) {
      // A malformed unread cache must never prevent SendHere from starting.
    }
  }

  Future<void> _loadRecentDevices() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_recentDevicesKey);
    if (raw == null) return;
    try {
      final values = jsonDecode(raw) as List<dynamic>;
      if (!mounted) return;
      setState(() {
        for (final value in values) {
          final device = _PeerDevice.fromJson(value as Map<String, dynamic>);
          _connectedPeers[device.id] = device;
        }
      });
    } catch (_) {
      // A malformed cache must never prevent SendHere from starting.
    }
  }

  Future<void> _saveRecentDevices() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        _recentDevicesKey,
        jsonEncode(
            _connectedPeers.values.map((device) => device.toJson()).toList()));
  }

  Future<void> _startServer() async {
    try {
      await _subscription?.cancel();
      await _nearbySubscription?.cancel();
      await _nearby.pause();
      _discoveredComputerIds.clear();
      _connectingPeerIds.clear();
      await _server?.stop();
      final server = LocalTransferServer(
        downloadDirectory: await _receiveDirectory(),
        deviceName: await DeviceName.current(),
        onFileReceived: Platform.isAndroid ? _publishToAndroidDownloads : null,
      );
      await server.start();
      _subscription = server.events.listen((incoming) {
        final event = incoming.withoutUnkeptSentCopy();
        if (!mounted) return;
        final shouldCollapsePhoneQr = _phoneQrExpanded &&
            event.type == TransferEventType.clientConnected &&
            !event.isComputerPeer;
        setState(() {
          final existingIndex = event.transferId == null
              ? -1
              : _events.indexWhere(
                  (previous) => previous.transferId == event.transferId);
          if (existingIndex >= 0) {
            // Progress updates replace the original bubble instead of adding a
            // new message for every uploaded file chunk.
            _events[existingIndex] = event;
          } else {
            _events.insert(0, event);
          }
          if (event.deviceId != null && event.clientName != null) {
            if (event.type == TransferEventType.clientConnected) {
              final deviceId = event.deviceId!;
              final shouldOpenPhoneConversation = !event.isComputerPeer;
              final previous = _connectedPeers[deviceId];
              _connectedPeers[deviceId] = _PeerDevice(
                  id: deviceId,
                  name: event.clientName!,
                  online: true,
                  lastSeenAt: DateTime.now(),
                  tailscaleAddress:
                      event.peerTailscaleAddress ?? previous?.tailscaleAddress,
                  port: event.peerPort ?? previous?.port,
                  transport: event.isComputerPeer
                      ? server.peerTransport(deviceId)
                      : null);
              // Every QR browser identification represents a user opening a
              // phone session. It may reuse an ID from the recent-device list,
              // so select it even when that historical conversation already
              // exists. Computer peers must not steal the active chat.
              if (shouldOpenPhoneConversation || _selectedPeerId == null) {
                final previousId = _selectedPeerId;
                if (previousId != null) {
                  _drafts[previousId] = _textController.text;
                }
                _selectedPeerId = deviceId;
                _textController.text = _drafts[deviceId] ?? '';
              }
            } else if (event.type == TransferEventType.clientDisconnected) {
              final device = _connectedPeers[event.deviceId!];
              if (device != null) {
                _connectedPeers[event.deviceId!] = device.copyWith(
                    online: false,
                    lastSeenAt: DateTime.now(),
                    clearTransport: true);
              }
            } else {
              final device = _connectedPeers[event.deviceId!];
              if (device != null) {
                _connectedPeers[event.deviceId!] =
                    device.copyWith(lastSeenAt: DateTime.now());
              }
            }
          }
        });
        _saveRecentDevices();
        unawaited(_history.record(event));
        if (event.type == TransferEventType.text ||
            event.type == TransferEventType.file) {
          unawaited(_notifyIncomingMessage(event));
        }
        if (event.type == TransferEventType.clientConnected &&
            event.deviceId != null) {
          unawaited(_deliverOutbox(event.deviceId!));
        }
        if (shouldCollapsePhoneQr && mounted) {
          setState(() => _phoneQrExpanded = false);
        }
      });
      await _nearby.start(port: server.port);
      _nearbySubscription = _nearby.devices.listen(_syncNearbyDevices);
      final addresses = await server.localAddresses();
      final tailscale = await server.tailscaleAddresses();
      final preferences = await SharedPreferences.getInstance();
      final localDeviceId = _nearby.deviceId;
      if ((addresses.isNotEmpty || tailscale.isNotEmpty) &&
          localDeviceId != null) {
        server.setLocalEndpoint(
          address: addresses.isEmpty ? null : addresses.first,
          tailscaleAddress: tailscale.isEmpty ? null : tailscale.first,
          deviceId: localDeviceId,
        );
      }
      if (mounted) {
        setState(() {
          _server = server;
          _address = addresses.isEmpty ? null : addresses.first;
          _tailscaleAddress = tailscale.isEmpty ? null : tailscale.first;
          _qrUseTailscale = _tailscaleAddress != null &&
              (_address == null ||
                  (preferences.getBool(_qrUseTailscaleKey) ?? false));
          _error = null;
        });
        _startTailscaleReconnect();
        if (addresses.isEmpty &&
            tailscale.isEmpty &&
            (Platform.isIOS || Platform.isAndroid)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未检测到 Wi‑Fi 局域网地址，暂时无法生成连接二维码')),
          );
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  /// Where received files are saved.
  /// - macOS / Windows: the user's Downloads folder, like a browser. The macOS
  ///   sandbox grants this via `com.apple.security.files.downloads.read-write`.
  /// - iOS / Android (and fallback): Documents/SendHere. iOS sandboxes the
  ///   Downloads location, and Documents stays visible in the Files app.
  static Future<Directory> _receiveDirectory() async {
    if (Platform.isMacOS || Platform.isWindows) {
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) return downloads;
      } catch (error) {
        developer.log('Downloads folder unavailable: $error', name: 'SendHere');
      }
    }
    final documents = await getApplicationDocumentsDirectory();
    return Directory(path.join(documents.path, 'SendHere'));
  }

  /// Android only: publishes a received file to the public
  /// Download/SendHere folder so it is visible in the system Files app.
  /// Falls back to the private copy if publishing fails.
  static Future<String> _publishToAndroidDownloads(File file) async {
    try {
      final published = await _mobileFileChannel.invokeMethod<String>(
          'publishToDownloads', {'path': file.path});
      return published ?? file.path;
    } on PlatformException catch (error) {
      developer.log('Publish to Downloads failed: ${error.message}',
          name: 'SendHere');
      return file.path;
    }
  }

  /// Address advertised in the phone QR code: Tailscale when selected (or
  /// when there is no LAN address), otherwise the LAN address.
  String? get _qrAddress => _qrUseTailscale && _tailscaleAddress != null
      ? _tailscaleAddress
      : _address;

  String? get _url {
    final address = _qrAddress;
    if (_server == null || address == null) return null;
    return 'http://$address:${_server!.port}/?token=${_server!.token}';
  }

  Future<void> _setQrUseTailscale(bool value) async {
    if (_tailscaleAddress == null && value) return;
    if (_address == null && !value) return;
    setState(() => _qrUseTailscale = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_qrUseTailscaleKey, value);
  }

  Future<void> _syncNearbyDevices(List<NearbyDevice> devices) async {
    if (!mounted) return;
    final localDeviceId = _nearby.deviceId;
    final currentIds = devices.map((device) => device.id).toSet();
    final disappearedIds = _discoveredComputerIds.difference(currentIds);
    setState(() {
      for (final id in disappearedIds) {
        final existing = _connectedPeers[id];
        if (existing != null) {
          // mDNS can briefly withdraw a service while the app is foregrounded
          // or the Wi-Fi radio roams. Do not turn a healthy peer WebSocket into
          // “刚刚在线”; its real close event remains the offline authority.
          _connectedPeers[id] = existing.copyWith(
            online: _server?.hasDevice(id) ?? false,
            lastSeenAt: DateTime.now(),
          );
        }
      }
      _discoveredComputerIds
        ..clear()
        ..addAll(currentIds);
      for (final device in devices) {
        _server?.updatePeerEndpoint(
          deviceId: device.id,
          deviceName: device.name,
          address: device.address,
          port: device.port,
          localDeviceId: localDeviceId ?? '',
        );
        final existing = _connectedPeers[device.id];
        final onlineNow = _server?.hasDevice(device.id) ?? false;
        _connectedPeers[device.id] = existing == null
            ? _PeerDevice(
                id: device.id,
                name: device.name,
                // mDNS only proves the device is nearby. A device becomes
                // online after its peer WebSocket can transfer text/files.
                online: onlineNow,
                lastSeenAt: DateTime.now(),
                transport: onlineNow ? _server?.peerTransport(device.id) : null,
              )
            // Merge rather than replace: a fresh _PeerDevice would silently
            // drop the remembered tailscaleAddress/port, which the Tailscale
            // fallback timer relies on to redial after this device later
            // leaves the LAN again.
            : existing.copyWith(
                name: device.name,
                online: onlineNow,
                lastSeenAt: DateTime.now(),
                transport: onlineNow ? _server?.peerTransport(device.id) : null,
                clearTransport: !onlineNow,
              );
        if (existing == null && _selectedPeerId == null) {
          _selectedPeerId = device.id;
        }
      }
    });
    _saveRecentDevices();

    // A transient mDNS loss must not close an established peer socket. The
    // socket's onDone callback publishes the actual offline transition.

    // Only one side dials. The other side receives that peer's WebSocket,
    // preventing duplicate sessions when both computers discover each other.
    // This also drives the LAN-preferred upgrade: when a device reappears on
    // mDNS while still connected over Tailscale, _connectPeer dials its LAN
    // address and swaps transports without dropping the session.
    if (localDeviceId == null) return;
    for (final device in devices) {
      if (localDeviceId.compareTo(device.id) < 0) {
        unawaited(_connectPeer(device));
      }
    }
  }

  Future<bool> _connectPeer(NearbyDevice device) async {
    final server = _server;
    // A device already connected over Tailscale is still worth dialing again
    // when it has become reachable on the LAN: LocalTransferServer.connectToPeer
    // treats that as a silent upgrade rather than a duplicate. Any other
    // already-connected case (same transport, or already on LAN) is skipped.
    final isLanUpgradeAttempt = server != null &&
        server.hasPeer(device.id) &&
        server.peerTransport(device.id) == PeerTransport.tailscale &&
        !LocalTransferServer.isTailscaleIpv4(device.address);
    if (server == null ||
        _nearby.deviceId == null ||
        (server.hasPeer(device.id) && !isLanUpgradeAttempt) ||
        _connectingPeerIds.contains(device.id)) {
      return false;
    }
    setState(() => _connectingPeerIds.add(device.id));
    try {
      await server.connectToPeer(
        deviceId: device.id,
        deviceName: device.name,
        address: device.address,
        peerPort: device.port,
        localDeviceId: _nearby.deviceId!,
      );
      if (mounted) {
        setState(() {
          final existing = _connectedPeers[device.id];
          if (existing != null) {
            // A LAN upgrade swaps the socket without emitting its own
            // clientConnected event (to avoid an online/offline flash in
            // the UI), so this is the only place that refreshes the
            // displayed transport after one succeeds.
            _connectedPeers[device.id] = existing.copyWith(
                online: server.hasDevice(device.id),
                transport: server.peerTransport(device.id));
          }
          _selectedPeerId ??= device.id;
        });
      }
      return true;
    } catch (_) {
      // Retry while the device is still advertised. This restores recent
      // computers after an app restart without making the user reconnect them.
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted && _discoveredComputerIds.contains(device.id)) {
          unawaited(_connectPeer(device));
        }
      });
      return false;
    } finally {
      if (mounted) setState(() => _connectingPeerIds.remove(device.id));
    }
  }

  /// Periodically dials remembered computers over Tailscale when they are not
  /// discoverable on the LAN (mDNS does not cross Tailscale). LAN discovery
  /// stays preferred: a device seen via mDNS is skipped here.
  void _startTailscaleReconnect() {
    _tailscaleReconnectTimer?.cancel();
    if (_tailscaleAddress == null) return;
    unawaited(_reconnectTailscalePeers());
    _tailscaleReconnectTimer = Timer.periodic(
        const Duration(seconds: 20), (_) => _reconnectTailscalePeers());
  }

  Future<void> _reconnectTailscalePeers() async {
    final server = _server;
    final localDeviceId = _nearby.deviceId;
    if (!mounted || server == null || localDeviceId == null) return;
    for (final device in _connectedPeers.values.toList()) {
      final address = device.tailscaleAddress;
      if (address == null ||
          address == _tailscaleAddress ||
          _discoveredComputerIds.contains(device.id) ||
          server.hasPeer(device.id) ||
          server.hasDevice(device.id)) {
        continue;
      }
      // Same tie-break as LAN discovery so only one side dials.
      if (localDeviceId.compareTo(device.id) >= 0) continue;
      final port = device.port ?? 8899;
      server.updatePeerEndpoint(
        deviceId: device.id,
        deviceName: device.name,
        address: address,
        port: port,
        localDeviceId: localDeviceId,
      );
      unawaited(_connectPeer(NearbyDevice(
          id: device.id, name: device.name, address: address, port: port)));
    }
  }

  /// Adds a computer that has never been on the same LAN, by its Tailscale IP
  /// or MagicDNS name (e.g. macmini.tailxxxx.ts.net).
  Future<void> _showAddRemoteDevice() async {
    final controller = TextEditingController();
    String? error;
    var busy = false;
    _RemoteAddStage? stage;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDialogState) {
        Future<void> submit() async {
          final input = controller.text.trim();
          if (input.isEmpty) return;
          final parsed = _parseHostPort(input);
          setDialogState(() {
            busy = true;
            error = null;
            stage = _RemoteAddStage.resolving;
          });
          final added = await _addRemoteDevice(
            parsed.$1,
            parsed.$2,
            onStageChanged: (newStage) {
              if (context.mounted) setDialogState(() => stage = newStage);
            },
          );
          if (!context.mounted) return;
          if (added == null) {
            // Hold the "已连接" state briefly so the user actually sees the
            // connection succeed, instead of the dialog vanishing the instant
            // connectToPeer returns.
            await Future<void>.delayed(const Duration(milliseconds: 500));
            if (context.mounted) Navigator.of(context).pop();
          } else {
            setDialogState(() {
              busy = false;
              error = added;
              stage = null;
            });
          }
        }

        return AlertDialog(
          title: const Text('通过 Tailscale 添加电脑'),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                _tailscaleAddress == null
                    ? '本机未检测到 Tailscale 地址，请先打开 Tailscale。'
                    : '在对方电脑上打开 SendHere，然后输入它的 Tailscale 地址或主机名。本机：$_tailscaleAddress',
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                enabled: !busy,
                decoration: InputDecoration(
                  hintText: '100.x.x.x 或 macmini.tailxxxx.ts.net',
                  errorText: error,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => submit(),
              ),
              if (busy && stage != null) ...[
                const SizedBox(height: 12),
                _RemoteAddProgress(stage: stage!),
              ],
            ]),
          ),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: const Text('取消')),
            FilledButton(
              onPressed: busy ? null : submit,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('连接'),
            ),
          ],
        );
      }),
    );
    controller.dispose();
  }

  static (String, int) _parseHostPort(String input) {
    final cleaned =
        input.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    final index = cleaned.lastIndexOf(':');
    if (index > 0) {
      final port = int.tryParse(cleaned.substring(index + 1));
      if (port != null) return (cleaned.substring(0, index), port);
    }
    return (cleaned, 8899);
  }

  /// Returns null on success, or an error message. Reports progress via
  /// [onStageChanged] so the add dialog can show staged feedback (已找到 →
  /// 正在建立连接 → 已连接) instead of a single opaque spinner, and only
  /// close once the connection truly succeeds.
  Future<String?> _addRemoteDevice(
    String host,
    int port, {
    ValueChanged<_RemoteAddStage>? onStageChanged,
  }) async {
    final server = _server;
    final localDeviceId = _nearby.deviceId;
    if (server == null || localDeviceId == null) return '本地服务尚未就绪';
    onStageChanged?.call(_RemoteAddStage.resolving);
    String address;
    try {
      address = InternetAddress.tryParse(host) != null
          ? host
          : (await InternetAddress.lookup(host, type: InternetAddressType.IPv4)
                  .timeout(const Duration(seconds: 4)))
              .first
              .address;
    } catch (_) {
      return '无法解析 $host';
    }
    if (address == _tailscaleAddress || address == _address) {
      return '这是本机地址';
    }
    final peer = await LocalTransferServer.probe(address, port);
    if (peer == null) {
      return '连不上 $address:$port，请确认对方已打开 SendHere 且 Tailscale 在线';
    }
    if (peer.id == localDeviceId) return '这是本机';
    onStageChanged?.call(_RemoteAddStage.found);
    // Older builds don't report their ID; fall back to an address-based key.
    final deviceId = peer.id ?? 'tailscale:$address';
    final name = peer.name;
    if (server.hasPeer(deviceId) || server.hasDevice(deviceId)) {
      onStageChanged?.call(_RemoteAddStage.connected);
      return null;
    }
    server.updatePeerEndpoint(
      deviceId: deviceId,
      deviceName: name,
      address: address,
      port: port,
      localDeviceId: localDeviceId,
    );
    try {
      onStageChanged?.call(_RemoteAddStage.connecting);
      // This always dials, ignoring the deviceId tie-break used elsewhere:
      // the remote side has never heard of us yet (a manual add is
      // one-directional), so it cannot possibly dial back on its own. Once
      // our identify message reaches it below, both sides store each
      // other's Tailscale address and id, and every reconnect after this
      // one (ours and theirs, in _reconnectTailscalePeers) is governed by
      // the same tie-break, so the connection stays single-dialer from here.
      await server.connectToPeer(
        deviceId: deviceId,
        deviceName: name,
        address: address,
        peerPort: port,
        localDeviceId: localDeviceId,
      );
    } catch (error) {
      return '连接失败：$error';
    }
    onStageChanged?.call(_RemoteAddStage.connected);
    return null;
  }

  Future<void> _offerFiles() async {
    try {
      if (Platform.isIOS || Platform.isAndroid) {
        final source = await showModalBottomSheet<_AttachmentSource>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('选择照片'),
                subtitle: const Text('支持多选图片'),
                onTap: () =>
                    Navigator.of(context).pop(_AttachmentSource.photos),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('选择文件'),
                subtitle: const Text('任意文件类型'),
                onTap: () => Navigator.of(context).pop(_AttachmentSource.files),
              ),
              const SizedBox(height: 8),
            ]),
          ),
        );
        if (source == null) return;
        if (source == _AttachmentSource.photos) {
          final photos = await ImagePicker().pickMultiImage();
          await _sendSelectedMobileFiles(
            photos.map((file) => file.path).toList(),
          );
          return;
        }
        final files = await openFiles();
        await _sendSelectedMobileFiles(files.map((file) => file.path).toList());
        return;
      }
      final files = await openFiles();
      await _addFilesToPending(files.map((file) => file.path).toList());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法添加文件：$error')));
      }
    }
  }

  Future<void> _sendSelectedMobileFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    await _addFilesToPending(paths);
    await _sendPending();
  }

  Future<void> _addFilesToPending(List<String> paths) async {
    final peerId = _selectedPeerId;
    if (peerId == null || paths.isEmpty) return;
    final text = _textController.text;
    setState(() {
      final items = _pendingItems.putIfAbsent(peerId, () => []);
      if (text.trim().isNotEmpty) items.add(_PendingItem.text(text));
      items.addAll(paths.map(_PendingItem.file));
      _drafts.remove(peerId);
      _textController.clear();
    });
  }

  void _replacePendingCompose(List<NativeComposeItem> composeItems) {
    final peerId = _selectedPeerId;
    if (peerId == null) return;
    setState(() {
      _pendingItems[peerId] = composeItems
          .map((item) => item.text != null
              ? _PendingItem.text(item.text!)
              : _PendingItem.file(item.filePath!))
          .toList();
      _drafts.remove(peerId);
      _textController.clear();
    });
  }

  void _removePendingItem(int index) {
    final peerId = _selectedPeerId;
    final items = peerId == null ? null : _pendingItems[peerId];
    if (items == null || index >= items.length) return;
    setState(() => items.removeAt(index));
  }

  void _editPendingText(int index) {
    final peerId = _selectedPeerId;
    final items = peerId == null ? null : _pendingItems[peerId];
    if (items == null || index >= items.length || items[index].text == null) {
      return;
    }
    final text = items[index].text!;
    setState(() {
      items.removeAt(index);
      _textController.text = text;
      _drafts[peerId!] = text;
    });
  }

  Future<void> _sendPending() async {
    final peerId = _selectedPeerId;
    final device = peerId == null ? null : _connectedPeers[peerId];
    final outboxDirectory = _outboxDirectory;
    if (peerId == null || device == null || outboxDirectory == null) return;
    final text = _textController.text;
    if (text.trim().isNotEmpty) {
      setState(() {
        _pendingItems
            .putIfAbsent(peerId, () => [])
            .add(_PendingItem.text(text));
        _drafts.remove(peerId);
        _textController.clear();
      });
    }
    final items = List<_PendingItem>.from(_pendingItems[peerId] ?? []);
    if (items.isEmpty) return;
    setState(() => _pendingItems.remove(peerId));
    for (final item in items) {
      final id = Outbox.newId();
      final outboxItem = item.text != null
          ? OutboxItem(
              id: id,
              deviceId: peerId,
              deviceName: device.name,
              createdAt: DateTime.now(),
              type: TransferEventType.text,
              text: item.text,
              status: FileTransferStatus.waiting,
            )
          : await _outboxFileItem(
              id, peerId, device.name, item.path!, outboxDirectory);
      await _outbox.add(outboxItem);
      if (mounted) {
        setState(() => _events.insert(0, _eventForOutbox(outboxItem)));
      }
    }
    unawaited(_deliverOutbox(peerId));
  }

  Future<OutboxItem> _outboxFileItem(String id, String deviceId,
      String deviceName, String sourcePath, Directory outboxDirectory) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw StateError('所选照片已无法读取，请重新选择');
    }
    final archived = await _outbox.archiveFile(source, outboxDirectory);
    if (await archived.length() == 0) {
      await _deleteArchivedFile(archived.path);
      throw StateError('所选照片为空，无法发送');
    }
    return OutboxItem(
      id: id,
      deviceId: deviceId,
      deviceName: deviceName,
      createdAt: DateTime.now(),
      type: TransferEventType.file,
      filePath: archived.path,
      fileName: path.basename(sourcePath),
      fileSize: await archived.length(),
      status: FileTransferStatus.waiting,
    );
  }

  TransferEvent _eventForOutbox(OutboxItem item) => TransferEvent(
        type: item.type,
        direction: TransferDirection.sent,
        createdAt: item.createdAt,
        clientName: item.deviceName,
        deviceId: item.deviceId,
        text: item.text,
        fileName: item.fileName,
        fileSize: item.fileSize,
        localPath: item.filePath,
        transferId: item.id,
        fileStatus: item.status,
      );

  Future<void> _deliverOutbox(String deviceId) async {
    final server = _server;
    if (server == null ||
        !server.hasDevice(deviceId) ||
        _sendingOutboxDeviceIds.contains(deviceId)) {
      return;
    }
    _sendingOutboxDeviceIds.add(deviceId);
    try {
      // Failed transfers stay visible for the user to retry or cancel, but must
      // not prevent a newly selected photo/file from being delivered.
      final items = _outbox.items
          .where((item) =>
              item.deviceId == deviceId &&
              item.status != FileTransferStatus.failed)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final item in items) {
        if (!server.hasDevice(deviceId)) break;
        try {
          await _setOutboxStatus(item, FileTransferStatus.uploading);
          if (item.isFile) {
            final file = File(item.filePath!);
            if (!await file.exists()) {
              throw StateError('待发送文件已不存在');
            }
            await server.offerFileToDevice(
              deviceId,
              file,
              transferId: item.id,
              fileName: item.fileName,
            );
          } else {
            await server.sendTextToDevice(
              deviceId,
              item.text!,
              transferId: item.id,
            );
          }
          await _outbox.remove(item.id);
          // Images keep their app-owned copy: thumbnails, preview and the
          // later "save" action all read it. Other files are not needed once
          // delivered, so their copy is removed to avoid growing storage.
          if (item.isFile &&
              item.filePath != null &&
              !isImageFileName(item.fileName)) {
            await _deleteArchivedFile(item.filePath!);
          }
        } catch (error) {
          await _setOutboxStatus(
            item,
            FileTransferStatus.failed,
            errorMessage: '$error',
          );
          break;
        }
      }
    } finally {
      _sendingOutboxDeviceIds.remove(deviceId);
    }
  }

  Future<void> _setOutboxStatus(
    OutboxItem item,
    FileTransferStatus status, {
    String? errorMessage,
  }) async {
    await _outbox.updateStatus(item.id, status);
    if (!mounted) return;
    final index = _events.indexWhere((event) => event.transferId == item.id);
    if (index < 0) return;
    setState(() {
      _events[index] = TransferEvent(
        type: item.type,
        direction: TransferDirection.sent,
        createdAt: item.createdAt,
        clientName: item.deviceName,
        deviceId: item.deviceId,
        text: item.text,
        fileName: item.fileName,
        fileSize: item.fileSize,
        localPath: item.filePath,
        transferId: item.id,
        fileStatus: status,
        errorMessage: errorMessage,
      );
    });
  }

  Future<void> _retryOutboxItem(String transferId) async {
    OutboxItem? item;
    for (final candidate in _outbox.items) {
      if (candidate.id == transferId) {
        item = candidate;
        break;
      }
    }
    if (item == null || item.status == FileTransferStatus.uploading) return;
    await _setOutboxStatus(item, FileTransferStatus.waiting);
    unawaited(_deliverOutbox(item.deviceId));
  }

  Future<void> _cancelOutboxItem(String transferId) async {
    OutboxItem? item;
    for (final candidate in _outbox.items) {
      if (candidate.id == transferId) {
        item = candidate;
        break;
      }
    }
    if (item == null || item.status == FileTransferStatus.uploading) return;
    await _outbox.remove(transferId);
    if (item.isFile && item.filePath != null) {
      await _deleteArchivedFile(item.filePath!);
    }
    if (!mounted) return;
    setState(
        () => _events.removeWhere((event) => event.transferId == transferId));
  }

  Future<void> _deleteArchivedFile(String filePath) async {
    final root = _outboxDirectory;
    if (root == null) return;
    final archiveDirectory = path.join(root.path, 'outbox');
    if (!path.isWithin(archiveDirectory, filePath)) return;
    final file = File(filePath);
    if (await file.exists()) await file.delete();
  }

  Future<void> _selectPeer(String id) async {
    if (_unreadCounts.remove(id) != null) {
      unawaited(_saveUnreadCounts());
      unawaited(_updateNotificationBadge());
    }
    final previousId = _selectedPeerId;
    if (previousId != null) {
      _drafts[previousId] = _textController.text;
    }
    if (!mounted) return;
    setState(() {
      _selectedPeerId = id;
      _textController.text = _drafts[id] ?? '';
    });
  }

  void _showPhoneConnectPanel() {
    final server = _server;
    if (server == null || _address == null) return;
    // Never present a QR code that may have expired while the app was open.
    // This deliberately keeps existing phone sessions alive.
    server.refreshToken(disconnectExisting: false);
    setState(() => _phoneQrExpanded = true);
  }

  Future<void> _showMobileConnectQr() async {
    final server = _server;
    final address = _address;
    if (server == null || address == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先连接 Wi‑Fi，才能生成局域网连接二维码')),
      );
      return;
    }
    server.refreshToken(disconnectExisting: false);
    final url = 'http://$address:${server.port}/?token=${server.token}';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('连接此手机',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('让同一局域网内的设备扫码，即可在浏览器中发送文本和文件。',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13)),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black12),
              ),
              child: QrImageView(data: url, size: 220),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('连接链接已复制')),
                  );
                }
              },
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: const Text('复制连接链接'),
            ),
          ]),
        ),
      ),
    );
  }

  void _hidePhoneConnectPanel() => setState(() => _phoneQrExpanded = false);

  void _openMobileConversation(String id) {
    _selectPeer(id);
    setState(() => _showMobileConversation = true);
  }

  Future<void> _deleteConversation(String deviceId) async {
    if (_unreadCounts.remove(deviceId) != null) {
      unawaited(_saveUnreadCounts());
      unawaited(_updateNotificationBadge());
    }
    final removedOutboxItems = await _outbox.removeForDevice(deviceId);
    for (final item in removedOutboxItems) {
      if (item.isFile && item.filePath != null) {
        await _deleteArchivedFile(item.filePath!);
      }
    }
    await _history.removeDevice(deviceId);
    await _server?.disconnectPeer(deviceId);
    if (!mounted) return;
    setState(() {
      _connectedPeers.remove(deviceId);
      _events.removeWhere((event) => event.deviceId == deviceId);
      _drafts.remove(deviceId);
      _pendingItems.remove(deviceId);
      _connectingPeerIds.remove(deviceId);
      if (_selectedPeerId == deviceId) _selectedPeerId = null;
      if (_showMobileConversation) _showMobileConversation = false;
    });
    await _saveRecentDevices();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _conversationDropChannel.setMethodCallHandler(null);
    _updateChannel.setMethodCallHandler(null);
    _updateTimer?.cancel();
    _tailscaleReconnectTimer?.cancel();
    _subscription?.cancel();
    _nearbySubscription?.cancel();
    _nearby.dispose();
    _server?.stop();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    final mobile = Platform.isIOS || Platform.isAndroid;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: mobile ? kToolbarHeight : 12,
        automaticallyImplyLeading: false,
        leading: mobile && _showMobileConversation
            ? IconButton(
                tooltip: '返回设备列表',
                icon: const Icon(Icons.arrow_back),
                onPressed: () =>
                    setState(() => _showMobileConversation = false),
              )
            : null,
        actions: mobile && !_showMobileConversation
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: IconButton.filledTonal(
                    tooltip: '连接此手机',
                    onPressed: _showMobileConnectQr,
                    icon: const Icon(Icons.add),
                  ),
                ),
              ]
            : null,
        title: mobile
            ? _showMobileConversation
                ? _MobileConversationTitle(
                    name: _selectedPeerId == null
                        ? '消息'
                        : _connectedPeers[_selectedPeerId]?.name ?? '消息',
                    online: _selectedPeerId != null &&
                        _connectedPeers[_selectedPeerId]?.online == true,
                    transport: _selectedPeerId == null
                        ? null
                        : _connectedPeers[_selectedPeerId]?.transport,
                    tailscaleAddress: _selectedPeerId == null
                        ? null
                        : _connectedPeers[_selectedPeerId]?.tailscaleAddress,
                  )
                : const Text('SendHere',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))
            : null,
      ),
      body: Padding(
        padding: EdgeInsets.all(mobile ? 0 : 16),
        child: _error != null
            ? _ErrorView(error: _error!, retry: _startServer)
            : _server == null
                ? const Center(child: CircularProgressIndicator())
                : url == null
                    ? _NoLanView(retry: _startServer)
                    : LayoutBuilder(builder: (context, constraints) {
                        final sidebar = _DeviceSidebar(
                          url: url,
                          qrNetworkToggle:
                              _address != null && _tailscaleAddress != null
                                  ? _QrNetworkToggle(
                                      useTailscale: _qrUseTailscale,
                                      onChanged: _setQrUseTailscale,
                                    )
                                  : null,
                          qrViaTailscale: _qrAddress == _tailscaleAddress,
                          addRemoteDevice: mobile ? null : _showAddRemoteDevice,
                          connectedPeers: _connectedPeers.values.toList(),
                          connectingPeerIds: _connectingPeerIds,
                          unreadCounts: _unreadCounts,
                          selectedPeerId: _selectedPeerId,
                          selectPeer:
                              mobile ? _openMobileConversation : _selectPeer,
                          connectPhone: _showPhoneConnectPanel,
                          showPhoneConnection: !mobile,
                          phoneQrExpanded: _phoneQrExpanded,
                          hidePhoneQr: _hidePhoneConnectPanel,
                          deleteConversation: _deleteConversation,
                          notificationPermission: _notificationPermission,
                          requestNotificationPermission: () =>
                              _refreshNotificationPermission(request: true),
                          openNotificationSettings: _openNotificationSettings,
                        );
                        final conversation = _ConversationPanel(
                          key: ValueKey(
                              'conversation-${_selectedPeerId ?? 'none'}'),
                          controller: _textController,
                          events: _events,
                          sendPending: _sendPending,
                          offerFiles: _offerFiles,
                          pendingItems: _selectedPeerId == null
                              ? const []
                              : List.unmodifiable(
                                  _pendingItems[_selectedPeerId] ?? const []),
                          removePendingItem: _removePendingItem,
                          editPendingText: _editPendingText,
                          addDroppedFiles: _addFilesToPending,
                          replacePendingCompose: _replacePendingCompose,
                          cancelOutboxItem: _cancelOutboxItem,
                          retryOutboxItem: _retryOutboxItem,
                          selectedPeerId: _selectedPeerId,
                          selectedPeerName: _selectedPeerId == null
                              ? null
                              : _connectedPeers[_selectedPeerId]?.name,
                          online: _selectedPeerId != null &&
                              _connectedPeers[_selectedPeerId]?.online == true,
                          draft: _selectedPeerId == null
                              ? ''
                              : _drafts[_selectedPeerId] ?? '',
                          onDraftChanged: (value) {
                            final id = _selectedPeerId;
                            if (id != null) _drafts[id] = value;
                          },
                          onMobileBack: mobile
                              ? () => setState(
                                  () => _showMobileConversation = false)
                              : null,
                          transport: _selectedPeerId == null
                              ? null
                              : _connectedPeers[_selectedPeerId]?.transport,
                          tailscaleAddress: _selectedPeerId == null
                              ? null
                              : _connectedPeers[_selectedPeerId]
                                  ?.tailscaleAddress,
                        );
                        if (mobile) {
                          return AnimatedSwitcher(
                            duration: const Duration(milliseconds: 260),
                            reverseDuration: const Duration(milliseconds: 220),
                            transitionBuilder: (child, animation) {
                              final conversationChild =
                                  child.key == const ValueKey('conversation');
                              final offset = Tween<Offset>(
                                begin: conversationChild
                                    ? const Offset(1, 0)
                                    : const Offset(-0.12, 0),
                                end: Offset.zero,
                              ).animate(CurvedAnimation(
                                parent: animation,
                                curve: Curves.easeOutCubic,
                                reverseCurve: Curves.easeInCubic,
                              ));
                              return SlideTransition(
                                  position: offset, child: child);
                            },
                            child: _showMobileConversation
                                ? KeyedSubtree(
                                    key: const ValueKey('conversation'),
                                    child: conversation,
                                  )
                                : KeyedSubtree(
                                    key: const ValueKey('devices'),
                                    child: sidebar,
                                  ),
                          );
                        }
                        return Row(children: [
                          SizedBox(width: 300, child: sidebar),
                          const SizedBox(width: 16),
                          Expanded(child: conversation),
                        ]);
                      }),
      ),
    );
  }
}

enum _AttachmentSource { photos, files }

/// Progress stages shown in the "添加远程电脑" dialog while _addRemoteDevice
/// resolves the host, probes it, and dials the WebSocket connection.
enum _RemoteAddStage { resolving, found, connecting, connected }

/// Shows the current _RemoteAddStage as a row of three labelled steps
/// (已找到 → 正在建立连接 → 已连接), the current one highlighted. "resolving"
/// (DNS lookup) has no step of its own; it reads as "已找到" not yet reached.
class _RemoteAddProgress extends StatelessWidget {
  const _RemoteAddProgress({required this.stage});

  final _RemoteAddStage stage;

  static const _steps = ['已找到', '正在建立连接', '已连接'];

  int get _activeIndex => switch (stage) {
        _RemoteAddStage.resolving => -1,
        _RemoteAddStage.found => 0,
        _RemoteAddStage.connecting => 1,
        _RemoteAddStage.connected => 2,
      };

  @override
  Widget build(BuildContext context) {
    final activeIndex = _activeIndex;
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      children: List.generate(_steps.length * 2 - 1, (index) {
        if (index.isOdd) {
          final completed = index ~/ 2 < activeIndex;
          return Expanded(
            child: Container(
              height: 2,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: completed
                  ? accent
                  : Theme.of(context).colorScheme.outlineVariant,
            ),
          );
        }
        final stepIndex = index ~/ 2;
        final reached = stepIndex <= activeIndex;
        final current = stepIndex == activeIndex;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 16,
            height: 16,
            child: current
                ? CircularProgressIndicator(strokeWidth: 2, color: accent)
                : Icon(
                    reached ? Icons.check_circle : Icons.circle_outlined,
                    size: 16,
                    color: reached
                        ? accent
                        : Theme.of(context).colorScheme.outlineVariant,
                  ),
          ),
          const SizedBox(height: 4),
          Text(_steps[stepIndex],
              style: TextStyle(
                  fontSize: 11,
                  color: reached
                      ? accent
                      : Theme.of(context).colorScheme.onSurfaceVariant)),
        ]);
      }),
    );
  }
}

class _PendingItem {
  const _PendingItem._({this.text, this.path});

  factory _PendingItem.text(String value) => _PendingItem._(text: value);
  factory _PendingItem.file(String value) => _PendingItem._(path: value);

  final String? text;
  final String? path;
  bool get isFile => path != null;
}

class _PeerDevice {
  const _PeerDevice({
    required this.id,
    required this.name,
    required this.online,
    required this.lastSeenAt,
    this.tailscaleAddress,
    this.port,
    this.transport,
  });
  final String id;
  final String name;
  final bool online;
  final DateTime lastSeenAt;

  /// Remembered Tailscale address of a computer peer, used to reconnect when
  /// it is not discoverable on the LAN.
  final String? tailscaleAddress;
  final int? port;

  /// How this computer peer is currently routed (LAN vs Tailscale). Null for
  /// phones, and for a computer peer whose transport isn't known yet. Not
  /// persisted: it only reflects the live socket, which setState always
  /// refreshes from LocalTransferServer.peerTransport() on every connection
  /// event, so a stale value from a previous session is never shown.
  final PeerTransport? transport;

  _PeerDevice copyWith({
    String? name,
    bool? online,
    DateTime? lastSeenAt,
    String? tailscaleAddress,
    int? port,
    PeerTransport? transport,
    bool clearTransport = false,
  }) =>
      _PeerDevice(
        id: id,
        name: name ?? this.name,
        online: online ?? this.online,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        tailscaleAddress: tailscaleAddress ?? this.tailscaleAddress,
        port: port ?? this.port,
        transport: clearTransport ? null : (transport ?? this.transport),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lastSeenAt': lastSeenAt.toIso8601String(),
        if (tailscaleAddress != null) 'tailscaleAddress': tailscaleAddress,
        if (port != null) 'port': port,
      };

  factory _PeerDevice.fromJson(Map<String, dynamic> json) => _PeerDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        online: false,
        lastSeenAt: DateTime.tryParse(json['lastSeenAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        tailscaleAddress: json['tailscaleAddress'] as String?,
        port: json['port'] as int?,
      );
}

class _DeviceSidebar extends StatefulWidget {
  const _DeviceSidebar({
    required this.url,
    required this.qrNetworkToggle,
    required this.qrViaTailscale,
    required this.addRemoteDevice,
    required this.connectedPeers,
    required this.connectingPeerIds,
    required this.unreadCounts,
    required this.selectedPeerId,
    required this.selectPeer,
    required this.connectPhone,
    required this.showPhoneConnection,
    required this.phoneQrExpanded,
    required this.hidePhoneQr,
    required this.deleteConversation,
    required this.notificationPermission,
    required this.requestNotificationPermission,
    required this.openNotificationSettings,
  });

  final String url;
  final Widget? qrNetworkToggle;
  final bool qrViaTailscale;
  final VoidCallback? addRemoteDevice;
  final List<_PeerDevice> connectedPeers;
  final Set<String> connectingPeerIds;
  final Map<String, int> unreadCounts;
  final String? selectedPeerId;
  final ValueChanged<String> selectPeer;
  final VoidCallback connectPhone;
  final bool showPhoneConnection;
  final bool phoneQrExpanded;
  final VoidCallback hidePhoneQr;
  final ValueChanged<String> deleteConversation;
  final String? notificationPermission;
  final VoidCallback requestNotificationPermission;
  final VoidCallback openNotificationSettings;

  @override
  State<_DeviceSidebar> createState() => _DeviceSidebarState();
}

class _DeviceSidebarState extends State<_DeviceSidebar> {
  String? _revealedDeviceId;

  void _collapseActions() {
    if (_revealedDeviceId != null) setState(() => _revealedDeviceId = null);
  }

  List<_PeerDevice> get _sortedPeers => List<_PeerDevice>.from(
        widget.connectedPeers,
      )..sort((a, b) {
          if (a.online != b.online) return a.online ? -1 : 1;
          return b.lastSeenAt.compareTo(a.lastSeenAt);
        });

  @override
  Widget build(BuildContext context) {
    final peers = _sortedPeers;
    final mobile = Platform.isIOS || Platform.isAndroid;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _collapseActions,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 18, 16, 10),
            child: Text('设备列表',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          if (mobile &&
              widget.notificationPermission != null &&
              widget.notificationPermission != 'authorized' &&
              widget.notificationPermission != 'provisional')
            _NotificationPermissionBanner(
              permission: widget.notificationPermission!,
              requestPermission: widget.requestNotificationPermission,
              openSettings: widget.openNotificationSettings,
            ),
          Expanded(
            child: widget.connectedPeers.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无设备\n附近电脑会自动显示在这里',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black54)),
                    ),
                  )
                : ListView.separated(
                    itemCount: peers.length,
                    itemBuilder: (context, index) {
                      final device = peers[index];
                      return _DeviceTile(
                        device: device,
                        unreadCount: widget.unreadCounts[device.id] ?? 0,
                        selected: !mobile && widget.selectedPeerId == device.id,
                        select: (id) {
                          _collapseActions();
                          widget.selectPeer(id);
                        },
                        deleteConversation: widget.deleteConversation,
                        revealed: _revealedDeviceId == device.id,
                        reveal: () =>
                            setState(() => _revealedDeviceId = device.id),
                        collapse: _collapseActions,
                        connecting:
                            widget.connectingPeerIds.contains(device.id),
                      );
                    },
                    separatorBuilder: (_, __) => mobile
                        ? Divider(
                            height: 1,
                            thickness: 0.5,
                            indent: 72,
                            color: Theme.of(context)
                                .dividerColor
                                .withValues(alpha: 0.55),
                          )
                        : const SizedBox.shrink(),
                  ),
          ),
          if (widget.showPhoneConnection) ...[
            const Divider(height: 1),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: widget.phoneQrExpanded
                  ? _PhoneConnectCard(
                      url: widget.url,
                      networkToggle: widget.qrNetworkToggle,
                      viaTailscale: widget.qrViaTailscale,
                      onCollapse: widget.hidePhoneQr)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      child: Row(children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: widget.connectPhone,
                            icon: const Icon(Icons.phone_iphone_outlined),
                            label: const Text('手机'),
                          ),
                        ),
                        if (widget.addRemoteDevice != null) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: widget.addRemoteDevice,
                              icon: const Icon(Icons.add_link, size: 18),
                              label: const Text('远程电脑'),
                            ),
                          ),
                        ],
                      ]),
                    ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _NotificationPermissionBanner extends StatelessWidget {
  const _NotificationPermissionBanner({
    required this.permission,
    required this.requestPermission,
    required this.openSettings,
  });

  final String permission;
  final VoidCallback requestPermission;
  final VoidCallback openSettings;

  @override
  Widget build(BuildContext context) {
    final denied = permission == 'denied';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            const Icon(Icons.notifications_off_outlined, size: 19),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                denied ? '通知已关闭，后台短暂可接收的消息不会显示提醒。' : '开启通知，以便收到局域网消息时显示提醒。',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: denied ? openSettings : requestPermission,
              child: Text(denied ? '去设置' : '开启'),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, this.compact = false});

  final int count;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    final fontSize = compact ? 9.0 : 11.0;
    final wide = count > 9;
    final height = compact ? 16.0 : 22.0;
    return SizedBox(
      width: wide ? (compact ? 24 : 28) : height,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.red,
          borderRadius: BorderRadius.circular(height / 2),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceAvatar extends StatelessWidget {
  const _DeviceAvatar({
    required this.phone,
    required this.online,
    required this.unreadCount,
  });

  final bool phone;
  final bool online;
  final int unreadCount;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              backgroundColor: online
                  ? null
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(phone
                  ? Icons.phone_iphone_outlined
                  : Icons.computer_outlined),
            ),
            if (unreadCount > 0)
              Positioned(
                top: -2,
                right: -3,
                child: _UnreadBadge(count: unreadCount, compact: true),
              ),
          ],
        ),
      );
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.unreadCount,
    required this.selected,
    required this.select,
    required this.deleteConversation,
    required this.revealed,
    required this.reveal,
    required this.collapse,
    this.connecting = false,
  });

  final _PeerDevice device;
  final int unreadCount;
  final bool selected;
  final ValueChanged<String> select;
  final ValueChanged<String> deleteConversation;
  final bool revealed;
  final VoidCallback reveal;
  final VoidCallback collapse;

  /// Whether a dial to this device (fresh connect or LAN upgrade) is
  /// currently in flight, per `_HomeScreenState._connectingPeerIds`.
  final bool connecting;

  /// "在线 · 局域网" / "在线 · Tailscale 远程" / "连接中 · Tailscale" / "离线 · X前".
  /// A phone has no transport concept, so it only ever shows online/offline.
  String _statusLabel(BuildContext context) {
    if (connecting) {
      return device.transport == PeerTransport.tailscale
          ? '连接中 · Tailscale'
          : '连接中…';
    }
    if (!device.online) return _lastSeenLabel(context, device.lastSeenAt);
    switch (device.transport) {
      case PeerTransport.lan:
        return '在线 · 局域网';
      case PeerTransport.tailscale:
        return '在线 · Tailscale 远程';
      case null:
        return '在线';
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = device.name.contains('手机') || device.name.contains('iPhone');
    final statusLabel = _statusLabel(context);
    final tile = Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: ListTile(
        selected: selected,
        selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
        leading: _DeviceAvatar(
          phone: phone,
          online: device.online,
          unreadCount: unreadCount,
        ),
        minVerticalPadding: 7,
        title: Text(device.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: Text(statusLabel, style: const TextStyle(fontSize: 12)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            device.online
                ? const Icon(Icons.circle, size: 10, color: Colors.green)
                : Icon(
                    Icons.cloud_off_outlined,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
          ],
        ),
        onTap: () => select(device.id),
      ),
    );
    if (Platform.isIOS || Platform.isAndroid) {
      return _SwipeConversationTile(
        deviceId: device.id,
        confirmDelete: () => _confirmDelete(context),
        deleteConversation: deleteConversation,
        revealed: revealed,
        reveal: reveal,
        collapse: collapse,
        revealedChild: Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: ListTile(
            minVerticalPadding: 7,
            title: Text(
              device.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            subtitle: Text(statusLabel, style: const TextStyle(fontSize: 12)),
          ),
        ),
        child: tile,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (details) {
        select(device.id);
        _showDesktopMenu(context, details);
      },
      child: tile,
    );
  }

  Future<bool?> _confirmDelete(BuildContext context) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除会话？'),
          content: Text(
              '删除与“${device.name}”的本机聊天记录和待发送内容。\n\n已接收的文件不会被删除；设备再次被发现时仍会显示。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除')),
          ],
        ),
      );

  Future<void> _showDesktopMenu(
    BuildContext context,
    TapDownDetails details,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(
            details.globalPosition.dx, details.globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      menuPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      items: [
        const _RoundedMenuItem(value: 'open', child: Text('打开会话')),
        _RoundedMenuItem(
          value: 'delete',
          color: Theme.of(context).colorScheme.error,
          child: const Text('删除会话'),
        ),
      ],
    );
    if (!context.mounted) return;
    if (value == 'open') {
      select(device.id);
    } else if (value == 'delete' && await _confirmDelete(context) == true) {
      if (context.mounted) deleteConversation(device.id);
    }
  }

  String _lastSeenLabel(BuildContext context, DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return '刚刚在线';
    if (difference.inHours < 1) return '${difference.inMinutes} 分钟前在线';
    if (difference.inDays == 0) {
      return '今天 ${TimeOfDay.fromDateTime(time).format(context)} 在线';
    }
    if (difference.inDays == 1) {
      return '昨天 ${TimeOfDay.fromDateTime(time).format(context)} 在线';
    }
    return '${time.year}/${time.month}/${time.day} 在线';
  }
}

class _RoundedMenuItem extends PopupMenuItem<String> {
  const _RoundedMenuItem({
    required super.value,
    required super.child,
    this.color,
  });

  final Color? color;

  @override
  PopupMenuItemState<String, _RoundedMenuItem> createState() =>
      _RoundedMenuItemState();
}

class _RoundedMenuItemState
    extends PopupMenuItemState<String, _RoundedMenuItem> {
  static const _radius = BorderRadius.all(Radius.circular(7));

  @override
  Widget build(BuildContext context) {
    final textStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(color: widget.color);
    return Semantics(
      enabled: widget.enabled,
      button: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Material(
          color: Colors.transparent,
          borderRadius: _radius,
          child: InkWell(
            borderRadius: _radius,
            onTap: widget.enabled ? handleTap : null,
            child: SizedBox(
              height: 42,
              child: Center(
                child: DefaultTextStyle.merge(
                  style: textStyle,
                  child: buildChild() ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwipeConversationTile extends StatefulWidget {
  const _SwipeConversationTile({
    required this.deviceId,
    required this.confirmDelete,
    required this.deleteConversation,
    required this.revealed,
    required this.reveal,
    required this.collapse,
    required this.child,
    required this.revealedChild,
  });

  final String deviceId;
  final Future<bool?> Function() confirmDelete;
  final ValueChanged<String> deleteConversation;
  final bool revealed;
  final VoidCallback reveal;
  final VoidCallback collapse;
  final Widget child;
  final Widget revealedChild;

  @override
  State<_SwipeConversationTile> createState() => _SwipeConversationTileState();
}

class _SwipeConversationTileState extends State<_SwipeConversationTile> {
  static const _actionWidth = 88.0;
  double _dragOffset = 0;

  void _handleDragUpdate(DragUpdateDetails details) {
    if (widget.revealed) return;
    setState(() {
      _dragOffset = (_dragOffset + details.delta.dx).clamp(-_actionWidth, 0.0);
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    if (widget.revealed) {
      if (details.velocity.pixelsPerSecond.dx > 250) widget.collapse();
      return;
    }
    final shouldReveal = _dragOffset.abs() > _actionWidth / 2 ||
        details.velocity.pixelsPerSecond.dx < -450;
    setState(() => _dragOffset = 0);
    if (shouldReveal) widget.reveal();
  }

  Future<void> _delete() async {
    if (await widget.confirmDelete() != true || !mounted) return;
    widget.deleteConversation(widget.deviceId);
  }

  Widget _deleteAction(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.error,
        child: InkWell(
          onTap: _delete,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.onError),
              const SizedBox(height: 2),
              Text('删除',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onError)),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 72,
        child: ClipRect(
          child: Stack(
            children: [
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                width: _actionWidth,
                child: _deleteAction(context),
              ),
              Positioned.fill(
                right: widget.revealed ? _actionWidth : 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: widget.revealed ? widget.collapse : null,
                  onHorizontalDragUpdate: _handleDragUpdate,
                  onHorizontalDragEnd: _handleDragEnd,
                  child: Transform.translate(
                    offset: Offset(widget.revealed ? 0 : _dragOffset, 0),
                    child:
                        widget.revealed ? widget.revealedChild : widget.child,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _PhoneConnectCard extends StatelessWidget {
  const _PhoneConnectCard({
    required this.url,
    required this.networkToggle,
    required this.viaTailscale,
    required this.onCollapse,
  });

  final String url;
  final Widget? networkToggle;
  final bool viaTailscale;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Icon(Icons.phone_iphone_outlined, size: 18),
            const SizedBox(width: 7),
            const Expanded(
              child: Text('连接手机',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            IconButton(
              tooltip: '收起',
              icon: const Icon(Icons.keyboard_arrow_down),
              visualDensity: VisualDensity.compact,
              onPressed: onCollapse,
            ),
          ]),
          const SizedBox(height: 2),
          Text(
              viaTailscale
                  ? '手机需开启 Tailscale，用系统相机扫一扫，不在同一 Wi‑Fi 也能传。'
                  : '用系统相机或微信扫一扫，无需安装 App。',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          if (networkToggle != null) ...[
            const SizedBox(height: 8),
            networkToggle!,
          ],
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.black12),
            ),
            child: QrImageView(data: url, size: 132),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onCollapse,
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            label: const Text('收起二维码'),
          ),
        ]),
      );
}

/// Switches the phone QR code between the LAN and the Tailscale address.
class _QrNetworkToggle extends StatelessWidget {
  const _QrNetworkToggle({required this.useTailscale, required this.onChanged});

  final bool useTailscale;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(
              value: false,
              icon: Icon(Icons.wifi, size: 16),
              label: Text('局域网')),
          ButtonSegment(
              value: true,
              icon: Icon(Icons.vpn_lock_outlined, size: 16),
              label: Text('Tailscale')),
        ],
        selected: {useTailscale},
        onSelectionChanged: (values) => onChanged(values.first),
      );
}

class _MobileConversationTitle extends StatelessWidget {
  const _MobileConversationTitle({
    required this.name,
    required this.online,
    this.transport,
    this.tailscaleAddress,
  });

  final String name;
  final bool online;
  final PeerTransport? transport;
  final String? tailscaleAddress;

  @override
  Widget build(BuildContext context) {
    final viaTailscale = online && transport == PeerTransport.tailscale;
    return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          if (viaTailscale) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: tailscaleAddress == null
                  ? '通过 Tailscale 远程连接\n回到同一 Wi-Fi 后自动切换到局域网'
                  : '通过 Tailscale 远程连接（$tailscaleAddress）\n回到同一 Wi-Fi 后自动切换到局域网',
              child: Icon(Icons.vpn_lock_outlined,
                  size: 17,
                  color: Theme.of(context).colorScheme.onSecondaryContainer),
            ),
          ],
          const SizedBox(width: 7),
          Tooltip(
            message: online ? '在线' : '离线',
            child: Icon(
              online ? Icons.circle : Icons.cloud_off_outlined,
              size: online ? 10 : 18,
              color: online
                  ? Colors.green
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
  }
}

/// Desktop conversation header: the peer's name plus, for a computer peer
/// connected over Tailscale, a "通过 Tailscale 连接" chip whose tooltip shows
/// the actual address and reminds the user it will switch back to LAN
/// automatically. Mobile shows the equivalent in the AppBar title instead
/// (_MobileConversationTitle), so this is desktop-only.
class _ConversationHeader extends StatelessWidget {
  const _ConversationHeader({
    required this.name,
    required this.online,
    this.transport,
    this.tailscaleAddress,
  });

  final String name;
  final bool online;
  final PeerTransport? transport;
  final String? tailscaleAddress;

  @override
  Widget build(BuildContext context) {
    final viaTailscale = online && transport == PeerTransport.tailscale;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
      child: Row(children: [
        Expanded(
          child: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
        if (viaTailscale)
          Tooltip(
            message: tailscaleAddress == null
                ? '通过 Tailscale 远程连接\n回到同一 Wi-Fi 后自动切换到局域网'
                : '通过 Tailscale 远程连接（$tailscaleAddress）\n回到同一 Wi-Fi 后自动切换到局域网',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.vpn_lock_outlined,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSecondaryContainer),
                const SizedBox(width: 4),
                Text('通过 Tailscale 连接',
                    style: TextStyle(
                        fontSize: 11,
                        color:
                            Theme.of(context).colorScheme.onSecondaryContainer)),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _ConversationPanel extends StatefulWidget {
  const _ConversationPanel({
    super.key,
    required this.controller,
    required this.events,
    required this.sendPending,
    required this.offerFiles,
    required this.pendingItems,
    required this.removePendingItem,
    required this.editPendingText,
    required this.addDroppedFiles,
    required this.replacePendingCompose,
    required this.cancelOutboxItem,
    required this.retryOutboxItem,
    required this.selectedPeerId,
    required this.selectedPeerName,
    required this.online,
    required this.draft,
    required this.onDraftChanged,
    this.onMobileBack,
    this.transport,
    this.tailscaleAddress,
  });

  final TextEditingController controller;
  final List<TransferEvent> events;
  final Future<void> Function() sendPending;
  final Future<void> Function() offerFiles;
  final List<_PendingItem> pendingItems;
  final ValueChanged<int> removePendingItem;
  final ValueChanged<int> editPendingText;
  final ValueChanged<List<String>> addDroppedFiles;
  final ValueChanged<List<NativeComposeItem>> replacePendingCompose;
  final ValueChanged<String> cancelOutboxItem;
  final ValueChanged<String> retryOutboxItem;
  final String? selectedPeerId;
  final String? selectedPeerName;
  final bool online;
  final String draft;
  final ValueChanged<String> onDraftChanged;
  final VoidCallback? onMobileBack;

  /// How the selected computer peer is currently routed. Null for a phone
  /// conversation or when the peer's transport isn't known.
  final PeerTransport? transport;

  /// The peer's Tailscale address, shown in the header tooltip so a user
  /// dealing with a connection issue can see exactly what SendHere dialed.
  final String? tailscaleAddress;

  @override
  State<_ConversationPanel> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends State<_ConversationPanel> {
  static const _minimumComposeHeight = 96.0;
  static const _maximumComposeHeight = 180.0;

  final _nativeFieldKey = GlobalKey<NativeTextFieldState>();
  final _scrollController = ScrollController();
  double _composeHeight = _minimumComposeHeight;
  static const _backGestureEdgeWidth = 56.0;
  static const _backGestureDistance = 42.0;
  bool _startedAtLeadingEdge = false;
  Offset? _backGestureStart;
  int? _backGesturePointer;
  double _backDragOffset = 0;

  @override
  void initState() {
    super.initState();
    _scrollToLatestAfterLayout();
  }

  @override
  void didUpdateWidget(covariant _ConversationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scrollToLatestAfterLayout();
  }

  void _scrollToLatestAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom(animate: false);
      });
    });
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.position.minScrollExtent;
    if (!animate) {
      _scrollController.jumpTo(offset);
      return;
    }
    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
    _nativeFieldKey.currentState?.unfocus();
  }

  void _focusInput() {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _nativeFieldKey.currentState?.focus());
  }

  void _submit(String value) {
    developer.log('Submitting ${value.length} characters',
        name: 'SendHere.Input');
    widget.controller.text = value;
    // Sending is always an enqueue operation. The input must therefore clear
    // identically whether the device is connected now or will receive it later.
    unawaited(widget.sendPending());
    widget.onDraftChanged('');
    // AppKit platform views can retain their drawing after Flutter clears the
    // draft. Clear the currently mounted NSTextView directly as well.
    _nativeFieldKey.currentState?.clear();
  }

  @override
  Widget build(BuildContext context) {
    final peerId = widget.selectedPeerId;
    if (peerId == null || widget.selectedPeerName == null) {
      return const Card(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.forum_outlined, size: 52),
            SizedBox(height: 14),
            Text('选择一台已连接设备开始对话'),
            SizedBox(height: 6),
            Text('附近电脑会自动出现；可通过左下角二维码连接手机',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54)),
          ]),
        ),
      );
    }
    final messages = widget.events
        .where((event) =>
            event.deviceId == peerId &&
            event.type != TransferEventType.clientConnected &&
            event.type != TransferEventType.clientDisconnected)
        .toList();
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        // Keep this comfortably inside the screen rather than requiring the
        // physical edge: a phone case often makes the outermost pixels awkward
        // to reach. Track the pointer directly so child image gestures cannot
        // make a fast swipe miss the back action.
        _startedAtLeadingEdge = event.position.dx <= _backGestureEdgeWidth;
        _backGesturePointer = _startedAtLeadingEdge ? event.pointer : null;
        _backGestureStart = _startedAtLeadingEdge ? event.position : null;
        if (_startedAtLeadingEdge) _backDragOffset = 0;
      },
      onPointerMove: (event) {
        if (!_startedAtLeadingEdge ||
            event.pointer != _backGesturePointer ||
            widget.onMobileBack == null) {
          return;
        }
        final start = _backGestureStart;
        if (start == null) return;
        setState(() {
          _backDragOffset = (event.position.dx - start.dx).clamp(0, 420);
        });
      },
      onPointerUp: (event) {
        if (event.pointer != _backGesturePointer) return;
        final start = _backGestureStart;
        // Use the final pointer position too. Fast iOS swipes can coalesce
        // movement events immediately before the finger lifts.
        final distance = start == null ? 0.0 : event.position.dx - start.dx;
        final shouldGoBack = _startedAtLeadingEdge &&
            distance >= _backGestureDistance &&
            widget.onMobileBack != null;
        _startedAtLeadingEdge = false;
        _backGesturePointer = null;
        _backGestureStart = null;
        if (shouldGoBack) {
          widget.onMobileBack!();
        } else {
          setState(() => _backDragOffset = 0);
        }
      },
      onPointerCancel: (event) {
        if (event.pointer != _backGesturePointer) return;
        _startedAtLeadingEdge = false;
        _backGesturePointer = null;
        _backGestureStart = null;
        setState(() => _backDragOffset = 0);
      },
      child: Transform.translate(
        offset: Offset(_backDragOffset, 0),
        child: Card(
          clipBehavior: Clip.antiAlias,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!(Platform.isIOS || Platform.isAndroid))
              _ConversationHeader(
                name: widget.selectedPeerName!,
                online: widget.online,
                transport: widget.transport,
                tailscaleAddress: widget.tailscaleAddress,
              ),
            Expanded(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => _dismissKeyboard(),
                child: messages.isEmpty
                    ? Center(
                        child:
                            Text(widget.online ? '还没有消息，开始发送吧。' : '该设备暂时不可用'),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.all(18),
                        itemCount: messages.length,
                        itemBuilder: (_, index) => _MessageBubble(
                          event: messages[index],
                          cancelOutboxItem: widget.cancelOutboxItem,
                          retryOutboxItem: widget.retryOutboxItem,
                        ),
                      ),
              ),
            ),
            const Divider(height: 1),
            Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black26),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                  child: NativeTextField(
                    key: _nativeFieldKey,
                    initialText: widget.draft,
                    composeItems: widget.pendingItems
                        .map((item) => item.isFile
                            ? NativeComposeItem.file(
                                item.path!, path.basename(item.path!))
                            : NativeComposeItem.text(item.text!))
                        .toList(),
                    height: _composeHeight,
                    onContentHeightChanged: (contentHeight) {
                      final nextHeight = contentHeight.clamp(
                        _minimumComposeHeight,
                        _maximumComposeHeight,
                      );
                      if ((nextHeight - _composeHeight).abs() > 0.5) {
                        setState(() => _composeHeight = nextHeight);
                      }
                    },
                    onFilesDropped: (paths) {
                      widget.addDroppedFiles(paths);
                      _focusInput();
                    },
                    onComposeChanged: widget.replacePendingCompose,
                    onChanged: (value) {
                      widget.controller.text = value;
                      widget.onDraftChanged(value);
                    },
                    onSubmitted: _submit,
                  ),
                ),
                if (!Platform.isMacOS && !Platform.isWindows)
                  const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 8, 4),
                  child: Row(children: [
                    Tooltip(
                      message: '添加附件',
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          hoverColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          onTap: () async {
                            await widget.offerFiles();
                            if (Platform.isMacOS) _focusInput();
                          },
                          child: SizedBox(
                            width: 34,
                            height: 32,
                            child: Icon(
                              Platform.isMacOS || Platform.isWindows
                                  ? Icons.folder_open_outlined
                                  : Icons.add_circle_outline,
                              size: Platform.isMacOS || Platform.isWindows
                                  ? 18
                                  : 25,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                        onPressed: () => _submit(widget.controller.text),
                        icon: const Icon(Icons.send),
                        label: const Text('发送')),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.event,
    required this.cancelOutboxItem,
    required this.retryOutboxItem,
  });
  final TransferEvent event;
  final ValueChanged<String> cancelOutboxItem;
  final ValueChanged<String> retryOutboxItem;

  @override
  Widget build(BuildContext context) {
    final sent = event.direction == TransferDirection.sent;
    final file = event.type == TransferEventType.file;
    final image = file && _isImage(event.fileName);
    final scheme = Theme.of(context).colorScheme;
    final time = TimeOfDay.fromDateTime(event.createdAt).format(context);
    return Align(
      alignment: sent ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment:
                sent ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: sent
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: file
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        InkWell(
                          onTap: event.localPath == null
                              ? null
                              : image
                                  ? () => _showImagePreview(
                                        context,
                                        event.localPath!,
                                        event.fileName ?? '图片',
                                      )
                                  : () => _openReceivedFile(
                                        context,
                                        event.localPath!,
                                      ),
                          onLongPress: event.localPath == null || !image
                              ? null
                              : () => _showImageActions(
                                    context,
                                    event.localPath!,
                                    event.fileName ?? '图片',
                                  ),
                          onSecondaryTapDown: event.localPath == null || !image
                              ? null
                              : (details) => _showImageActions(
                                    context,
                                    event.localPath!,
                                    event.fileName ?? '图片',
                                    position: details.globalPosition,
                                  ),
                          child: image && event.localPath != null
                              ? ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 360),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(File(event.localPath!),
                                        height: 180,
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) =>
                                            _FileLabel(name: event.fileName)),
                                  ),
                                )
                              : _FileLabel(name: event.fileName),
                        ),
                        if (sent &&
                            event.transferId != null &&
                            event.fileStatus !=
                                FileTransferStatus.completed) ...[
                          const SizedBox(height: 10),
                          _TransferProgress(
                            event: event,
                            retry: event.fileStatus == FileTransferStatus.failed
                                ? () => retryOutboxItem(event.transferId!)
                                : null,
                            cancel: event.fileStatus ==
                                        FileTransferStatus.waiting ||
                                    event.fileStatus ==
                                        FileTransferStatus.failed
                                ? () => cancelOutboxItem(event.transferId!)
                                : null,
                          ),
                        ],
                      ])
                    : MessageText(event.text ?? ''),
              ),
              const SizedBox(height: 3),
              Text(
                file &&
                        sent &&
                        event.transferId != null &&
                        event.fileStatus != FileTransferStatus.completed
                    ? time
                    : _messageStatus(sent, event, time),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _messageStatus(bool sent, TransferEvent event, String time) {
    if (sent && event.transferId != null) {
      return switch (event.fileStatus) {
        FileTransferStatus.waiting => '等待设备上线 · $time',
        FileTransferStatus.uploading => '正在发送 · $time',
        FileTransferStatus.completed => '已送达 · $time',
        FileTransferStatus.failed => '发送失败 · $time',
      };
    }
    return '${sent ? '已发送' : '已接收'} · $time';
  }

  bool _isImage(String? fileName) => isImageFileName(fileName);
}

class _TransferProgress extends StatelessWidget {
  const _TransferProgress({required this.event, this.retry, this.cancel});
  final TransferEvent event;
  final VoidCallback? retry;
  final VoidCallback? cancel;

  @override
  Widget build(BuildContext context) {
    final total = event.fileSize ?? 0;
    final sent = event.bytesTransferred ?? 0;
    final progress = total == 0 ? 0.0 : (sent / total).clamp(0.0, 1.0);
    final waiting = event.fileStatus == FileTransferStatus.waiting;
    final failed = event.fileStatus == FileTransferStatus.failed;
    final completed = event.fileStatus == FileTransferStatus.completed;
    final color = failed
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    final label = waiting
        ? '等待设备上线'
        : failed
            ? '发送失败${event.errorMessage == null ? '' : '：${event.errorMessage}'}'
            : completed
                ? '已送达 · ${_formatBytes(total)}'
                : '发送中 ${(progress * 100).round()}% · ${_formatBytes(sent)} / ${_formatBytes(total)}';
    return SizedBox(
      width: 280,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LinearProgressIndicator(
          value: waiting ? null : (completed || failed ? 1 : progress),
          minHeight: 5,
          borderRadius: BorderRadius.circular(4),
          color: color,
          backgroundColor:
              Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        const SizedBox(height: 5),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          if (retry != null) ...[
            TextButton(
              onPressed: retry,
              style: const ButtonStyle(
                overlayColor: WidgetStatePropertyAll(Colors.transparent),
                minimumSize: WidgetStatePropertyAll(Size(0, 22)),
                padding: WidgetStatePropertyAll(EdgeInsets.zero),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity(horizontal: -4, vertical: -4),
              ),
              child: const Text('重新发送', style: TextStyle(fontSize: 12)),
            ),
          ],
          if (retry != null && cancel != null) const SizedBox(width: 8),
          if (cancel != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              child: Text('|',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline)),
            ),
            TextButton(
              onPressed: cancel,
              style: ButtonStyle(
                foregroundColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.hovered)
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurfaceVariant),
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                minimumSize: const WidgetStatePropertyAll(Size(0, 22)),
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity:
                    const VisualDensity(horizontal: -4, vertical: -4),
              ),
              child: const Text('取消发送', style: TextStyle(fontSize: 12)),
            ),
          ],
        ]),
      ]),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _FileLabel extends StatelessWidget {
  const _FileLabel({required this.name});
  final String? name;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.insert_drive_file_outlined),
          const SizedBox(width: 8),
          Flexible(
              child: Text(name ?? '文件',
                  maxLines: 2, overflow: TextOverflow.ellipsis)),
        ]),
      );
}

/// Shown when the local server is running but no Wi-Fi/Ethernet LAN address
/// was found, instead of an endless spinner.
class _NoLanView extends StatelessWidget {
  const _NoLanView({required this.retry});
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off, size: 48),
            const SizedBox(height: 12),
            const Text('未检测到 Wi‑Fi 局域网地址',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('请连接与电脑相同的 Wi‑Fi（或开启热点），然后点击重试。',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: retry, child: const Text('重试')),
          ]),
        ),
      );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.retry});
  final String error;
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 12),
          Text('无法启动本地服务：$error'),
          const SizedBox(height: 12),
          FilledButton(onPressed: retry, child: const Text('重试')),
        ]),
      );
}
