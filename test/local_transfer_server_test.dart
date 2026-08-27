import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:send_here/src/local_transfer_server.dart';

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
