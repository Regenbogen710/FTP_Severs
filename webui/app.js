const state = {
  csrfToken: '',
  config: null,
};

const fields = [
  'FTP_ROOT',
  'HOST',
  'PORT',
  'PERMISSION',
  'CUSTOM_PERMISSIONS',
  'PASSIVE_PORTS',
  'FTP_ENCODING',
  'MAX_DOWNLOAD_SIZE_MB',
  'USERNAME',
  'WATCHDOG_INTERVAL_SECONDS',
  'PYFTPDLIB_PACKAGE',
];

const checks = [
  'ALLOW_ANONYMOUS',
  'DANGEROUS_ALLOW_ANONYMOUS_DELETE',
  'AUTO_INSTALL_PYFTPDLIB',
  'ENABLE_FRONTEND',
];

function byId(id) {
  return document.getElementById(id);
}

function setMessage(text, type = '') {
  const el = byId('message');
  el.className = `notice ${type}`.trim();
  el.textContent = text || '';
}

function setBusy(isBusy) {
  for (const id of ['startBtn', 'stopBtn', 'refreshBtn']) {
    byId(id).disabled = isBusy;
  }
  byId('configForm').querySelector('button[type="submit"]').disabled = isBusy;
}

async function api(path, options = {}) {
  const headers = {
    Accept: 'application/json',
    ...(options.headers || {}),
  };

  if (options.body) {
    headers['Content-Type'] = 'application/json';
  }

  if (options.method && options.method !== 'GET') {
    headers['X-CSRF-Token'] = state.csrfToken;
  }

  const res = await fetch(path, {
    ...options,
    headers,
    credentials: 'same-origin',
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.error || `请求失败：${res.status}`);
  }
  return data;
}

function fillConfig(config) {
  state.config = config;
  for (const key of fields) {
    byId(key).value = config[key] ?? '';
  }
  for (const key of checks) {
    byId(key).checked = String(config[key]).toLowerCase() === 'true';
  }
  byId('PASSWORD').value = '';
}

function renderStatus(status) {
  const running = Boolean(status.ftpRunning);
  const badge = byId('serverState');
  badge.className = `status-pill ${running ? 'running' : 'stopped'}`;
  badge.textContent = running ? 'FTP 运行中' : 'FTP 未运行';

  byId('ftpUrl').textContent = status.ftpUrl || '-';
  byId('ftpRoot').textContent = status.ftpRoot || '-';
  byId('ftpPermission').textContent = status.permission || '-';
  byId('watchdogs').textContent = status.watchdogs || '-';
  byId('lastUpdated').textContent = `上次刷新：${new Date().toLocaleTimeString()}`;
}

function collectConfig() {
  const payload = {};
  for (const key of fields) {
    payload[key] = byId(key).value.trim();
  }
  for (const key of checks) {
    payload[key] = byId(key).checked ? 'true' : 'false';
  }

  const password = byId('PASSWORD').value;
  if (password) {
    payload.PASSWORD = password;
  }
  return payload;
}

async function loadAll() {
  setBusy(true);
  try {
    const session = await api('/api/session');
    state.csrfToken = session.csrfToken;
    const [configData, statusData] = await Promise.all([
      api('/api/config'),
      api('/api/status'),
    ]);
    fillConfig(configData.config);
    renderStatus(statusData.status);
    setMessage('');
  } catch (error) {
    setMessage(error.message, 'error');
  } finally {
    setBusy(false);
  }
}

async function saveConfig(event) {
  event.preventDefault();
  setBusy(true);
  try {
    const payload = collectConfig();
    if (payload.DANGEROUS_ALLOW_ANONYMOUS_DELETE === 'true') {
      const ok = window.confirm('匿名删除会让同网络用户删除 FTP 文件。确定保存吗？');
      if (!ok) return;
    }
    if (payload.ENABLE_FRONTEND !== 'true') {
      const ok = window.confirm('关闭前端后，下次运行 start_control_panel.bat 将不会打开控制面板。确定保存吗？');
      if (!ok) return;
    }
    const data = await api('/api/config', {
      method: 'POST',
      body: JSON.stringify(payload),
    });
    fillConfig(data.config);
    const statusData = await api('/api/status');
    renderStatus(statusData.status);
    setMessage('配置已保存。启动或重启 FTP 后生效。', 'success');
  } catch (error) {
    setMessage(error.message, 'error');
  } finally {
    setBusy(false);
  }
}

async function startFtp() {
  setBusy(true);
  try {
    await api('/api/start', { method: 'POST' });
    const statusData = await api('/api/status');
    renderStatus(statusData.status);
    setMessage('启动命令已发送。', 'success');
  } catch (error) {
    setMessage(error.message, 'error');
  } finally {
    setBusy(false);
  }
}

async function stopFtp() {
  setBusy(true);
  try {
    await api('/api/stop', { method: 'POST' });
    const statusData = await api('/api/status');
    renderStatus(statusData.status);
    setMessage('停止命令已发送。', 'success');
  } catch (error) {
    setMessage(error.message, 'error');
  } finally {
    setBusy(false);
  }
}

document.addEventListener('DOMContentLoaded', () => {
  byId('configForm').addEventListener('submit', saveConfig);
  byId('startBtn').addEventListener('click', startFtp);
  byId('stopBtn').addEventListener('click', stopFtp);
  byId('refreshBtn').addEventListener('click', loadAll);
  loadAll();
});
