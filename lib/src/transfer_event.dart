enum TransferEventType { text, file, clientConnected, clientDisconnected }

enum TransferDirection { received, sent }

enum FileTransferStatus { waiting, uploading, completed, failed }

class TransferEvent {
  const TransferEvent({
    required this.type,
    required this.createdAt,
    this.direction = TransferDirection.received,
    this.clientName,
    this.clientAgent,
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

  /// For browser sessions, the browser or in-app container they run in
  /// ("Safari", "微信", "App"). Null for native peers.
  final String? clientAgent;
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

  /// A sent non-image file keeps no app copy once it is delivered, so its
  /// completed event drops the local path. Images keep their copy for
  /// previews and "save to device".
  TransferEvent withoutUnkeptSentCopy() {
    if (type != TransferEventType.file ||
        direction != TransferDirection.sent ||
        fileStatus != FileTransferStatus.completed ||
        localPath == null ||
        isImageFileName(fileName)) {
      return this;
    }
    return TransferEvent(
      type: type,
      createdAt: createdAt,
      direction: direction,
      clientName: clientName,
      clientAgent: clientAgent,
      deviceId: deviceId,
      text: text,
      fileName: fileName,
      fileSize: fileSize,
      downloadPath: downloadPath,
      transferId: transferId,
      fileStatus: fileStatus,
      bytesTransferred: bytesTransferred,
      errorMessage: errorMessage,
      isComputerPeer: isComputerPeer,
      peerTailscaleAddress: peerTailscaleAddress,
      peerPort: peerPort,
    );
  }
}

const _imageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
  '.heic',
};

bool isImageFileName(String? fileName) {
  final name = fileName?.toLowerCase() ?? '';
  return _imageExtensions.any(name.endsWith);
}
