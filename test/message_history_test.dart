import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:send_here/src/message_history.dart';
import 'package:send_here/src/transfer_event.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sendhere-history');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  TransferEvent text(String value, {String device = 'phone', DateTime? at}) =>
      TransferEvent(
        type: TransferEventType.text,
        createdAt: at ?? DateTime.now(),
        text: value,
        deviceId: device,
        clientName: 'Phone',
      );

  test('restores received texts and files after reload', () async {
    final history = MessageHistory();
    await history.load(directory);
    await history.record(text('hello'));
    await history.record(TransferEvent(
      type: TransferEventType.file,
      createdAt: DateTime.now(),
      fileName: 'a.pdf',
      fileSize: 3,
      localPath: '/tmp/a.pdf',
      deviceId: 'phone',
    ));

    final reloaded = MessageHistory();
    await reloaded.load(directory);
    expect(reloaded.items.map((e) => e.text ?? e.fileName), ['hello', 'a.pdf']);
    expect(reloaded.items.last.localPath, '/tmp/a.pdf');
  });

  test('skips connection events and unfinished transfers', () async {
    final history = MessageHistory();
    await history.load(directory);
    await history.record(TransferEvent(
        type: TransferEventType.clientConnected,
        createdAt: DateTime.now(),
        deviceId: 'phone'));
    await history.record(TransferEvent(
      type: TransferEventType.file,
      direction: TransferDirection.sent,
      createdAt: DateTime.now(),
      fileName: 'b.zip',
      localPath: '/tmp/b.zip',
      deviceId: 'phone',
      transferId: 't1',
      fileStatus: FileTransferStatus.uploading,
    ));
    expect(history.items, isEmpty);
  });

  test('replaces entries by transferId and trims per device', () async {
    final history = MessageHistory(maxPerDevice: 2);
    await history.load(directory);
    final base = DateTime(2026);
    for (var i = 0; i < 3; i++) {
      await history.record(text('m$i', at: base.add(Duration(minutes: i))));
    }
    await history.record(text('other', device: 'mac'));
    expect(history.items.where((e) => e.deviceId == 'phone').map((e) => e.text),
        ['m1', 'm2']);

    final sent = TransferEvent(
      type: TransferEventType.text,
      direction: TransferDirection.sent,
      createdAt: base,
      text: 'v1',
      deviceId: 'mac',
      transferId: 'x',
    );
    await history.record(sent);
    await history.record(TransferEvent(
      type: TransferEventType.text,
      direction: TransferDirection.sent,
      createdAt: base,
      text: 'v2',
      deviceId: 'mac',
      transferId: 'x',
    ));
    expect(history.items.where((e) => e.transferId == 'x').single.text, 'v2');

    await history.removeDevice('mac');
    final reloaded = MessageHistory();
    await reloaded.load(directory);
    expect(reloaded.items.every((e) => e.deviceId == 'phone'), isTrue);
  });

  test('a corrupt history file does not throw', () async {
    await File('${directory.path}/message-history-v1.json')
        .writeAsString('{not json');
    final history = MessageHistory();
    await history.load(directory);
    expect(history.items, isEmpty);
  });
}
