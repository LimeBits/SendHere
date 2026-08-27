import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NearbyDevice {
  const NearbyDevice({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
  });

  final String id;
  final String name;
  final String address;
  final int port;
}

/// Publishes this desktop and maintains the list of nearby SendHere desktops.
/// Authentication tokens never appear in mDNS TXT records.
class NearbyDeviceService {
  static const serviceType = '_sendhere._tcp';
  final _devices = StreamController<List<NearbyDevice>>.broadcast();
  final _known = <String, NearbyDevice>{};

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription? _subscription;
  String? deviceId;
  String? deviceName;

  Stream<List<NearbyDevice>> get devices => _devices.stream;

  Future<void> start({required int port}) async {
    final preferences = await SharedPreferences.getInstance();
    deviceId = preferences.getString('sendhere-device-id');
    if (deviceId == null) {
      deviceId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      await preferences.setString('sendhere-device-id', deviceId!);
    }
    deviceName = Platform.localHostname;

    final service = BonsoirService(
      name: deviceName!,
      type: serviceType,
      port: port,
      attributes: {'v': '1', 'id': deviceId!, 'name': deviceName!},
    );
    _broadcast = BonsoirBroadcast(service: service, printLogs: false);
    await _broadcast!.initialize();
    await _broadcast!.start();

    _discovery = BonsoirDiscovery(type: serviceType, printLogs: false);
    await _discovery!.initialize();
    _subscription = _discovery!.eventStream?.listen(_handleEvent);
    await _discovery!.start();
  }

  void _handleEvent(BonsoirDiscoveryEvent event) {
    final service = event.service;
    if (service == null) return;
    final id = service.attributes['id'];
    if (id == null || id == deviceId) return;

    if (event is BonsoirDiscoveryServiceFoundEvent) {
      service.resolve(_discovery!.serviceResolver);
      return;
    }
    if (event is BonsoirDiscoveryServiceResolvedEvent ||
        event is BonsoirDiscoveryServiceUpdatedEvent) {
      final address = service.hostAddresses.firstWhere(
          (address) =>
              InternetAddress.tryParse(address)?.type ==
              InternetAddressType.IPv4,
          orElse: () =>
              service.hostAddresses.isEmpty ? '' : service.hostAddresses.first);
      if (address.isEmpty) return;
      _known[id] = NearbyDevice(
        id: id,
        name: service.attributes['name'] ?? service.name,
        address: address,
        port: service.port,
      );
      _devices.add(
          _known.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
    }
    if (event is BonsoirDiscoveryServiceLostEvent) {
      _known.remove(id);
      _devices.add(
          _known.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    await _discovery?.stop();
    await _broadcast?.stop();
    await _devices.close();
  }
}
