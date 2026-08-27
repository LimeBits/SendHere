const token = new URLSearchParams(location.search).get('token');
const headers = { 'x-sendhere-token': token };
const text = document.querySelector('#text');
const incoming = document.querySelector('#incoming');
const status = document.querySelector('#upload-status');
const deviceNameLabel = document.querySelector('#device-name');
const computerNameLabel = document.querySelector('#computer-name');
const browserIdKey = 'sendhere-device-id';
let browserId = localStorage.getItem(browserIdKey);
if (!browserId) {
  browserId = Math.random().toString(36).slice(2, 10).toUpperCase();
  localStorage.setItem(browserIdKey, browserId);
}
const isWeChat = /MicroMessenger/i.test(navigator.userAgent);
const isIPhone = /iPhone/i.test(navigator.userAgent);
const clientName = `${isWeChat ? '微信 ' : ''}${isIPhone ? 'iPhone' : '手机'} · ${browserId.slice(-4)}`;
let socket;
let reconnectTimer;
let heartbeatTimer;
let reconnectDelay = 1000;

function renderDeviceName() {
  deviceNameLabel.textContent = `这台手机：${clientName}`;
}

renderDeviceName();

function showIncoming(node) {
  incoming.classList.remove('empty');
  incoming.prepend(node);
}

function addText(value) {
  const block = document.createElement('article');
  const content = document.createElement('div');
  content.className = 'content';
  content.textContent = value;
  const copy = document.createElement('button');
  copy.className = 'secondary';
  copy.textContent = '复制';
  copy.onclick = () => navigator.clipboard.writeText(value);
  block.append(content, copy);
  const url = value.match(/^https?:\/\/\S+$/);
  if (url) {
    const open = document.createElement('a');
    open.href = url[0];
    open.target = '_blank';
    open.rel = 'noopener';
    open.textContent = '打开链接';
    block.append(open);
  }
  showIncoming(block);
}

function addFile(name, downloadPath) {
  const block = document.createElement('article');
  block.textContent = `电脑发来文件：${name}`;
  const link = document.createElement('a');
  link.href = `${downloadPath}?token=${encodeURIComponent(token)}`;
  link.textContent = '下载';
  block.append(document.createElement('br'), link);
  showIncoming(block);
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

document.querySelector('#send-text').onclick = async () => {
  const value = text.value.trim();
  if (!value) return;
  const response = await request('/api/text?token=' + encodeURIComponent(token), {
    method: 'POST',
    headers: { ...headers, 'content-type': 'application/json' },
    body: JSON.stringify({ text: value, clientName, deviceId: browserId }),
  });
  if (response.ok) {
    text.value = '';
    status.textContent = '已发送到电脑';
  } else if (response.status !== 403) {
    status.textContent = '发送失败，请重新扫码。';
  }
};

document.querySelector('#files').onchange = async event => {
  const files = [...event.target.files];
  if (!files.length) return;
  status.textContent = '正在上传…';
  const data = new FormData();
  files.forEach(file => data.append('files', file));
  const response = await request('/api/upload?token=' + encodeURIComponent(token), {
    method: 'POST',
    headers: {
      ...headers,
      'x-sendhere-client-name': clientName,
      'x-sendhere-device-id': browserId,
    },
    body: data,
  });
  if (response.status !== 403) {
    status.textContent = response.ok ? '上传完成' : '上传失败，请重新扫码后重试。';
  }
  event.target.value = '';
};

request('/api/status?token=' + encodeURIComponent(token))
  .then(response => response.ok ? response.json() : null)
  .then(data => {
    if (data) computerNameLabel.textContent = `已连接到电脑：${data.deviceName}`;
  })
  .catch(() => computerNameLabel.textContent = '连接已失效，请重新扫码');

const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
const socketUrl = `${protocol}//${location.host}/ws?token=${encodeURIComponent(token)}`;

function setConnectionStatus(message) {
  status.textContent = message;
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
    const event = JSON.parse(data);
    if (event.type === 'desktop_text') addText(event.text);
    if (event.type === 'desktop_file') addFile(event.fileName, event.downloadPath);
  };
  socket.onclose = event => {
    stopHeartbeat();
    if (event.code === 1008) {
      showExpired();
      return;
    }
    setConnectionStatus('连接暂时中断，正在恢复…');
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

connectSocket();
