import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'transfer_event.dart';

/// Persists finished conversation messages (texts and completed files, both
/// directions) so bubbles survive an app restart. Pending outgoing items are
/// owned by [Outbox]; this store only keeps what has already happened.
///
/// Stored as a JSON file in the app support directory rather than
/// SharedPreferences: the history can grow to hundreds of entries and
/// SharedPreferences rewrites/loads its whole store on every access.
class MessageHistory {
  MessageHistory({this.maxPerDevice = 500});

  final int maxPerDevice;
  final List<TransferEvent> _items = [];
  File? _file;
  Future<void> _pendingWrite = Future.value();

  List<TransferEvent> get items => List.unmodifiable(_items);

  Future<void> load(Directory directory) async {
    _file = File(path.join(directory.path, 'message-history-v1.json'));
    _items.clear();
    try {
      if (!await _file!.exists()) return;
      final decoded = jsonDecode(await _file!.readAsString()) as List<dynamic>;
      for (final value in decoded) {
        final event = eventFromJson(value as Map<String, dynamic>);
        if (event != null) _items.add(event);
      }
    } catch (_) {
      // A corrupt history must never prevent SendHere from starting.
      _items.clear();
    }
  }

  /// Whether [event] is a finished message worth keeping.
  static bool isPersistable(TransferEvent event) {
    if (event.deviceId == null) return false;
    if (event.type == TransferEventType.text) {
      return (event.text ?? '').isNotEmpty;
    }
    if (event.type == TransferEventType.file) {
      return event.fileStatus == FileTransferStatus.completed &&
          event.localPath != null;
    }
    return false;
  }

  /// Adds [event], replacing an earlier entry with the same transferId (a
  /// sent file goes uploading → completed under one id).
  Future<void> record(TransferEvent event) async {
    if (!isPersistable(event)) return;
    final id = event.transferId;
    final index =
        id == null ? -1 : _items.indexWhere((item) => item.transferId == id);
    if (index >= 0) {
      _items[index] = event;
    } else {
      _items.add(event);
    }
    _trim(event.deviceId!);
    await _save();
  }

  Future<void> removeDevice(String deviceId) async {
    _items.removeWhere((item) => item.deviceId == deviceId);
    await _save();
  }

  void _trim(String deviceId) {
    final forDevice = _items.where((item) => item.deviceId == deviceId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final excess = forDevice.length - maxPerDevice;
    if (excess <= 0) return;
    final drop = forDevice.take(excess).toSet();
    _items.removeWhere(drop.contains);
  }

  /// Serialises writes so two quick events cannot interleave and leave a
  /// truncated file; writes to a temp file then renames for atomicity.
  Future<void> _save() {
    final file = _file;
    if (file == null) return Future.value();
    final snapshot = jsonEncode(_items.map(eventToJson).toList());
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(snapshot, flush: true);
        await temp.rename(file.path);
      } catch (_) {
        // Losing one history write is preferable to crashing a transfer.
      }
    });
    return _pendingWrite;
  }

  static Map<String, dynamic> eventToJson(TransferEvent event) => {
        'type': event.type.name,
        'direction': event.direction.name,
        'createdAt': event.createdAt.toIso8601String(),
        'clientName': event.clientName,
        'deviceId': event.deviceId,
        'text': event.text,
        'fileName': event.fileName,
        'fileSize': event.fileSize,
        'localPath': event.localPath,
        'transferId': event.transferId,
        'isComputerPeer': event.isComputerPeer,
      };

  static TransferEvent? eventFromJson(Map<String, dynamic> json) {
    try {
      return TransferEvent(
        type: TransferEventType.values.byName(json['type'] as String),
        direction: TransferDirection.values.byName(json['direction'] as String),
        createdAt: DateTime.parse(json['createdAt'] as String),
        clientName: json['clientName'] as String?,
        deviceId: json['deviceId'] as String?,
        text: json['text'] as String?,
        fileName: json['fileName'] as String?,
        fileSize: json['fileSize'] as int?,
        localPath: json['localPath'] as String?,
        transferId: json['transferId'] as String?,
        isComputerPeer: json['isComputerPeer'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}
