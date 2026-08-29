import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:send_here/src/outbox.dart';
import 'package:send_here/src/transfer_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('persists queued items and restores interrupted transfers as waiting',
      () async {
    final outbox = Outbox();
    final item = OutboxItem(
      id: 'queued-text',
      deviceId: 'mac-mini',
      deviceName: 'Mac mini',
      createdAt: DateTime(2026, 8, 29, 12),
      type: TransferEventType.text,
      text: '稍后发送的文字',
      status: FileTransferStatus.uploading,
    );

    await outbox.add(item);

    final restored = Outbox();
    await restored.load();
    expect(restored.items, hasLength(1));
    expect(restored.items.single.id, item.id);
    expect(restored.items.single.text, item.text);
    expect(restored.items.single.status, FileTransferStatus.waiting);
  });

  test('archives an owned copy so the original can be removed', () async {
    final root = await Directory.systemTemp.createTemp('sendhere-outbox-');
    final source = File('${root.path}${Platform.pathSeparator}original.txt');
    await source.writeAsString('SendHere outbox');
    addTearDown(() => root.delete(recursive: true));

    final archived = await Outbox().archiveFile(source, root);
    await source.delete();

    expect(await archived.exists(), isTrue);
    expect(await archived.readAsString(), 'SendHere outbox');
    expect(archived.path,
        contains('${Platform.pathSeparator}outbox${Platform.pathSeparator}'));
  });

  test('updates and removes only the requested queued item', () async {
    final outbox = Outbox();
    final first = OutboxItem(
      id: 'first',
      deviceId: 'device-a',
      deviceName: 'Device A',
      createdAt: DateTime(2026, 8, 29, 12),
      type: TransferEventType.text,
      text: 'first',
    );
    final second = OutboxItem(
      id: 'second',
      deviceId: 'device-a',
      deviceName: 'Device A',
      createdAt: DateTime(2026, 8, 29, 13),
      type: TransferEventType.text,
      text: 'second',
    );
    await outbox.add(first);
    await outbox.add(second);

    await outbox.updateStatus('first', FileTransferStatus.failed);
    await outbox.remove('second');

    expect(outbox.items, hasLength(1));
    expect(outbox.items.single.id, 'first');
    expect(outbox.items.single.status, FileTransferStatus.failed);
  });
}
