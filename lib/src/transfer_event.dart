enum TransferEventType { text, file, clientConnected, clientDisconnected }

enum TransferDirection { received, sent }

class TransferEvent {
  const TransferEvent({
    required this.type,
    required this.createdAt,
    this.direction = TransferDirection.received,
    this.clientName,
    this.deviceId,
    this.text,
    this.fileName,
    this.fileSize,
    this.downloadPath,
    this.localPath,
  });

  final TransferEventType type;
  final DateTime createdAt;
  final TransferDirection direction;
  final String? clientName;
  final String? deviceId;
  final String? text;
  final String? fileName;
  final int? fileSize;
  final String? downloadPath;
  final String? localPath;
}
