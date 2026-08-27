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
import 'package:web_socket_channel/web_socket_channel.dart';

import 'transfer_event.dart';

class LocalTransferServer {
  LocalTransferServer({
    required this.downloadDirectory,
    Future<List<int>> Function(String asset)? loadAsset,
  }) : _loadAsset = loadAsset ?? _loadFlutterAsset;

  final Directory downloadDirectory;
  final Future<List<int>> Function(String asset) _loadAsset;
  final _events = StreamController<TransferEvent>.broadcast();
  final _sockets = <WebSocketChannel>{};
  final _files = <String, File>{};
  final _clients = <WebSocketChannel, String>{};
  final _clientIds = <WebSocketChannel, String>{};
  final _peerTokens = <String, DateTime>{};
  final _peerSockets = <String, WebSocketChannel>{};
  final _peerSessions = <String, _PeerSession>{};

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
      _sockets.where((socket) => !_clientIds.containsKey(socket)).length;
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
      ..get('/ws', webSocketHandler(_handleSocket));

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
    _peerTokens.clear();
    await _server?.close(force: true);
    _server = null;
  }

  void refreshToken() {
    _token = _newToken();
    _expiresAt = DateTime.now().add(const Duration(minutes: 30));
    // Existing sockets were authorized by the previous QR code. Closing them
    // makes refresh a real revocation action rather than just a new link.
    for (final socket in _sockets.toList()) {
      socket.sink.close(WebSocketStatus.policyViolation, 'QR code refreshed');
    }
    _sockets.clear();
    _clients.clear();
  }

  Future<List<String>> localAddresses() async {
    final addresses = <String>[];
    for (final interface in await NetworkInterface.list()) {
      for (final address in interface.addresses) {
        if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
          addresses.add(address.address);
        }
      }
    }
    return addresses;
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
        'deviceName': Platform.localHostname,
        'expiresAt': _expiresAt.toIso8601String()
      }),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Future<Response> _handlePeerSession(Request request) async {
    _peerTokens.removeWhere((_, expiry) => DateTime.now().isAfter(expiry));
    final token = _newToken();
    _peerTokens[token] = DateTime.now().add(const Duration(minutes: 5));
    return Response.ok(
        jsonEncode({'token': token, 'name': Platform.localHostname}),
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
    final boundary = _boundaryFrom(request.headers['content-type']);
    if (boundary == null) {
      return Response(400, body: 'Expected multipart/form-data.');
    }
    final clientName = request.headers['x-sendhere-client-name'] ?? '手机';
    final deviceId = request.headers['x-sendhere-device-id'];
    final transformer = MimeMultipartTransformer(boundary);
    await for (final part in transformer.bind(request.read())) {
      final disposition =
          HeaderValue.parse(part.headers['content-disposition'] ?? '');
      final filename = disposition.parameters['filename'];
      if (filename == null || filename.isEmpty) continue;
      final safeName = path.basename(filename);
      final destination = await _uniqueFile(safeName);
      await part.pipe(destination.openWrite());
      final size = await destination.length();
      _events.add(TransferEvent(
          type: TransferEventType.file,
          createdAt: DateTime.now(),
          fileName: destination.path.split(Platform.pathSeparator).last,
          fileSize: size,
          clientName: clientName,
          deviceId: deviceId,
          localPath: destination.path));
      _broadcast({
        'type': 'file_received',
        'fileName': destination.path.split(Platform.pathSeparator).last,
        'fileSize': size
      });
    }
    return Response.ok(jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'});
  }

  Future<Response> _handleDownload(Request request, String id) async {
    if (!_isAuthorized(request)) return _forbidden();
    final file = _files[id];
    if (file == null || !await file.exists()) {
      return Response.notFound('File not found.');
    }
    return Response.ok(file.openRead(), headers: {
      'content-type': 'application/octet-stream',
      'content-disposition':
          'attachment; filename="${path.basename(file.path)}"',
      'content-length': (await file.length()).toString(),
    });
  }

  Future<void> connectToPeer({
    required String deviceId,
    required String deviceName,
    required String address,
    required int peerPort,
    required String localDeviceId,
  }) async {
    final client = HttpClient();
    try {
      if (hasPeer(deviceId)) return;
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
      final socketUri = Uri(
          scheme: 'ws',
          host: address,
          port: peerPort,
          path: '/ws',
          queryParameters: {'token': token});
      final socket = WebSocketChannel.connect(socketUri);
      _peerSessions[deviceId] = _PeerSession(
          deviceId: deviceId,
          deviceName: deviceName,
          senderDeviceId: localDeviceId,
          baseUri: Uri(scheme: 'http', host: address, port: peerPort),
          token: token);
      _registerSocket(socket, name: deviceName, id: deviceId, isPeer: true);
      socket.sink.add(jsonEncode({
        'type': 'identify',
        'name': Platform.localHostname,
        'id': localDeviceId,
        'peer': true,
      }));
    } finally {
      client.close(force: true);
    }
  }

  bool hasPeer(String deviceId) => _peerSockets.containsKey(deviceId);
  bool hasDevice(String deviceId) => _clientIds.values.contains(deviceId);

  void sendTextToDevice(String deviceId, String text) {
    if (text.trim().isEmpty) return;
    final socket = _sockets.cast<WebSocketChannel?>().firstWhere(
        (candidate) => candidate != null && _clientIds[candidate] == deviceId,
        orElse: () => null);
    if (socket == null) return;
    _events.add(TransferEvent(
        type: TransferEventType.text,
        direction: TransferDirection.sent,
        createdAt: DateTime.now(),
        text: text,
        clientName: _clients[socket],
        deviceId: deviceId));
    socket.sink.add(jsonEncode(_peerSockets[deviceId] == socket
        ? {'type': 'peer_text', 'text': text}
        : {'type': 'desktop_text', 'text': text}));
  }

  Future<void> offerFileToDevice(String deviceId, File file) async {
    final socket = _sockets.cast<WebSocketChannel?>().firstWhere(
        (candidate) => candidate != null && _clientIds[candidate] == deviceId,
        orElse: () => null);
    if (socket == null) throw StateError('设备未连接');
    if (_peerSockets[deviceId] == socket) {
      await sendFileToPeer(deviceId, file);
      return;
    }
    final id = _newToken();
    _files[id] = file;
    _events.add(TransferEvent(
        type: TransferEventType.file,
        direction: TransferDirection.sent,
        createdAt: DateTime.now(),
        fileName: path.basename(file.path),
        fileSize: await file.length(),
        clientName: _clients[socket],
        deviceId: deviceId,
        localPath: file.path));
    socket.sink.add(jsonEncode({
      'type': 'desktop_file',
      'fileName': path.basename(file.path),
      'downloadPath': '/api/download/$id',
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

  Future<void> sendFileToPeer(String deviceId, File file) async {
    final session = _peerSessions[deviceId];
    if (session == null || !hasPeer(deviceId)) {
      throw StateError('设备未连接');
    }
    final boundary = 'sendhere-${_newToken()}';
    final filename = path.basename(file.path);
    final prefix = utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="$filename"\r\n'
        'Content-Type: ${lookupMimeType(filename) ?? 'application/octet-stream'}\r\n\r\n');
    const suffix = '\r\n--';
    final ending = utf8.encode('$suffix$boundary--\r\n');
    final client = HttpClient();
    try {
      final request =
          await client.postUrl(session.baseUri.replace(path: '/api/upload'));
      request.headers
        ..set(HttpHeaders.contentTypeHeader,
            'multipart/form-data; boundary=$boundary')
        ..set('x-sendhere-token', session.token)
        ..set('x-sendhere-client-name', Platform.localHostname)
        ..set('x-sendhere-device-id', session.senderDeviceId);
      request.contentLength =
          prefix.length + await file.length() + ending.length;
      request.add(prefix);
      await request.addStream(file.openRead());
      request.add(ending);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('设备拒绝了文件传输（${response.statusCode}）');
      }
      await response.drain();
      _events.add(TransferEvent(
          type: TransferEventType.file,
          direction: TransferDirection.sent,
          createdAt: DateTime.now(),
          fileName: filename,
          fileSize: await file.length(),
          clientName: session.deviceName,
          deviceId: deviceId,
          localPath: file.path));
    } finally {
      client.close(force: true);
    }
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
    _files[id] = file;
    _events.add(TransferEvent(
        type: TransferEventType.file,
        direction: TransferDirection.sent,
        createdAt: DateTime.now(),
        fileName: path.basename(file.path),
        fileSize: await file.length(),
        clientName: connectedDeviceNames,
        localPath: file.path));
    _broadcast({
      'type': 'desktop_file',
      'fileName': path.basename(file.path),
      'downloadPath': '/api/download/$id'
    });
  }

  void _handleSocket(WebSocketChannel socket) => _registerSocket(socket);

  void _registerSocket(WebSocketChannel socket,
      {String name = '手机', String? id, bool isPeer = false}) {
    _sockets.add(socket);
    _clients[socket] = name;
    if (id != null) _clientIds[socket] = id;
    if (isPeer && id != null) _peerSockets[id] = socket;
    var connectedEventAdded = isPeer;
    if (isPeer) {
      _events.add(TransferEvent(
          type: TransferEventType.clientConnected,
          createdAt: DateTime.now(),
          clientName: name,
          deviceId: id));
    }
    socket.stream.listen((message) {
      try {
        final data = jsonDecode(message as String) as Map<String, dynamic>;
        if (data['type'] == 'identify' && data['name'] is String) {
          final identifiedName = data['name'] as String;
          final identifiedId = data['id'] as String?;
          final peer = data['peer'] == true && identifiedId != null;
          _clients[socket] = identifiedName;
          if (identifiedId != null) _clientIds[socket] = identifiedId;
          if (peer) {
            final existingSocket = _peerSockets[identifiedId];
            if (existingSocket != null && existingSocket != socket) {
              socket.sink.close(
                  WebSocketStatus.normalClosure, 'Duplicate peer connection');
              return;
            }
            _peerSockets[identifiedId] = socket;
          }
          if (!connectedEventAdded) {
            connectedEventAdded = true;
          }
          // An already connected phone can rename itself from its browser;
          // publish the new identity so the desktop list stays in sync.
          if (identifiedId != null) {
            _events.add(TransferEvent(
                type: TransferEventType.clientConnected,
                createdAt: DateTime.now(),
                clientName: identifiedName,
                deviceId: identifiedId));
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
      if (deviceId != null && _peerSockets[deviceId] == socket) {
        _peerSockets.remove(deviceId);
        _peerSessions.remove(deviceId);
      }
      _sockets.remove(socket);
      final hasReplacement = deviceId != null &&
          _clientIds.entries.any((entry) => entry.value == deviceId);
      if (deviceId != null && !hasReplacement) {
        _events.add(TransferEvent(
            type: TransferEventType.clientDisconnected,
            createdAt: DateTime.now(),
            clientName: name,
            deviceId: deviceId));
      }
    });
  }

  void _broadcast(Map<String, dynamic> payload) {
    final message = jsonEncode(payload);
    for (final socket in _sockets.toList()) {
      // Phone sessions retain the existing broadcast behavior. Desktop peers
      // are private conversations and must only receive targeted messages.
      if (!_clientIds.containsKey(socket)) socket.sink.add(message);
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

class _PeerSession {
  const _PeerSession({
    required this.deviceId,
    required this.deviceName,
    required this.senderDeviceId,
    required this.baseUri,
    required this.token,
  });

  final String deviceId;
  final String deviceName;
  final String senderDeviceId;
  final Uri baseUri;
  final String token;
}
