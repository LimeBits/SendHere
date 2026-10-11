enum TransferEventType { text, file, clientConnected, clientDisconnected }

enum TransferDirection { received, sent }

enum FileTransferStatus { waiting, uploading, completed, failed }

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
    this.transferId,
    this.fileStatus = FileTransferStatus.completed,
    this.bytesTransferred,
    this.errorMessage,
    this.isComputerPeer = false,
    this.peerTailscaleAddress,
    this.peerPort,
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
  final String? transferId;
  final FileTransferStatus fileStatus;
  final int? bytesTransferred;
  final String? errorMessage;
  final bool isComputerPeer;

  /// Tailscale address a computer peer advertised in its identify message,
  /// remembered so the two computers can reconnect when not on the same LAN.
  final String? peerTailscaleAddress;
  final int? peerPort;
}
