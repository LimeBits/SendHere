const token = new URLSearchParams(location.search).get('token');
const headers = { 'x-sendhere-token': token };
const text = document.querySelector('#text');
const messages = document.querySelector('#messages');
const emptyState = document.querySelector('#empty-state');
const status = document.querySelector('#upload-status');
const deviceNameLabel = document.querySelector('#device-name');
const computerNameLabel = document.querySelector('#computer-name');
const connectionStatus = document.querySelector('#connection-status');
const sendButton = document.querySelector('#send-text');
const filesInput = document.querySelector('#files');
const browserIdKey = 'sendhere-device-id';
let browserId = localStorage.getItem(browserIdKey);
if (!browserId) {
  browserId = Math.random().toString(36).slice(2, 10).toUpperCase();
  localStorage.setItem(browserIdKey, browserId);
}
const isWeChat = /MicroMessenger/i.test(navigator.userAgent);
const isIPhone = /iPhone/i.test(navigator.userAgent);
const clientName = `${isWeChat ? '微信 ' : ''}${isIPhone ? 'iPhone' : '手机'} · ${browserId.slice(-4)}`;
const historyKey = `sendhere-chat-history:${token}:${browserId}`;
const historyLimit = 100;
let socket;
let reconnectTimer;
let heartbeatTimer;
let reconnectDelay = 1000;

function renderDeviceName() {
  deviceNameLabel.textContent = `这台手机：${clientName}`;
}

function scrollToLatest() {
  requestAnimationFrame(() => {
    messages.scrollTop = messages.scrollHeight;
    requestAnimationFrame(() => { messages.scrollTop = messages.scrollHeight; });
  });
}

function showMessage(node, entry) {
  emptyState?.remove();
  messages.append(node);
  if (entry) saveHistoryEntry(entry);
  scrollToLatest();
}

function loadHistory() {
  try {
    return JSON.parse(sessionStorage.getItem(historyKey) || '[]');
  } catch (_) {
    return [];
  }
}

function saveHistoryEntry(entry) {
  const entries = loadHistory();
  entries.push(entry);
  sessionStorage.setItem(historyKey, JSON.stringify(entries.slice(-historyLimit)));
}

function restoreHistory() {
  for (const entry of loadHistory()) {
    if (entry.type === 'text') {
      const content = textContent(entry.text);
      showMessage(messageBubble({ direction: entry.direction, content, meta: entry.meta }));
    } else if (entry.type === 'file') {
      const content = fileContent(entry.name, entry.downloadPath);
      showMessage(messageBubble({ direction: entry.direction, content, meta: entry.meta }));
    }
  }
}

function messageBubble({ direction, content, meta }) {
  const row = document.createElement('article');
  row.className = `message ${direction}`;
  const bubble = document.createElement('div');
  bubble.className = 'message-bubble';
  bubble.append(content);
  if (meta) {
    const detail = document.createElement('div');
    detail.className = 'message-meta';
    detail.textContent = meta;
    bubble.append(detail);
  }
  row.append(bubble);
  return row;
}

function textContent(value) {
  const content = document.createElement('div');
  content.className = 'message-text';
  content.textContent = value;
  return content;
}

function isImage(name) {
  return /\.(avif|gif|heic|heif|jpe?g|png|webp)$/i.test(name);
}

function showImagePreview(source, name) {
  const overlay = document.createElement('div');
  overlay.className = 'image-preview';
  const image = document.createElement('img');
  image.src = source;
  image.alt = name;
  const close = document.createElement('button');
  close.type = 'button';
  close.className = 'preview-close';
  close.setAttribute('aria-label', '关闭预览');
  close.textContent = '×';
  const download = document.createElement('a');
  download.className = 'preview-download';
  download.href = source;
  download.download = name;
  download.setAttribute('aria-label', '下载图片');
  const downloadIcon = document.createElement('span');
  downloadIcon.className = 'download-glyph';
  downloadIcon.setAttribute('aria-hidden', 'true');
  download.append(downloadIcon);
  let dragStartY;
  const dismiss = () => overlay.remove();
  close.onclick = dismiss;
  image.onclick = dismiss;
  image.onpointerdown = event => { dragStartY = event.clientY; };
  image.onpointerup = event => {
    if (dragStartY != null && event.clientY - dragStartY > 90) dismiss();
    dragStartY = undefined;
  };
  image.onpointercancel = () => { dragStartY = undefined; };
  overlay.onclick = event => {
    if (event.target === overlay) dismiss();
  };
  overlay.append(image, close, download);
  document.body.append(overlay);
}

function imageContent(name, source) {
  const content = document.createElement('div');
  content.className = 'image-card';
  const image = document.createElement('img');
  image.className = 'image-thumbnail';
  image.src = source;
  image.alt = name;
  image.loading = 'eager';
  image.onload = scrollToLatest;
  image.onerror = scrollToLatest;
  image.onclick = () => showImagePreview(source, name);
  const label = document.createElement('div');
  label.className = 'image-name';
  label.textContent = name;
  content.append(image, label);
  return content;
}

function fileContent(name, downloadPath) {
  if (isImage(name) && downloadPath) {
    return imageContent(name, `${downloadPath}?token=${encodeURIComponent(token)}`);
  }
  const content = document.createElement('div');
  content.className = 'file-card';
  const icon = document.createElement('span');
  icon.className = 'file-icon';
  icon.textContent = '▤';
  const detail = document.createElement('div');
  const title = document.createElement('div');
  title.className = 'file-name';
  title.textContent = name;
  detail.append(title);
  if (downloadPath) {
    const link = document.createElement('a');
    link.className = 'download-link';
    link.href = `${downloadPath}?token=${encodeURIComponent(token)}`;
    link.textContent = '下载到本地';
    detail.append(link);
  }
  content.append(icon, detail);
  return content;
}

function addIncomingText(value) {
  showMessage(messageBubble({ direction: 'incoming', content: textContent(value) }), {
    type: 'text', direction: 'incoming', text: value,
  });
}

function addIncomingFile(name, downloadPath) {
  const meta = '电脑发来的文件';
  showMessage(messageBubble({
    direction: 'incoming', content: fileContent(name, downloadPath), meta,
  }), { type: 'file', direction: 'incoming', name, downloadPath, meta });
}

function addOutgoingText(value) {
  const meta = '已发送';
  showMessage(messageBubble({ direction: 'outgoing', content: textContent(value), meta }), {
    type: 'text', direction: 'outgoing', text: value, meta,
  });
}

function addOutgoingFile(file, state = '已发送') {
  const content = isImage(file.name)
    ? imageContent(file.name, URL.createObjectURL(file))
    : fileContent(file.name);
  showMessage(messageBubble({ direction: 'outgoing', content, meta: state }), {
    type: 'file', direction: 'outgoing', name: file.name, meta: state,
  });
}

function showExpired() {
  clearTimeout(reconnectTimer);
  clearInterval(heartbeatTimer);
  location.replace('/?expired=1');
}

async function request(url, options) {
  const response = await fetch(url, options);
  if (response.status === 403) showExpired();
  return response;
}

function resizeComposer() {
  text.style.height = 'auto';
  text.style.height = `${Math.min(text.scrollHeight, 126)}px`;
}

async function sendText() {
  const value = text.value.trim();
  if (!value || sendButton.disabled) return;
  sendButton.disabled = true;
  try {
    const response = await request('/api/text?token=' + encodeURIComponent(token), {
      method: 'POST',
      headers: { ...headers, 'content-type': 'application/json' },
      body: JSON.stringify({ text: value, clientName, deviceId: browserId }),
    });
    if (response.ok) {
      text.value = '';
      resizeComposer();
      addOutgoingText(value);
      status.textContent = '';
    } else if (response.status !== 403) {
      status.textContent = '文字发送失败，请检查连接后重试。';
    }
  } catch (_) {
    status.textContent = '文字发送失败，请检查网络后重试。';
  } finally {
    sendButton.disabled = false;
  }
}

sendButton.onclick = sendText;
text.addEventListener('input', resizeComposer);
// The mobile keyboard's return key always inserts a newline. Sending is an
// explicit action through the button, matching the native mobile app.
resizeComposer();

async function uploadFile(file) {
  // Upload one File as the request body rather than as multipart/form-data.
  // WeChat's iOS WebView can leave a multipart upload pending on an HTTP LAN
  // origin, while direct File requests include a determinate content length.
  const response = await request('/api/upload?token=' + encodeURIComponent(token), {
    method: 'POST',
    headers: {
      ...headers,
      'content-type': file.type || 'application/octet-stream',
      'x-sendhere-client-name': encodeURIComponent(clientName),
      'x-sendhere-device-id': browserId,
      'x-sendhere-file-name': encodeURIComponent(file.name),
    },
    body: file,
  });
  if (!response.ok && response.status !== 403) {
    throw new Error(`Upload failed (${response.status})`);
  }
}

filesInput.onchange = async event => {
  const files = [...event.target.files];
  if (!files.length) return;
  try {
    for (let index = 0; index < files.length; index++) {
      status.textContent = files.length === 1
        ? `正在发送 ${files[index].name}…`
        : `正在发送 ${index + 1}/${files.length}：${files[index].name}`;
      await uploadFile(files[index]);
      addOutgoingFile(files[index]);
    }
    status.textContent = '';
  } catch (_) {
    status.textContent = '文件发送失败，请检查连接后重试。';
  } finally {
    event.target.value = '';
  }
};

request('/api/status?token=' + encodeURIComponent(token))
  .then(response => response.ok ? response.json() : null)
  .then(data => {
    if (data) computerNameLabel.textContent = data.deviceName;
  })
  .catch(() => {
    computerNameLabel.textContent = '电脑连接不可用';
    connectionStatus.textContent = '连接已失效，请重新扫码';
    connectionStatus.className = 'connection-status is-offline';
  });

const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
const socketUrl = `${protocol}//${location.host}/ws?token=${encodeURIComponent(token)}`;

function setConnectionStatus(message, state = '') {
  connectionStatus.textContent = message;
  connectionStatus.className = `connection-status ${state}`.trim();
}

function stopHeartbeat() {
  clearInterval(heartbeatTimer);
  heartbeatTimer = undefined;
}

function scheduleReconnect() {
  clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(connectSocket, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, 10000);
}

function identify() {
  socket.send(JSON.stringify({ type: 'identify', name: clientName, id: browserId }));
}

function connectSocket() {
  if (!token) {
    showExpired();
    return;
  }
  stopHeartbeat();
  socket = new WebSocket(socketUrl);
  socket.onopen = () => {
    reconnectDelay = 1000;
    identify();
    heartbeatTimer = setInterval(() => {
      if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'ping' }));
    }, 25000);
    setConnectionStatus('已连接到电脑');
  };
  socket.onmessage = ({ data }) => {
    try {
      const event = JSON.parse(data);
      if (event.type === 'desktop_text') addIncomingText(event.text);
      if (event.type === 'desktop_file') addIncomingFile(event.fileName, event.downloadPath);
    } catch (_) {
      status.textContent = '收到了一条无法识别的消息。';
    }
  };
  socket.onclose = event => {
    stopHeartbeat();
    if (event.code === 1008) {
      showExpired();
      return;
    }
    setConnectionStatus('连接暂时中断，正在恢复…', 'is-reconnecting');
    scheduleReconnect();
  };
  socket.onerror = () => socket.close();
}

document.addEventListener('visibilitychange', () => {
  if (!document.hidden && (!socket || socket.readyState !== WebSocket.OPEN)) {
    clearTimeout(reconnectTimer);
    reconnectDelay = 1000;
    connectSocket();
  }
});

renderDeviceName();
restoreHistory();
connectSocket();
