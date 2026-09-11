import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import 'transfer_event.dart';

class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.createdAt,
    required this.type,
    this.text,
    this.filePath,
    this.fileName,
    this.fileSize,
    this.status = FileTransferStatus.waiting,
  });

  final String id;
  final String deviceId;
  final String deviceName;
  final DateTime createdAt;
  final TransferEventType type;
  final String? text;
  final String? filePath;
  final String? fileName;
  final int? fileSize;
  final FileTransferStatus status;

  bool get isFile => type == TransferEventType.file;

  OutboxItem copyWith({FileTransferStatus? status}) => OutboxItem(
        id: id,
        deviceId: deviceId,
        deviceName: deviceName,
        createdAt: createdAt,
        type: type,
        text: text,
        filePath: filePath,
        fileName: fileName,
        fileSize: fileSize,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'createdAt': createdAt.toIso8601String(),
        'type': type.name,
        'text': text,
        'filePath': filePath,
        'fileName': fileName,
        'fileSize': fileSize,
        'status': status.name,
      };

  factory OutboxItem.fromJson(Map<String, dynamic> json) => OutboxItem(
        id: json['id'] as String,
        deviceId: json['deviceId'] as String,
        deviceName: json['deviceName'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        type: TransferEventType.values.byName(json['type'] as String),
        text: json['text'] as String?,
        filePath: json['filePath'] as String?,
        fileName: json['fileName'] as String?,
        fileSize: json['fileSize'] as int?,
        // Uploading cannot survive an app restart: the socket stream has ended.
        // Restore such entries as waiting so a later connection can retry them.
        status: Outbox.restoredStatus(json['status'] as String?),
      );
}

class Outbox {
  static const _key = 'sendhere-outbox-v1';
  final List<OutboxItem> _items = [];
  List<OutboxItem> get items => List.unmodifiable(_items);

  Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return;
    try {
      _items
        ..clear()
        ..addAll((jsonDecode(raw) as List<dynamic>).map(
            (value) => OutboxItem.fromJson(value as Map<String, dynamic>)));
    } catch (_) {
      _items.clear();
    }
  }

  Future<void> add(OutboxItem item) async {
    _items.add(item);
    await _save();
  }

  Future<void> remove(String id) async {
    _items.removeWhere((item) => item.id == id);
    await _save();
  }

  Future<List<OutboxItem>> removeForDevice(String deviceId) async {
    final removed = _items.where((item) => item.deviceId == deviceId).toList();
    _items.removeWhere((item) => item.deviceId == deviceId);
    await _save();
    return removed;
  }

  Future<void> updateStatus(String id, FileTransferStatus status) async {
    final index = _items.indexWhere((item) => item.id == id);
    if (index >= 0) {
      _items[index] = _items[index].copyWith(status: status);
      await _save();
    }
  }

  Future<File> archiveFile(File source, Directory root) async {
    final id = _id();
    final directory = Directory(path.join(root.path, 'outbox'));
    await directory.create(recursive: true);
    final destination =
        File(path.join(directory.path, '$id-${path.basename(source.path)}'));
    await source.copy(destination.path);
    return destination;
  }

  static FileTransferStatus restoredStatus(String? value) {
    final status = FileTransferStatus.values.byName(
      value ?? FileTransferStatus.waiting.name,
    );
    return status == FileTransferStatus.uploading
        ? FileTransferStatus.waiting
        : status;
  }

  static String newId() => _id();
  static String _id() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random.secure().nextInt(1 << 32).toRadixString(36)}';

  Future<void> _save() async =>
      (await SharedPreferences.getInstance()).setString(
          _key, jsonEncode(_items.map((item) => item.toJson()).toList()));
}
