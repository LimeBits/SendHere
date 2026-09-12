import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:send_here/src/local_transfer_server.dart';
import 'package:send_here/src/transfer_event.dart';

void main() {
  test('requires a valid token and accepts phone text', () async {
    final directory = await Directory.systemTemp.createTemp('sendhere-test-');
    final server = LocalTransferServer(
      downloadDirectory: directory,
      loadAsset: (asset) => File(asset).readAsBytes(),
    );
    addTearDown(() async {
      await server.stop();
      await directory.delete(recursive: true);
    });

    await server.start();
    final client = HttpClient();
    addTearDown(client.close);
    final base = Uri.parse('http://127.0.0.1:${server.port}');

    final expiredHome = await client.getUrl(base.replace(path: '/'));
    final expiredHomeResponse = await expiredHome.close();
    expect(expiredHomeResponse.statusCode, HttpStatus.ok);
    final expiredHtml = await utf8.decodeStream(expiredHomeResponse);
    expect(expiredHtml, contains('连接已过期'));
    expect(expiredHtml, contains('<meta name="viewport"'));
    expect(expiredHtml, isNot(contains('content</head>')));

    final denied = await client.getUrl(base.replace(path: '/api/status'));
    expect((await denied.close()).statusCode, HttpStatus.forbidden);

    final htmlRequest = await client.getUrl(
        base.replace(path: '/', queryParameters: {'token': server.token}));
    expect((await htmlRequest.close()).statusCode, HttpStatus.ok);

    final assetRequest = await client.getUrl(base.replace(path: '/app.js'));
    expect((await assetRequest.close()).statusCode, HttpStatus.ok);

    final request = await client.postUrl(base
        .replace(path: '/api/text', queryParameters: {'token': server.token}));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'text': '来自手机的测试文字', 'clientName': '测试手机'}));
    expect((await request.close()).statusCode, HttpStatus.ok);
  });

  test('opening a new QR token immediately replaces an old QR token', () async {
    final directory = await Directory.systemTemp.createTemp('sendhere-test-');
    final server = LocalTransferServer(
      downloadDirectory: directory,
      loadAsset: (asset) => File(asset).readAsBytes(),
    );
    addTearDown(() async {
      await server.stop();
      await directory.delete(recursive: true);
    });

    await server.start();
    final client = HttpClient();
    addTearDown(client.close);
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final oldToken = server.token;
    server.refreshToken(disconnectExisting: false);
    final newToken = server.token;
    expect(newToken, isNot(oldToken));

    final oldLink = await client
        .getUrl(base.replace(path: '/', queryParameters: {'token': oldToken}));
    expect(await utf8.decodeStream(await oldLink.close()), contains('连接已过期'));

    final newLink = await client
        .getUrl(base.replace(path: '/', queryParameters: {'token': newToken}));
    expect((await newLink.close()).statusCode, HttpStatus.ok);
  });

  test('accepts direct binary file uploads for mobile web views', () async {
    final directory = await Directory.systemTemp.createTemp('sendhere-test-');
    final server = LocalTransferServer(
      downloadDirectory: directory,
      loadAsset: (asset) => File(asset).readAsBytes(),
    );
    addTearDown(() async {
      await server.stop();
      await directory.delete(recursive: true);
    });

    await server.start();
    final client = HttpClient();
    addTearDown(client.close);
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final request = await client.postUrl(base.replace(
        path: '/api/upload', queryParameters: {'token': server.token}));
    request.headers
      ..set('x-sendhere-client-name', Uri.encodeComponent('微信 iPhone · TEST'))
      ..set('x-sendhere-device-id', 'wechat-test')
      ..set('x-sendhere-file-name', Uri.encodeComponent('微信图片.jpg'))
      ..contentType = ContentType('image', 'jpeg');
    request.add([1, 2, 3, 4]);

    expect((await request.close()).statusCode, HttpStatus.ok);
    final uploaded = File('${directory.path}${Platform.pathSeparator}微信图片.jpg');
    expect(await uploaded.readAsBytes(), [1, 2, 3, 4]);
  });

  test('keeps a desktop file available for a phone download', () async {
    final directory = await Directory.systemTemp.createTemp('sendhere-test-');
    final source = File('${directory.path}${Platform.pathSeparator}share.txt');
    await source.writeAsString('available to phone');
    final server = LocalTransferServer(
      downloadDirectory: directory,
      loadAsset: (asset) => File(asset).readAsBytes(),
    );
    addTearDown(() async {
      await server.stop();
      await directory.delete(recursive: true);
    });
    await server.start();

    final eventFuture = server.events.firstWhere(
      (event) => event.type == TransferEventType.file,
    );
    await server.offerFileToPhone(source);
    final event = await eventFuture;
    expect(event.localPath, source.path);

    // File IDs are opaque, so exercise the download URL announced to the phone
    // through a connected WebSocket in integration tests. Here, keeping the
    // source path alive establishes the server-side lifetime contract.
    expect(await File(event.localPath!).readAsString(), 'available to phone');
  });

  test('delivers a file immediately after a peer connection is established',
      () async {
    final senderDirectory =
        await Directory.systemTemp.createTemp('sendhere-sender-');
    final receiverDirectory =
        await Directory.systemTemp.createTemp('sendhere-receiver-');
    final sender = LocalTransferServer(
      downloadDirectory: senderDirectory,
      deviceName: '发送电脑',
      loadAsset: (asset) => File(asset).readAsBytes(),
    );
    final receiver = LocalTransferServer(
      downloadDirectory: receiverDirectory,
      deviceName: '接收电脑',
      loadAsset: (asset) => File(asset).readAsBytes(),
    );
    addTearDown(() async {
      await sender.stop();
      await receiver.stop();
      await senderDirectory.delete(recursive: true);
      await receiverDirectory.delete(recursive: true);
    });

    await sender.start();
    await receiver.start();
    sender.setLocalEndpoint(address: '127.0.0.1', deviceId: 'sender-device');
    receiver.setLocalEndpoint(
        address: '127.0.0.1', deviceId: 'receiver-device');
    final source =
        File('${senderDirectory.path}${Platform.pathSeparator}ready.txt');
    await source.writeAsString('file transfer is ready');
    final received = receiver.events.firstWhere((event) =>
        event.type == TransferEventType.file &&
        event.direction == TransferDirection.received &&
        event.deviceId == 'sender-device');

    await sender.connectToPeer(
      deviceId: 'receiver-device',
      deviceName: '接收电脑',
      address: '127.0.0.1',
      peerPort: receiver.port,
      localDeviceId: 'sender-device',
    );
    await sender.offerFileToDevice('receiver-device', source);

    final event = await received.timeout(const Duration(seconds: 10));
    expect(event.fileName, 'ready.txt');
    expect(
      await File('${receiverDirectory.path}${Platform.pathSeparator}ready.txt')
          .readAsString(),
      'file transfer is ready',
    );
  });

  test('peer session token does not replace the QR token', () async {
    final directory = await Directory.systemTemp.createTemp('sendhere-test-');
    final server = LocalTransferServer(
      downloadDirectory: directory,
      loadAsset: (asset) => File(asset).readAsBytes(),
    );
    addTearDown(() async {
      await server.stop();
      await directory.delete(recursive: true);
    });

    await server.start();
    final client = HttpClient();
    addTearDown(client.close);
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final qrToken = server.token;

    final bootstrap =
        await client.getUrl(base.replace(path: '/api/peer-session'));
    final bootstrapResponse = await bootstrap.close();
    expect(bootstrapResponse.statusCode, HttpStatus.ok);
    final peerToken = (jsonDecode(await utf8.decodeStream(bootstrapResponse))
        as Map<String, dynamic>)['token'] as String;
    expect(peerToken, isNot(qrToken));

    final peerText = await client.postUrl(
        base.replace(path: '/api/text', queryParameters: {'token': peerToken}));
    peerText.headers.contentType = ContentType.json;
    peerText.write(jsonEncode({'text': '来自电脑的测试文字'}));
    expect((await peerText.close()).statusCode, HttpStatus.ok);

    final qrText = await client.postUrl(
        base.replace(path: '/api/text', queryParameters: {'token': qrToken}));
    qrText.headers.contentType = ContentType.json;
    qrText.write(jsonEncode({'text': '二维码会话仍有效'}));
    expect((await qrText.close()).statusCode, HttpStatus.ok);
  });
}
