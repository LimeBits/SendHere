import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:send_here/src/local_transfer_server.dart';
import 'package:send_here/src/transfer_event.dart';

void main() {
  test('recognises Tailscale CGNAT addresses', () {
    for (final address in [
      '100.64.0.1',
      '100.115.152.126',
      '100.127.255.254'
    ]) {
      expect(LocalTransferServer.isTailscaleIpv4(address), isTrue,
          reason: address);
    }
    for (final address in [
      '100.63.255.255',
      '100.128.0.1',
      '192.168.1.2',
      '10.0.0.1',
      '100.1',
      'abc',
    ]) {
      expect(LocalTransferServer.isTailscaleIpv4(address), isFalse,
          reason: address);
    }
  });

  test('recognises LAN interface names across platforms', () {
    for (final name in [
      'en0', 'en1', // macOS / iOS
      'wlan0', 'swlan0', 'ap0', 'eth0', // Android
      'Wi-Fi', 'WLAN', 'Ethernet', '以太网', // Windows
    ]) {
      expect(LocalTransferServer.isLanInterfaceName(name), isTrue,
          reason: name);
    }
    for (final name in [
      'rmnet_data0', 'ccmni0', 'pdp_ip0', // cellular
      'tun0', 'utun3', 'ppp0', 'ipsec0', 'lo', // VPN / loopback
    ]) {
      expect(LocalTransferServer.isLanInterfaceName(name), isFalse,
          reason: name);
    }
  });

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

  test('sends desktop text and file notifications to an identified phone',
      () async {
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
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}/ws?token=${server.token}',
    );
    addTearDown(socket.close);
    final messages = socket
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .asBroadcastStream();
    final connected = server.events.firstWhere((event) =>
        event.type == TransferEventType.clientConnected &&
        event.deviceId == 'phone-browser');
    socket.add(jsonEncode({
      'type': 'identify',
      'name': '测试手机',
      'id': 'phone-browser',
    }));
    await connected;
    expect(server.connectedPhoneCount, 1);

    final textMessage =
        messages.firstWhere((message) => message['type'] == 'desktop_text');
    server.sendTextToPhone('电脑发来的文字');
    expect((await textMessage)['text'], '电脑发来的文字');

    final source =
        File('${directory.path}${Platform.pathSeparator}from-desktop.txt');
    await source.writeAsString('download me');
    final fileMessage =
        messages.firstWhere((message) => message['type'] == 'desktop_file');
    await server.offerFileToPhone(source);
    final file = await fileMessage;
    expect(file['fileName'], 'from-desktop.txt');
    expect(file['downloadPath'], startsWith('/api/download/'));
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

  test('peers exchange Tailscale addresses so they can reconnect remotely',
      () async {
    final dialerDirectory =
        await Directory.systemTemp.createTemp('sendhere-dialer-');
    final listenerDirectory =
        await Directory.systemTemp.createTemp('sendhere-listener-');
    final dialer = LocalTransferServer(
      downloadDirectory: dialerDirectory,
      deviceName: '家里电脑',
      loadAsset: (asset) => File(asset).readAsBytes(),
    );
    final listener = LocalTransferServer(
      downloadDirectory: listenerDirectory,
      deviceName: '公司电脑',
      loadAsset: (asset) => File(asset).readAsBytes(),
    );
    addTearDown(() async {
      await dialer.stop();
      await listener.stop();
      await dialerDirectory.delete(recursive: true);
      await listenerDirectory.delete(recursive: true);
    });

    await dialer.start();
    await listener.start();
    dialer.setLocalEndpoint(
        address: '127.0.0.1',
        tailscaleAddress: '100.100.1.1',
        deviceId: 'dialer-device');
    listener.setLocalEndpoint(
        address: '127.0.0.1',
        tailscaleAddress: '100.100.2.2',
        deviceId: 'listener-device');

    // probe() reports the peer's name and stable device ID.
    final probed = await LocalTransferServer.probe('127.0.0.1', listener.port);
    expect(probed?.name, '公司电脑');
    expect(probed?.id, 'listener-device');
    expect(await LocalTransferServer.probe('127.0.0.1', 1), isNull);

    final listenerSaw = listener.events.firstWhere((event) =>
        event.type == TransferEventType.clientConnected &&
        event.deviceId == 'dialer-device');
    final dialerSaw = dialer.events.firstWhere((event) =>
        event.type == TransferEventType.clientConnected &&
        event.deviceId == 'listener-device');

    await dialer.connectToPeer(
      deviceId: 'listener-device',
      deviceName: '公司电脑',
      address: '127.0.0.1',
      peerPort: listener.port,
      localDeviceId: 'dialer-device',
    );

    final onListener = await listenerSaw.timeout(const Duration(seconds: 5));
    expect(onListener.isComputerPeer, isTrue);
    expect(onListener.peerTailscaleAddress, '100.100.1.1');
    expect(onListener.peerPort, dialer.port);

    final onDialer = await dialerSaw.timeout(const Duration(seconds: 5));
    expect(onDialer.peerTailscaleAddress, '100.100.2.2');
    expect(onDialer.peerPort, listener.port);

    // The identify message triggers a background upload-session request from
    // the listener back to the dialer; let it finish before teardown closes
    // both servers, otherwise the forced close surfaces as a test-zone error.
    await Future<void>.delayed(const Duration(milliseconds: 500));
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

  test(
      'a LAN connection silently upgrades an existing Tailscale peer '
      'without a visible disconnect', () async {
    final dialerDirectory =
        await Directory.systemTemp.createTemp('sendhere-upgrade-dialer-');
    final listenerDirectory =
        await Directory.systemTemp.createTemp('sendhere-upgrade-listener-');
    // 'localhost' and '127.0.0.1' both reach the same loopback listener, but
    // are distinct strings a fake classifier can tell apart, standing in for
    // a real Tailscale address and a real LAN address without needing an
    // actual 100.64.0.0/10 interface in the test environment.
    // Both ends must agree on the fake classifier: the listener uses it to
    // tell the dialer's two identify messages apart, exactly as both real
    // devices would agree on the real 100.64.0.0/10 range in production.
    bool fakeIsTailscale(String address) => address == 'localhost';
    final dialer = LocalTransferServer(
      downloadDirectory: dialerDirectory,
      deviceName: '家里电脑',
      loadAsset: (asset) => File(asset).readAsBytes(),
      isTailscaleAddress: fakeIsTailscale,
    );
    final listener = LocalTransferServer(
      downloadDirectory: listenerDirectory,
      deviceName: '公司电脑',
      loadAsset: (asset) => File(asset).readAsBytes(),
      isTailscaleAddress: fakeIsTailscale,
    );
    addTearDown(() async {
      await dialer.stop();
      await listener.stop();
      await dialerDirectory.delete(recursive: true);
      await listenerDirectory.delete(recursive: true);
    });

    await dialer.start();
    await listener.start();
    // The dialer's "Tailscale address" is the fake-Tailscale string so its
    // identify's callback address matches what it dialed on the first leg.
    dialer.setLocalEndpoint(
        address: '127.0.0.1',
        tailscaleAddress: 'localhost',
        deviceId: 'dialer-device');
    listener.setLocalEndpoint(
        address: '127.0.0.1', deviceId: 'listener-device');

    final dialerEvents = <TransferEvent>[];
    final dialerSubscription = dialer.events.listen(dialerEvents.add);
    addTearDown(dialerSubscription.cancel);
    final listenerEvents = <TransferEvent>[];
    final listenerSubscription = listener.events.listen(listenerEvents.add);
    addTearDown(listenerSubscription.cancel);

    // First dial looks like Tailscale to the fake classifier.
    await dialer.connectToPeer(
      deviceId: 'listener-device',
      deviceName: '公司电脑',
      address: 'localhost',
      peerPort: listener.port,
      localDeviceId: 'dialer-device',
    );
    expect(dialer.peerTransport('listener-device'), PeerTransport.tailscale);
    // The broadcast stream delivers to listeners asynchronously relative to
    // the synchronous _events.add() call inside connectToPeer (and the
    // listener's own identify handling happens over a real socket, adding
    // another hop), so the initial clientConnected may not have reached
    // dialerEvents/listenerEvents yet; let it flush before clearing,
    // otherwise clear() can run first and the legitimate first-connect
    // event gets mistaken for a replay later.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // Only events from the upgrade dial onward matter here; the initial
    // connection legitimately raises its own clientConnected on both ends.
    dialerEvents.clear();
    listenerEvents.clear();

    // The two computers then land on the same LAN. Dialing the real LAN
    // address upgrades the connection: the old socket is replaced, but no
    // clientDisconnected/clientConnected pair should surface to the UI,
    // since the UI must not treat an upgrade as the device going briefly
    // offline and back online.
    await dialer.connectToPeer(
      deviceId: 'listener-device',
      deviceName: '公司电脑',
      address: '127.0.0.1',
      peerPort: listener.port,
      localDeviceId: 'dialer-device',
    );
    expect(dialer.peerTransport('listener-device'), PeerTransport.lan);
    expect(dialer.hasPeer('listener-device'), isTrue);

    // Give the old Tailscale socket's onDone callback time to run; it
    // debounces the disconnect check by 800ms specifically to absorb this
    // kind of race, so wait past that window before asserting nothing fired.
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    expect(
        dialerEvents.where((event) =>
            event.type == TransferEventType.clientDisconnected ||
            event.type == TransferEventType.clientConnected),
        isEmpty,
        reason: 'upgrading transport must not replay connect/disconnect '
            'on the dialing side');
    expect(
        listenerEvents.where((event) =>
            event.type == TransferEventType.clientDisconnected ||
            event.type == TransferEventType.clientConnected),
        isEmpty,
        reason: 'upgrading transport must not replay connect/disconnect '
            'on the receiving side');
    expect(dialer.hasPeer('listener-device'), isTrue);
    expect(dialer.peerTransport('listener-device'), PeerTransport.lan);
  });
}
