import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' show serve;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'transfer_event.dart';

/// How a peer connection is currently routed. LAN is preferred: lower
/// latency, no dependency on a third-party relay, and no mobile-data use.
enum PeerTransport { lan, tailscale }

class LocalTransferServer {
  LocalTransferServer({
    required this.downloadDirectory,
    String? deviceName,
    Future<List<int>> Function(String asset)? loadAsset,
    bool Function(String address)? isTailscaleAddress,
    this.onFileReceived,
  })  : deviceName = deviceName ?? Platform.localHostname,
        _loadAsset = loadAsset ?? _loadFlutterAsset,
        _isTailscaleAddress = isTailscaleAddress ?? isTailscaleIpv4;

  final Directory downloadDirectory;
  final String deviceName;
  final Future<List<int>> Function(String asset) _loadAsset;

  /// Called once a received file is fully written. May relocate it (e.g. to
  /// Android's public Downloads) and returns the path the file now lives at;
  /// that path is what the file event reports.
  final Future<String> Function(File file)? onFileReceived;

  /// Classifies an address as Tailscale vs LAN. Defaults to the real
  /// CGNAT-range check ([isTailscaleIpv4]); tests inject a fake classifier
  /// so the LAN-upgrade path can be exercised over plain loopback addresses
  /// without binding a real 100.64.0.0/10 address.
  final bool Function(String address) _isTailscaleAddress;
  final _events = StreamController<TransferEvent>.broadcast();
  final _sockets = <WebSocketChannel>{};
  final _files = <String, _DownloadFile>{};
  final _clients = <WebSocketChannel, String>{};
  final _clientIds = <WebSocketChannel, String>{};
  final _peerTokens = <String, DateTime>{};
  final _peerSockets = <String, WebSocketChannel>{};
  final _peerSessions = <String, _PeerSession>{};
  final _peerSessionRequests = <String, Future<_PeerSession?>>{};
  final _peerEndpoints = <String, _PeerEndpoint>{};
  final _peerTransports = <String, PeerTransport>{};
  final _upgradingPeerIds = <String>{};
  // Remembers a peer's transport for a brief window after its socket closes,
  // so a replacement connection landing moments later (the other leg of a
  // LAN <-> Tailscale upgrade, which is a second independent TCP connection
  // that can arrive slightly before or after this one's close notice) is
  // still recognised as an upgrade rather than a fresh, unrelated connect.
  final _recentlyClosedPeerTransports = <String, PeerTransport>{};
  String? _localAddress;
  String? _localTailscaleAddress;
  String? _localDeviceId;

  HttpServer? _server;
  String _token = _newToken();
  DateTime _expiresAt = DateTime.now();

  Stream<TransferEvent> get events => _events.stream;
  bool get isRunning => _server != null;
  String get token => _token;
  DateTime get expiresAt => _expiresAt;
  int get port => _server?.port ?? 0;
  int get connectedDeviceCount => _clients.length;
  int get connectedPhoneCount =>
      _sockets.where((socket) => !_isPeerSocket(socket)).length;
  String get connectedDeviceNames {
    final names = _clients.values.where((name) => name != '手机').toSet();
    return names.isEmpty ? '已连接设备' : names.join('、');
  }

  Future<void> start() async {
    if (isRunning) return;
    await downloadDirectory.create(recursive: true);
    refreshToken();

    final router = Router()
      ..get('/', _handleHome)
      ..get('/app.js', _handleAsset)
      ..get('/styles.css', _handleAsset)
      ..get('/api/status', _handleStatus)
      ..get('/api/peer-session', _handlePeerSession)
      ..post('/api/text', _handleText)
      ..post('/api/upload', _handleUpload)
      ..get('/api/download/<id>', _handleDownload)
      ..get(
          '/ws',
          webSocketHandler(_handleSocket,
              pingInterval: const Duration(seconds: 8)));

    final handler = const Pipeline()
        .addMiddleware(_authorizationMiddleware)
        .addMiddleware(logRequests())
        .addHandler(router.call);
    try {
      _server = await serve(handler, InternetAddress.anyIPv4, 8899);
    } on SocketException {
      // A fixed default keeps QR addresses predictable, while an ephemeral
      // fallback avoids making the product fail just because 8899 is in use.
      _server = await serve(handler, InternetAddress.anyIPv4, 0);
    }
  }

  Future<void> stop() async {
    for (final socket in _sockets.toList()) {
      await socket.sink.close();
    }
    _sockets.clear();
    _clients.clear();
    _clientIds.clear();
    _peerSockets.clear();
    _peerSessions.clear();
    _peerSessionRequests.clear();
    _peerTokens.clear();
    _peerTransports.clear();
    _upgradingPeerIds.clear();
    await _server?.close(force: true);
    _server = null;
  }

  void refreshToken({bool disconnectExisting = true}) {
    _token = _newToken();
    // A phone may take a while to open the system camera result, especially
    // after waking from the lock screen. The link is still local-network-only,
    // and each newly opened QR dialog gets its own token.
    _expiresAt = DateTime.now().add(const Duration(hours: 2));
    if (!disconnectExisting) return;
    // Explicit revocation closes phone sessions authorized by the old QR code.
    for (final socket in _sockets.toList()) {
      socket.sink.close(WebSocketStatus.policyViolation, 'QR code refreshed');
    }
    _sockets.clear();
    _clients.clear();
  }

  /// Returns private IPv4 addresses, preferring a physical Wi-Fi/Ethernet
  /// interface over cellular or VPN interfaces. A QR link must be reachable by
  /// another device on the same local network, so advertising a VPN or cellular
  /// address would create a valid-looking but unusable code.
  Future<List<String>> localAddresses() async {
    final preferred = <String>[];
    for (final interface in await NetworkInterface.list()) {
      final physical = isLanInterfaceName(interface.name);
      for (final address in interface.addresses) {
        if (address.type != InternetAddressType.IPv4 ||
            address.isLoopback ||
            !_isPrivateIpv4(address.address)) {
          continue;
        }
        if (physical) preferred.add(address.address);
      }
    }
    return preferred.toSet().toList();
  }

  /// Whether [interfaceName] is a Wi-Fi/Ethernet/hotspot interface.
  /// - macOS/iOS: en0, en1...
  /// - Android: wlan0 (Wi-Fi), swlan0/ap0 (hotspot), eth0 (USB Ethernet)
  /// - Windows: "Wi-Fi", "WLAN", "Ethernet", "以太网"
  /// Cellular (rmnet*, ccmni*, pdp_ip*) and VPN (tun*, utun*, ppp*, ipsec*)
  /// interfaces are rejected.
  static bool isLanInterfaceName(String interfaceName) {
    final name = interfaceName.toLowerCase();
    return name.startsWith('en') ||
        name.startsWith('wlan') ||
        name.startsWith('swlan') ||
        name.startsWith('ap') ||
        name.startsWith('eth') ||
        name.contains('wi-fi') ||
        name.contains('wifi') ||
        name.contains('ethernet') ||
        name.contains('以太网');
  }

  /// Returns this device's Tailscale IPv4 addresses (100.64.0.0/10).
  /// Detected by address range rather than interface name, because Tailscale
  /// shows up as utun* on Apple platforms, "Tailscale" on Windows and tun0 on
  /// Android.
  Future<List<String>> tailscaleAddresses() async {
    final result = <String>[];
    for (final interface in await NetworkInterface.list()) {
      for (final address in interface.addresses) {
        if (address.type == InternetAddressType.IPv4 &&
            isTailscaleIpv4(address.address)) {
          result.add(address.address);
        }
      }
    }
    return result.toSet().toList();
  }

  /// Whether [value] is in Tailscale's CGNAT range 100.64.0.0/10.
  static bool isTailscaleIpv4(String value) {
    final octets = value.split('.').map(int.tryParse).toList();
    if (octets.length != 4 || octets.any((octet) => octet == null)) {
      return false;
    }
    return octets[0] == 100 && octets[1]! >= 64 && octets[1]! <= 127;
  }

  static bool _isPrivateIpv4(String value) {
    final octets = value.split('.');
    if (octets.length != 4) return false;
    final numbers = octets.map(int.tryParse).toList();
    if (numbers.any((number) => number == null)) return false;
    final first = numbers[0]!;
    final second = numbers[1]!;
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }

  bool _isAuthorized(Request request) {
    final supplied = request.url.queryParameters['token'] ??
        request.headers['x-sendhere-token'];
    if (supplied == _token && DateTime.now().isBefore(_expiresAt)) return true;
    final peerExpiry = supplied == null ? null : _peerTokens[supplied];
    return peerExpiry != null && DateTime.now().isBefore(peerExpiry);
  }

  Middleware get _authorizationMiddleware => (innerHandler) => (request) {
        // Assets contain no user data. Keeping them public lets a tokenized
        // HTML page load its CSS/JS without leaking the token into asset URLs.
        final isStaticAsset =
            request.url.path == 'app.js' || request.url.path == 'styles.css';
        final isPeerBootstrap = request.url.path == 'api/peer-session';
        // The root route renders a recovery page for expired QR links.
        final isHome = request.url.path.isEmpty;
        if (!isStaticAsset &&
            !isPeerBootstrap &&
            !isHome &&
            !_isAuthorized(request)) {
          return _forbidden();
        }
        return innerHandler(request);
      };

  Future<Response> _handleHome(Request request) async {
    if (!_isAuthorized(request)) {
      return _asset('assets/web/expired.html', 'text/html; charset=utf-8');
    }
    return _asset('assets/web/index.html', 'text/html; charset=utf-8');
  }

  Future<Response> _handleAsset(Request request) async {
    final asset = request.url.path == 'app.js'
        ? 'assets/web/app.js'
        : 'assets/web/styles.css';
    final contentType = asset.endsWith('.js')
        ? 'application/javascript; charset=utf-8'
        : 'text/css; charset=utf-8';
    return _asset(asset, contentType);
  }

  Future<Response> _handleStatus(Request request) async {
    if (!_isAuthorized(request)) return _forbidden();
    return Response.ok(
      jsonEncode({
        'deviceName': deviceName,
        'expiresAt': _expiresAt.toIso8601String()
      }),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Future<Response> _handlePeerSession(Request request) async {
    _peerTokens.removeWhere((_, expiry) => DateTime.now().isAfter(expiry));
    final token = _newToken();
    _peerTokens[token] = DateTime.now().add(const Duration(minutes: 5));
    // Device ID and Tailscale address are not secrets (the ID is already in
    // mDNS TXT records); they let the dialing side remember this computer.
    return Response.ok(
        jsonEncode({
          'token': token,
          'name': deviceName,
          if (_localDeviceId != null) 'id': _localDeviceId,
          if (_localTailscaleAddress != null)
            'tailscaleAddress': _localTailscaleAddress,
        }),
        headers: {'content-type': 'application/json; charset=utf-8'});
  }

  Future<Response> _handleText(Request request) async {
    if (!_isAuthorized(request)) return _forbidden();
    final data =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final text = (data['text'] as String? ?? '').trim();
    if (text.isEmpty) return Response(400, body: 'Text cannot be empty.');
    final clientName = data['clientName'] as String? ?? '手机';
    final deviceId = data['deviceId'] as String?;
    _events.add(TransferEvent(
        type: TransferEventType.text,
        createdAt: DateTime.now(),
        text: text,
        clientName: clientName,
        deviceId: deviceId));
    _broadcast(
        {'type': 'text_received', 'text': text, 'clientName': clientName});
    return Response.ok(jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'});
  }

  Future<Response> _handleUpload(Request request) async {
    if (!_isAuthorized(request)) return _forbidden();
    final encodedClientName = request.headers['x-sendhere-client-name'];
    final clientName = encodedClientName == null
        ? '手机'
        : Uri.decodeComponent(encodedClientName);
    final deviceId = request.headers['x-sendhere-device-id'];
    final boundary = _boundaryFrom(request.headers['content-type']);

    if (boundary != null) {
      // Keep multipart support for desktop peer uploads and older web clients.
      final transformer = MimeMultipartTransformer(boundary);
      await for (final part in transformer.bind(request.read())) {
        final disposition =
            HeaderValue.parse(part.headers['content-disposition'] ?? '');
        final filename = disposition.parameters['filename'];
        if (filename == null || filename.isEmpty) continue;
        await _saveUploadedFile(part, filename,
            clientName: clientName, deviceId: deviceId);
      }
    } else {
      // WeChat's iOS WebView can leave multipart HTTP uploads pending. It sends
      // each selected File as a direct request body with its name in a header.
      final encodedFilename = request.headers['x-sendhere-file-name'];
      if (encodedFilename == null || encodedFilename.isEmpty) {
        return Response(400, body: 'Expected a file name.');
      }
      final filename = Uri.decodeComponent(encodedFilename);
      await _saveUploadedFile(request.read(), filename,
          clientName: clientName, deviceId: deviceId);
    }
    return Response.ok(jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'});
  }

  Future<void> _saveUploadedFile(Stream<List<int>> content, String filename,
      {required String clientName, String? deviceId}) async {
    final safeName = path.basename(filename);
    if (safeName.isEmpty || safeName == '.') return;
    final destination = await _uniqueFile(safeName);
    final sink = destination.openWrite();
    try {
      await for (final chunk in content) {
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    final size = await destination.length();
    var finalPath = destination.path;
    final hook = onFileReceived;
    if (hook != null) {
      try {
        finalPath = await hook(destination);
      } catch (_) {
        // Relocation is best effort; the file is still in downloadDirectory.
      }
    }
    _events.add(TransferEvent(
        type: TransferEventType.file,
        createdAt: DateTime.now(),
        fileName: path.basename(finalPath),
        fileSize: size,
        clientName: clientName,
        deviceId: deviceId,
        localPath: finalPath));
    _broadcast({
      'type': 'file_received',
      'fileName': path.basename(finalPath),
      'fileSize': size,
    });
  }

  Future<Response> _handleDownload(Request request, String id) async {
    if (!_isAuthorized(request)) return _forbidden();
    final download = _files[id];
    if (download == null || !await download.file.exists()) {
      return Response.notFound('File not found.');
    }
    return Response.ok(download.file.openRead(), headers: {
      'content-type':
          lookupMimeType(download.name) ?? 'application/octet-stream',
      'content-disposition':
          'attachment; filename="${_contentDispositionFilename(download.name)}"',
      'content-length': (await download.file.length()).toString(),
    });
  }

  /// Dials [deviceId] at [address]:[peerPort]. If that peer is already
  /// connected over Tailscale and [address] is a LAN address, this proceeds
  /// as a silent upgrade: a successful `/api/peer-session` round trip over
  /// the LAN address already proves it is reachable, so the old Tailscale
  /// socket is only closed once the new LAN socket takes its place in
  /// [_peerSockets], and the UI never shows the device as briefly offline.
  Future<void> connectToPeer({
    required String deviceId,
    required String deviceName,
    required String address,
    required int peerPort,
    required String localDeviceId,
  }) async {
    final isUpgrade = hasPeer(deviceId) &&
        _peerTransports[deviceId] == PeerTransport.tailscale &&
        !_isTailscaleAddress(address);
    if (hasPeer(deviceId) && !isUpgrade) return;
    if (isUpgrade) {
      if (_upgradingPeerIds.contains(deviceId)) return;
      _upgradingPeerIds.add(deviceId);
    }
    final client = HttpClient();
    try {
      final uri = Uri(
          scheme: 'http',
          host: address,
          port: peerPort,
          path: '/api/peer-session');
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw const HttpException('无法创建连接会话');
      }
      final body =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
      final token = body['token'] as String;
      final advertised = body['tailscaleAddress'] as String?;
      final peerTailscale = _isTailscaleAddress(address)
          ? address
          : advertised != null && isTailscaleIpv4(advertised)
              ? advertised
              : null;
      final socketUri = Uri(
          scheme: 'ws',
          host: address,
          port: peerPort,
          path: '/ws',
          queryParameters: {'token': token});
      // A ping keepalive matches the server's and lets a dead TCP path (Wi-Fi
      // dropped, Tailscale route gone) surface via onDone within seconds
      // instead of the OS's much longer default TCP timeout, so the LAN <->
      // Tailscale fallback/upgrade logic reacts promptly.
      final socket = IOWebSocketChannel.connect(socketUri,
          pingInterval: const Duration(seconds: 8));
      _peerSessions[deviceId] = _PeerSession(
          deviceId: deviceId,
          deviceName: deviceName,
          senderDeviceId: localDeviceId,
          baseUri: Uri(scheme: 'http', host: address, port: peerPort),
          token: token,
          expiresAt: DateTime.now().add(const Duration(minutes: 4)));
      final dialedTailscale = _isTailscaleAddress(address);
      _registerSocket(socket,
          name: deviceName,
          id: deviceId,
          isPeer: true,
          transport: dialedTailscale ? PeerTransport.tailscale : PeerTransport.lan,
          isUpgrade: isUpgrade,
          peerTailscaleAddress: peerTailscale,
          peerPort: peerPort);
      // Advertise the address reachable on the same network we just dialed
      // on, not just whichever address we happen to prefer. Dialing [address]
      // over Tailscale but advertising our LAN address would hand the peer a
      // callback address it cannot reach, breaking its own reconnect retries.
      final callbackAddress = dialedTailscale
          ? _localTailscaleAddress ?? _localAddress
          : _localAddress ?? _localTailscaleAddress;
      socket.sink.add(jsonEncode({
        'type': 'identify',
        'name': this.deviceName,
        'id': localDeviceId,
        'peer': true,
        'address': callbackAddress,
        'tailscaleAddress': _localTailscaleAddress,
        'port': port,
      }));
    } finally {
      client.close(force: true);
      _upgradingPeerIds.remove(deviceId);
    }
  }

  bool hasPeer(String deviceId) => _peerSockets.containsKey(deviceId);
  bool hasDevice(String deviceId) => _clientIds.values.contains(deviceId);

  /// How [deviceId]'s connection is currently routed, or null if not
  /// connected as a peer.
  PeerTransport? peerTransport(String deviceId) => _peerTransports[deviceId];

  /// Removes a desktop that has disappeared from LAN discovery immediately,
  /// rather than waiting for the operating system's TCP timeout.
  Future<void> disconnectPeer(String deviceId) async {
    final socket = _peerSockets[deviceId];
    if (socket != null) {
      await socket.sink
          .close(WebSocketStatus.goingAway, 'Peer is no longer discoverable');
    }
  }

  void setLocalEndpoint({
    required String? address,
    required String deviceId,
    String? tailscaleAddress,
  }) {
    _localAddress = address;
    _localDeviceId = deviceId;
    _localTailscaleAddress = tailscaleAddress;
  }

  /// Probes a SendHere instance at [address]:[port] (LAN or Tailscale) and
  /// returns its device name and ID, or null when nothing answers.
  static Future<({String name, String? id})?> probe(String address, int port,
      {Duration timeout = const Duration(seconds: 4)}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client
          .getUrl(Uri(
              scheme: 'http', host: address, port: port, path: '/api/status'))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>();
      // /api/status needs a token; a 403 still proves SendHere is listening.
      if (response.statusCode != HttpStatus.forbidden &&
          response.statusCode != HttpStatus.ok) {
        return null;
      }
      final session = await client
          .getUrl(Uri(
              scheme: 'http',
              host: address,
              port: port,
              path: '/api/peer-session'))
          .timeout(timeout);
      final sessionResponse = await session.close().timeout(timeout);
      if (sessionResponse.statusCode != HttpStatus.ok) return null;
      final body = jsonDecode(await utf8.decodeStream(sessionResponse))
          as Map<String, dynamic>;
      final name = body['name'] as String?;
      if (name == null) return null;
      return (name: name, id: body['id'] as String?);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  void updatePeerEndpoint({
    required String deviceId,
    required String deviceName,
    required String address,
    required int port,
    required String localDeviceId,
  }) {
    _peerEndpoints[deviceId] = _PeerEndpoint(
      deviceId: deviceId,
      deviceName: deviceName,
      address: address,
      port: port,
      localDeviceId: localDeviceId,
    );
  }

  Future<_PeerSession?> _ensurePeerUploadSession(String deviceId) async {
    final existing = _peerSessions[deviceId];
    if (existing != null && DateTime.now().isBefore(existing.expiresAt)) {
      return existing;
    }
    final pending = _peerSessionRequests[deviceId];
    if (pending != null) return pending;

    _peerSessions.remove(deviceId);
    final request = _createPeerUploadSession(deviceId);
    _peerSessionRequests[deviceId] = request;
    try {
      return await request;
    } finally {
      if (identical(_peerSessionRequests[deviceId], request)) {
        _peerSessionRequests.remove(deviceId);
      }
    }
  }

  Future<_PeerSession?> _createPeerUploadSession(String deviceId) async {
    final endpoint = _peerEndpoints[deviceId];
    if (endpoint == null) return null;
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri(
        scheme: 'http',
        host: endpoint.address,
        port: endpoint.port,
        path: '/api/peer-session',
      ));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final body =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
      final token = body['token'] as String?;
      if (token == null || token.isEmpty) return null;
      final session = _PeerSession(
        deviceId: deviceId,
        deviceName: endpoint.deviceName,
        senderDeviceId: endpoint.localDeviceId,
        baseUri:
            Uri(scheme: 'http', host: endpoint.address, port: endpoint.port),
        token: token,
        expiresAt: DateTime.now().add(const Duration(minutes: 4)),
      );
      _peerSessions[deviceId] = session;
      return session;
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    } on IOException {
      // Includes connection resets when the peer goes away mid-request,
      // which is routine over Tailscale or when an app quits.
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> sendTextToDevice(String deviceId, String text,
      {String? transferId}) async {
    if (text.trim().isEmpty) return;
    final socket = _sockets.cast<WebSocketChannel?>().firstWhere(
        (candidate) => candidate != null && _clientIds[candidate] == deviceId,
        orElse: () => null);
    if (socket == null) throw StateError('设备未连接');
    _events.add(TransferEvent(
        type: TransferEventType.text,
        direction: TransferDirection.sent,
        createdAt: DateTime.now(),
        text: text,
        clientName: _clients[socket],
        deviceId: deviceId,
        transferId: transferId));
    socket.sink.add(jsonEncode(_peerSockets[deviceId] == socket
        ? {'type': 'peer_text', 'text': text, 'transferId': transferId}
        : {'type': 'desktop_text', 'text': text, 'transferId': transferId}));
  }

  Future<void> offerFileToDevice(String deviceId, File file,
      {String? transferId, String? fileName}) async {
    final socket = _sockets.cast<WebSocketChannel?>().firstWhere(
        (candidate) => candidate != null && _clientIds[candidate] == deviceId,
        orElse: () => null);
    if (socket == null) throw StateError('设备未连接');
    if (_peerSockets[deviceId] == socket) {
      await sendFileToPeer(
        deviceId,
        file,
        transferId: transferId,
        fileName: fileName,
      );
      return;
    }
    final id = _newToken();
    final displayName = fileName ?? path.basename(file.path);
    // `file.path` may be an outbox archive with a random prefix. Keep the
    // original display name separate so the phone downloads the expected name.
    _files[id] = _DownloadFile(file: file, name: displayName);
    _events.add(TransferEvent(
        type: TransferEventType.file,
        direction: TransferDirection.sent,
        createdAt: DateTime.now(),
        fileName: displayName,
        fileSize: await file.length(),
        clientName: _clients[socket],
        deviceId: deviceId,
        localPath: file.path,
        transferId: transferId));
    socket.sink.add(jsonEncode({
      'type': 'desktop_file',
      'fileName': displayName,
      'downloadPath': '/api/download/$id',
      'transferId': transferId,
    }));
  }

  void sendTextToPeer(String deviceId, String text) {
    final socket = _peerSockets[deviceId];
    if (socket == null || text.trim().isEmpty) return;
    _events.add(TransferEvent(
        type: TransferEventType.text,
        direction: TransferDirection.sent,
        createdAt: DateTime.now(),
        text: text,
        clientName: _clients[socket],
        deviceId: deviceId));
    socket.sink.add(jsonEncode({'type': 'peer_text', 'text': text}));
  }

  Future<void> sendFileToPeer(String deviceId, File file,
      {String? transferId, String? fileName}) async {
    if (!hasPeer(deviceId)) throw StateError('设备未连接');
    // A peer WebSocket can arrive a fraction before its mDNS endpoint reaches
    // this process. Wait briefly so choosing a file immediately after a device
    // appears does not fail solely because the upload session is not ready.
    _PeerSession? session;
    for (var attempt = 0; attempt < 12 && session == null; attempt++) {
      session = await _ensurePeerUploadSession(deviceId);
      if (session == null && attempt < 11) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    if (session == null) {
      throw StateError('设备连接尚未准备好文件传输，请确认对方 App 已打开后重试');
    }
    final uploadSession = session;
    final filename = fileName ?? path.basename(file.path);
    final size = await file.length();
    final id = transferId ?? _newToken();
    _emitFileTransfer(
      transferId: id,
      deviceId: deviceId,
      deviceName: uploadSession.deviceName,
      file: file,
      fileName: filename,
      fileSize: size,
      status: FileTransferStatus.uploading,
      bytesTransferred: 0,
    );
    final client = HttpClient();
    try {
      // Share the direct binary upload protocol used by mobile web views.
      // Unlike manually assembled multipart requests, it does not mix request
      // writes with addStream and therefore cannot enter HttpClient's Bad state.
      final request = await client
          .postUrl(uploadSession.baseUri.replace(path: '/api/upload'));
      request.headers
        ..set(HttpHeaders.contentTypeHeader,
            lookupMimeType(filename) ?? 'application/octet-stream')
        ..set('x-sendhere-token', uploadSession.token)
        ..set('x-sendhere-client-name', Uri.encodeComponent(deviceName))
        ..set('x-sendhere-device-id', uploadSession.senderDeviceId)
        ..set('x-sendhere-file-name', Uri.encodeComponent(filename));
      request.contentLength = size;
      var bytesTransferred = 0;
      await request.addStream(file.openRead().transform(
        StreamTransformer.fromHandlers(handleData: (chunk, sink) {
          bytesTransferred += chunk.length;
          _emitFileTransfer(
            transferId: id,
            deviceId: deviceId,
            deviceName: uploadSession.deviceName,
            file: file,
            fileName: filename,
            fileSize: size,
            status: FileTransferStatus.uploading,
            bytesTransferred: bytesTransferred,
          );
          sink.add(chunk);
        }),
      ));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('设备拒绝了文件传输（${response.statusCode}）');
      }
      await response.drain();
      _emitFileTransfer(
        transferId: id,
        deviceId: deviceId,
        deviceName: uploadSession.deviceName,
        file: file,
        fileName: filename,
        fileSize: size,
        status: FileTransferStatus.completed,
        bytesTransferred: size,
      );
    } catch (error) {
      _emitFileTransfer(
        transferId: id,
        deviceId: deviceId,
        deviceName: uploadSession.deviceName,
        file: file,
        fileName: filename,
        fileSize: size,
        status: FileTransferStatus.failed,
        errorMessage: '$error',
      );
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  void _emitFileTransfer({
    required String transferId,
    required String deviceId,
    required String deviceName,
    required File file,
    required String fileName,
    required int fileSize,
    required FileTransferStatus status,
    int? bytesTransferred,
    String? errorMessage,
  }) {
    _events.add(TransferEvent(
      type: TransferEventType.file,
      direction: TransferDirection.sent,
      createdAt: DateTime.now(),
      clientName: deviceName,
      deviceId: deviceId,
      fileName: fileName,
      fileSize: fileSize,
      localPath: file.path,
      transferId: transferId,
      fileStatus: status,
      bytesTransferred: bytesTransferred,
      errorMessage: errorMessage,
    ));
  }

  void sendTextToPhone(String text) {
    if (text.trim().isEmpty) return;
    _events.add(TransferEvent(
        type: TransferEventType.text,
        direction: TransferDirection.sent,
        createdAt: DateTime.now(),
        text: text,
        clientName: connectedDeviceNames));
    _broadcast({'type': 'desktop_text', 'text': text});
  }

  Future<void> offerFileToPhone(File file) async {
    final id = _newToken();
    final fileName = path.basename(file.path);
    _files[id] = _DownloadFile(file: file, name: fileName);
    _events.add(TransferEvent(
        type: TransferEventType.file,
        direction: TransferDirection.sent,
        createdAt: DateTime.now(),
        fileName: fileName,
        fileSize: await file.length(),
        clientName: connectedDeviceNames,
        localPath: file.path));
    _broadcast({
      'type': 'desktop_file',
      'fileName': fileName,
      'downloadPath': '/api/download/$id'
    });
  }

  void _handleSocket(WebSocketChannel socket) => _registerSocket(socket);

  /// Replaces [deviceId]'s current peer socket with [socket] and closes the
  /// old one, if any, after the new one is already in place. Used for both
  /// directions of a LAN upgrade: the dialing side swaps immediately since it
  /// knows the transport before sending identify, and the receiving side
  /// swaps once the new socket's identify arrives.
  void _swapPeerSocket(
      String deviceId, WebSocketChannel socket, PeerTransport transport) {
    final previous = _peerSockets[deviceId];
    _peerSockets[deviceId] = socket;
    _peerTransports[deviceId] = transport;
    if (previous != null && previous != socket) {
      previous.sink.close(WebSocketStatus.normalClosure, 'Upgraded transport');
    }
  }

  void _registerSocket(WebSocketChannel socket,
      {String name = '手机',
      String? id,
      bool isPeer = false,
      PeerTransport transport = PeerTransport.lan,
      bool isUpgrade = false,
      String? peerTailscaleAddress,
      int? peerPort}) {
    _sockets.add(socket);
    _clients[socket] = name;
    if (id != null) _clientIds[socket] = id;
    if (isPeer && id != null) {
      if (isUpgrade) {
        _swapPeerSocket(id, socket, transport);
      } else {
        _peerSockets[id] = socket;
        _peerTransports[id] = transport;
      }
    }
    var connectedEventAdded = isPeer;
    if (isPeer && !isUpgrade) {
      _events.add(TransferEvent(
          type: TransferEventType.clientConnected,
          createdAt: DateTime.now(),
          clientName: name,
          deviceId: id,
          isComputerPeer: true,
          peerTailscaleAddress: peerTailscaleAddress,
          peerPort: peerPort));
    }
    socket.stream.listen((message) {
      try {
        final data = jsonDecode(message as String) as Map<String, dynamic>;
        if (data['type'] == 'identify' && data['name'] is String) {
          final identifiedName = data['name'] as String;
          final identifiedId = data['id'] as String?;
          // Browsers report which browser they are; native peers do not.
          final identifiedAgent = data['agent'] as String?;
          final peer = data['peer'] == true && identifiedId != null;
          _clients[socket] = identifiedName;
          if (identifiedId != null) _clientIds[socket] = identifiedId;
          final peerAddress = data['address'] as String?;
          final peerPort = data['port'] as int?;
          if (peer &&
              peerAddress != null &&
              peerAddress.isNotEmpty &&
              peerPort != null) {
            _peerEndpoints[identifiedId] = _PeerEndpoint(
              deviceId: identifiedId,
              deviceName: identifiedName,
              address: peerAddress,
              port: peerPort,
              localDeviceId: _localDeviceId ?? '',
            );
            unawaited(_ensurePeerUploadSession(identifiedId));
          }
          var isLanUpgrade = false;
          if (peer) {
            // The dialer's callback address (identify's `address` field) is
            // set to its Tailscale address whenever it dialed us over
            // Tailscale (see connectToPeer's callbackAddress), so classifying
            // that single field is equivalent to and simpler than cross
            // -checking it against the separate `tailscaleAddress` field.
            final incomingTransport = peerAddress != null &&
                    _isTailscaleAddress(peerAddress)
                ? PeerTransport.tailscale
                : PeerTransport.lan;
            final existingSocket = _peerSockets[identifiedId];
            // The old leg's socket may have already closed by the time this
            // identify is processed (the two legs are independent TCP
            // connections racing each other), so fall back to the transport
            // it was last known to use.
            final existingTransport = _peerTransports[identifiedId] ??
                _recentlyClosedPeerTransports[identifiedId];
            isLanUpgrade = existingTransport == PeerTransport.tailscale &&
                incomingTransport == PeerTransport.lan &&
                (existingSocket == null || existingSocket != socket);
            if (existingSocket != null &&
                existingSocket != socket &&
                !isLanUpgrade) {
              socket.sink.close(
                  WebSocketStatus.normalClosure, 'Duplicate peer connection');
              return;
            }
            _recentlyClosedPeerTransports.remove(identifiedId);
            _swapPeerSocket(identifiedId, socket, incomingTransport);
          }
          if (!connectedEventAdded) {
            connectedEventAdded = true;
          }
          // An already connected phone can rename itself from its browser;
          // publish the new identity so the desktop list stays in sync. A
          // transport upgrade on an already-online peer must not replay a
          // clientConnected event: the UI treats that as a fresh connection
          // and would reset message state unnecessarily.
          if (identifiedId != null && !isLanUpgrade && !isUpgrade) {
            final tailscale = data['tailscaleAddress'] as String?;
            _events.add(TransferEvent(
                type: TransferEventType.clientConnected,
                createdAt: DateTime.now(),
                clientName: identifiedName,
                clientAgent: identifiedAgent,
                deviceId: identifiedId,
                isComputerPeer: peer,
                peerTailscaleAddress:
                    peer && tailscale != null && isTailscaleIpv4(tailscale)
                        ? tailscale
                        : null,
                peerPort: peer ? peerPort : null));
          }
        } else if (data['type'] == 'peer_text' && _clientIds[socket] != null) {
          _events.add(TransferEvent(
              type: TransferEventType.text,
              createdAt: DateTime.now(),
              text: data['text'] as String? ?? '',
              clientName: _clients[socket],
              deviceId: _clientIds[socket]));
        }
      } catch (_) {}
    }, onDone: () {
      final name = _clients.remove(socket) ?? '手机';
      final deviceId = _clientIds.remove(socket);
      final wasCurrentPeerSocket =
          deviceId != null && _peerSockets[deviceId] == socket;
      if (wasCurrentPeerSocket) {
        final closedTransport = _peerTransports[deviceId];
        if (closedTransport != null) {
          _recentlyClosedPeerTransports[deviceId] = closedTransport;
          Timer(const Duration(milliseconds: 800), () {
            if (_recentlyClosedPeerTransports[deviceId] == closedTransport) {
              _recentlyClosedPeerTransports.remove(deviceId);
            }
          });
        }
        _peerSockets.remove(deviceId);
        _peerSessions.remove(deviceId);
        _peerTransports.remove(deviceId);
      }
      _sockets.remove(socket);
      void publishDisconnectUnlessReplaced() {
        final hasReplacement = deviceId != null &&
            _clientIds.entries.any((entry) => entry.value == deviceId);
        if (deviceId != null && !hasReplacement) {
          _events.add(TransferEvent(
              type: TransferEventType.clientDisconnected,
              createdAt: DateTime.now(),
              clientName: name,
              deviceId: deviceId));
        }
      }

      if (wasCurrentPeerSocket) {
        // A LAN upgrade closes the old transport's socket deliberately, but
        // the two legs are independent TCP connections: the new one's
        // identify can arrive on the peer either just before or just after
        // this close notification, depending on OS scheduling. Give the
        // replacement a brief window to land before concluding the peer
        // actually went offline, so a transport swap never flashes
        // disconnected/reconnected in the UI. This only applies to peer
        // (computer) sockets: `isPeer` is the dial-time flag and is always
        // false for inbound sockets, so wasCurrentPeerSocket -- whether this
        // socket was actually registered as the peer connection -- is the
        // correct signal for both directions.
        Timer(const Duration(milliseconds: 800), publishDisconnectUnlessReplaced);
      } else {
        publishDisconnectUnlessReplaced();
      }
    });
  }

  bool _isPeerSocket(WebSocketChannel socket) =>
      _peerSockets.values.contains(socket);

  void _broadcast(Map<String, dynamic> payload) {
    final message = jsonEncode(payload);
    for (final socket in _sockets.toList()) {
      // An identified phone has a device ID too. Only desktop peer sockets must
      // be excluded from phone broadcasts; using _clientIds here previously
      // discarded every normally identified browser session.
      if (!_isPeerSocket(socket)) socket.sink.add(message);
    }
  }

  Future<Response> _asset(String asset, String contentType) async {
    final bytes = await _loadAsset(asset);
    return Response.ok(bytes,
        headers: {'content-type': contentType, 'cache-control': 'no-store'});
  }

  Response _forbidden() => Response.forbidden(
      'This SendHere link has expired. Scan the current QR code again.');

  Future<File> _uniqueFile(String filename) async {
    final base = path.basenameWithoutExtension(filename);
    final extension = path.extension(filename);
    var candidate = File(path.join(downloadDirectory.path, filename));
    var index = 2;
    while (await candidate.exists()) {
      candidate =
          File(path.join(downloadDirectory.path, '$base ($index)$extension'));
      index++;
    }
    return candidate;
  }

  String _contentDispositionFilename(String name) =>
      name.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  String? _boundaryFrom(String? contentType) {
    if (contentType == null) return null;
    return HeaderValue.parse(contentType).parameters['boundary'];
  }

  static Future<List<int>> _loadFlutterAsset(String asset) async =>
      (await rootBundle.load(asset)).buffer.asUint8List();

  static String _newToken() => base64UrlEncode(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
}

class _DownloadFile {
  const _DownloadFile({required this.file, required this.name});

  final File file;
  final String name;
}

class _PeerEndpoint {
  const _PeerEndpoint({
    required this.deviceId,
    required this.deviceName,
    required this.address,
    required this.port,
    required this.localDeviceId,
  });

  final String deviceId;
  final String deviceName;
  final String address;
  final int port;
  final String localDeviceId;
}

class _PeerSession {
  const _PeerSession({
    required this.deviceId,
    required this.deviceName,
    required this.senderDeviceId,
    required this.baseUri,
    required this.token,
    required this.expiresAt,
  });

  final String deviceId;
  final String deviceName;
  final String senderDeviceId;
  final Uri baseUri;
  final String token;
  final DateTime expiresAt;
}
