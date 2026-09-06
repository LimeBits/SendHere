import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_name.dart';
import 'local_transfer_server.dart';
import 'nearby_device_service.dart';
import 'native_text_field.dart';
import 'outbox.dart';
import 'transfer_event.dart';

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

class _SendHereHomeState extends State<SendHereHome> {
  final _events = <TransferEvent>[];
  final _textController = TextEditingController();
  final _nearby = NearbyDeviceService();
  final _connectedPeers = <String, _PeerDevice>{};
  final _drafts = <String, String>{};
  final _pendingItems = <String, List<_PendingItem>>{};
  final _outbox = Outbox();
  final _sendingOutboxDeviceIds = <String>{};
  Directory? _outboxDirectory;
  LocalTransferServer? _server;
  StreamSubscription<TransferEvent>? _subscription;
  StreamSubscription<List<NearbyDevice>>? _nearbySubscription;
  final _connectingPeerIds = <String>{};
  final _discoveredComputerIds = <String>{};
  String? _address;
  String? _error;
  String? _selectedPeerId;
  bool _phoneQrExpanded = false;

  static const _recentDevicesKey = 'sendhere-recent-devices';
  static const _conversationDropChannel =
      MethodChannel('sendhere/conversation_drop');

  @override
  void initState() {
    super.initState();
    _conversationDropChannel.setMethodCallHandler((call) async {
      if (call.method == 'filesDropped') {
        final paths = (call.arguments as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList();
        await _addFilesToPending(paths);
      }
    });
    _loadInitialState().whenComplete(_startServer);
  }

  Future<void> _loadInitialState() async {
    _outboxDirectory = await getApplicationSupportDirectory();
    await _outbox.load();
    _events.addAll(_outbox.items.map(_eventForOutbox));
    await _loadRecentDevices();
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
      await _server?.stop();
      final downloads = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final server = LocalTransferServer(
        downloadDirectory: Directory(path.join(downloads.path, 'SendHere')),
        deviceName: await DeviceName.current(),
      );
      await server.start();
      _subscription = server.events.listen((event) {
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
              _connectedPeers[event.deviceId!] = _PeerDevice(
                  id: event.deviceId!,
                  name: event.clientName!,
                  online: true,
                  lastSeenAt: DateTime.now());
              _selectedPeerId ??= event.deviceId;
            } else if (event.type == TransferEventType.clientDisconnected) {
              final device = _connectedPeers[event.deviceId!];
              if (device != null) {
                _connectedPeers[event.deviceId!] =
                    device.copyWith(online: false, lastSeenAt: DateTime.now());
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
      if (mounted) {
        setState(() {
          _server = server;
          _address = addresses.isEmpty ? null : addresses.first;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  String? get _url {
    if (_server == null || _address == null) return null;
    return 'http://$_address:${_server!.port}/?token=${_server!.token}';
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
          _connectedPeers[id] =
              existing.copyWith(online: false, lastSeenAt: DateTime.now());
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
        _connectedPeers[device.id] = _PeerDevice(
          id: device.id,
          name: device.name,
          // mDNS only proves the device is nearby. A device becomes online
          // after its peer WebSocket is ready to transfer text and files.
          online: _server?.hasDevice(device.id) ?? false,
          lastSeenAt: DateTime.now(),
        );
        if (existing == null && _selectedPeerId == null) {
          _selectedPeerId = device.id;
        }
      }
    });
    _saveRecentDevices();

    for (final id in disappearedIds) {
      unawaited(_server?.disconnectPeer(id) ?? Future<void>.value());
    }

    // Only one side dials. The other side receives that peer's WebSocket,
    // preventing duplicate sessions when both computers discover each other.
    if (localDeviceId == null) return;
    for (final device in devices) {
      if (localDeviceId.compareTo(device.id) < 0) {
        unawaited(_connectPeer(device));
      }
    }
  }

  Future<bool> _connectPeer(NearbyDevice device) async {
    if (_server == null ||
        _nearby.deviceId == null ||
        _server!.hasPeer(device.id) ||
        _connectingPeerIds.contains(device.id)) {
      return false;
    }
    setState(() => _connectingPeerIds.add(device.id));
    try {
      await _server!.connectToPeer(
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
            _connectedPeers[device.id] =
                existing.copyWith(online: _server!.hasDevice(device.id));
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

  Future<void> _offerFiles() async {
    try {
      final files = await openFiles();
      await _addFilesToPending(files.map((file) => file.path).toList());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法添加文件：$error')));
      }
    }
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
    final archived =
        await _outbox.archiveFile(File(sourcePath), outboxDirectory);
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
      final items = _outbox.items
          .where((item) => item.deviceId == deviceId)
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
          // A phone receives a download URL, not the file bytes. Its browser may
          // download much later, so retain the archived source while this app is
          // running. Mac-to-Mac uploads have completed at this point and can be
          // safely removed.
          if (item.isFile && server.hasPeer(deviceId)) {
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

  void _hidePhoneConnectPanel() => setState(() => _phoneQrExpanded = false);

  @override
  void dispose() {
    _conversationDropChannel.setMethodCallHandler(null);
    _subscription?.cancel();
    _nearbySubscription?.cancel();
    _nearby.stop();
    _server?.stop();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 12,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _error != null
            ? _ErrorView(error: _error!, retry: _startServer)
            : _server == null || url == null
                ? const Center(child: CircularProgressIndicator())
                : Row(children: [
                    SizedBox(
                      width: 300,
                      child: _DeviceSidebar(
                        url: url,
                        connectedPeers: _connectedPeers.values.toList(),
                        selectedPeerId: _selectedPeerId,
                        selectPeer: _selectPeer,
                        connectPhone: _showPhoneConnectPanel,
                        phoneQrExpanded: _phoneQrExpanded,
                        hidePhoneQr: _hidePhoneConnectPanel,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _ConversationPanel(
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
                      ),
                    ),
                  ]),
      ),
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
  });
  final String id;
  final String name;
  final bool online;
  final DateTime lastSeenAt;

  _PeerDevice copyWith({String? name, bool? online, DateTime? lastSeenAt}) =>
      _PeerDevice(
        id: id,
        name: name ?? this.name,
        online: online ?? this.online,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lastSeenAt': lastSeenAt.toIso8601String(),
      };

  factory _PeerDevice.fromJson(Map<String, dynamic> json) => _PeerDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        online: false,
        lastSeenAt: DateTime.tryParse(json['lastSeenAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

class _DeviceSidebar extends StatelessWidget {
  const _DeviceSidebar({
    required this.url,
    required this.connectedPeers,
    required this.selectedPeerId,
    required this.selectPeer,
    required this.connectPhone,
    required this.phoneQrExpanded,
    required this.hidePhoneQr,
  });

  final String url;
  final List<_PeerDevice> connectedPeers;
  final String? selectedPeerId;
  final ValueChanged<String> selectPeer;
  final VoidCallback connectPhone;
  final bool phoneQrExpanded;
  final VoidCallback hidePhoneQr;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 18, 16, 10),
            child: Text('设备列表',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: connectedPeers.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无设备\n附近电脑会自动显示在这里',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black54)),
                    ),
                  )
                : ListView(
                    children: (List<_PeerDevice>.from(connectedPeers)
                          ..sort((a, b) {
                            if (a.online != b.online) return a.online ? -1 : 1;
                            return b.lastSeenAt.compareTo(a.lastSeenAt);
                          }))
                        .map((device) => _DeviceTile(
                            device: device,
                            selected: selectedPeerId == device.id,
                            select: selectPeer))
                        .toList(),
                  ),
          ),
          const Divider(height: 1),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: phoneQrExpanded
                ? _PhoneConnectCard(url: url, onCollapse: hidePhoneQr)
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton.icon(
                      onPressed: connectPhone,
                      icon: const Icon(Icons.phone_iphone_outlined),
                      label: const Text('连接手机'),
                    ),
                  ),
          ),
        ]),
      );
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.selected,
    required this.select,
  });

  final _PeerDevice device;
  final bool selected;
  final ValueChanged<String> select;

  @override
  Widget build(BuildContext context) {
    final phone = device.name.contains('手机') || device.name.contains('iPhone');
    return ListTile(
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
      leading: CircleAvatar(
          backgroundColor: device.online
              ? null
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(
              phone ? Icons.phone_iphone_outlined : Icons.computer_outlined)),
      minVerticalPadding: 7,
      title: Text(device.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(
          device.online ? '在线' : _lastSeenLabel(context, device.lastSeenAt),
          style: const TextStyle(fontSize: 12)),
      trailing: device.online
          ? const Icon(Icons.circle, size: 10, color: Colors.green)
          : const Icon(Icons.cloud_off_outlined),
      onTap: () => select(device.id),
    );
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

class _PhoneConnectCard extends StatelessWidget {
  const _PhoneConnectCard({required this.url, required this.onCollapse});

  final String url;
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
          const Text('用系统相机或微信扫一扫，无需安装 App。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black54)),
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

class _ConversationPanel extends StatefulWidget {
  const _ConversationPanel({
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
    required this.selectedPeerId,
    required this.selectedPeerName,
    required this.online,
    required this.draft,
    required this.onDraftChanged,
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
  final String? selectedPeerId;
  final String? selectedPeerName;
  final bool online;
  final String draft;
  final ValueChanged<String> onDraftChanged;

  @override
  State<_ConversationPanel> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends State<_ConversationPanel> {
  static const _minimumComposeHeight = 96.0;
  static const _maximumComposeHeight = 180.0;

  final _nativeFieldKey = GlobalKey<NativeTextFieldState>();
  final _scrollController = ScrollController();
  double _composeHeight = _minimumComposeHeight;

  @override
  void didUpdateWidget(covariant _ConversationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // New incoming/outgoing records are prepended in the app state, but the
    // conversation is rendered oldest-to-newest. Keep the latest message in
    // view after a send, receive, or selected-device switch.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
        .toList()
        .reversed
        .toList();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Text(widget.online ? '还没有消息，开始发送吧。' : '该设备暂时不可用'),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(18),
                  itemCount: messages.length,
                  itemBuilder: (_, index) => _MessageBubble(
                    event: messages[index],
                    cancelOutboxItem: widget.cancelOutboxItem,
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
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 8, 4),
              child: Row(children: [
                IconButton(
                  tooltip: '发送文件',
                  onPressed: () async {
                    await widget.offerFiles();
                    _focusInput();
                  },
                  icon: const Icon(Icons.attach_file),
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
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.event, required this.cancelOutboxItem});
  final TransferEvent event;
  final ValueChanged<String> cancelOutboxItem;

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
                              : () =>
                                  Process.run('open', ['-R', event.localPath!]),
                          child: image && event.localPath != null
                              ? ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 360),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(File(event.localPath!),
                                        height: 180,
                                        fit: BoxFit.fitHeight,
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
                            cancel: event.fileStatus ==
                                        FileTransferStatus.waiting ||
                                    event.fileStatus ==
                                        FileTransferStatus.failed
                                ? () => cancelOutboxItem(event.transferId!)
                                : null,
                          ),
                        ],
                      ])
                    : SelectableText(event.text ?? ''),
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

  bool _isImage(String? fileName) {
    const extensions = {
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.bmp',
      '.heic'
    };
    final name = fileName?.toLowerCase() ?? '';
    return extensions.any(name.endsWith);
  }
}

class _TransferProgress extends StatelessWidget {
  const _TransferProgress({required this.event, this.cancel});
  final TransferEvent event;
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
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                minimumSize: const Size(0, 22),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
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
