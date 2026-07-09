let token = null;

async function api(method, path, body) {
  const opts = {
    method,
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` }
  };
  if (body) opts.body = JSON.stringify(body);
  const res = await fetch(path, opts);
  if (res.status === 401) { showLogin(); return null; }
  if (res.status === 403) { alert('Access denied'); return null; }
  return res.json();
}

function showLogin() {
  document.getElementById('login-screen').classList.remove('hidden');
  document.getElementById('main-screen').classList.add('hidden');
  localStorage.removeItem('token');
  token = null;
}

function showMain() {
  document.getElementById('login-screen').classList.add('hidden');
  document.getElementById('main-screen').classList.remove('hidden');
}

document.getElementById('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const user = document.getElementById('login-user').value;
  const pass = document.getElementById('login-pass').value;
  const errEl = document.getElementById('login-error');
  try {
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: user, password: pass })
    });
    if (!res.ok) { errEl.textContent = 'Invalid credentials'; return; }
    const data = await res.json();
    token = data.token;
    localStorage.setItem('token', data.token);
    showMain();
    loadDashboard();
  } catch { errEl.textContent = 'Connection error'; }
});

document.getElementById('logout-btn').addEventListener('click', showLogin);

const savedToken = localStorage.getItem('token');
if (savedToken) {
  token = savedToken;
  showMain();
  loadDashboard();
} else { showLogin(); }

document.querySelectorAll('#sidebar nav a').forEach(a => {
  a.addEventListener('click', (e) => {
    e.preventDefault();
    document.querySelectorAll('#sidebar nav a').forEach(x => x.classList.remove('active'));
    a.classList.add('active');
    document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
    const page = document.getElementById(`page-${a.dataset.page}`);
    if (page) {
      page.classList.add('active');
      const fn = `load${a.dataset.page.charAt(0).toUpperCase() + a.dataset.page.slice(1)}`;
      if (window[fn]) window[fn]();
    }
  });
});

async function loadDashboard() {
  const el = document.getElementById('page-dashboard');
  const data = await api('GET', '/api/dashboard/stats');
  if (!data) return;

  el.innerHTML = `
    <h1>📊 Dashboard</h1>
    <div class="stats-grid">
      <div class="stat-card">
        <div class="label">Server</div>
        <div class="value ${data.server && data.server.online ? 'green' : 'red'}">
          ${data.server && data.server.online ? 'Online' : 'Offline'}
        </div>
      </div>
      <div class="stat-card">
        <div class="label">Online Clients</div>
        <div class="value">${data.server ? data.server.onlineClients || 0 : '?'}</div>
      </div>
      <div class="stat-card">
        <div class="label">Active Tickets</div>
        <div class="value ${data.tickets && data.tickets.active_count > 0 ? 'yellow' : 'green'}">
          ${data.tickets ? data.tickets.active_count || 0 : '?'}
        </div>
      </div>
      <div class="stat-card">
        <div class="label">Total Users</div>
        <div class="value">${data.levels ? data.levels.totalUsers || 0 : '?'}</div>
      </div>
      <div class="stat-card">
        <div class="label">Total XP Earned</div>
        <div class="value green">${data.levels ? (data.levels.totalXp || 0).toLocaleString() : '?'}</div>
      </div>
      <div class="stat-card">
        <div class="label">Voice Hours</div>
        <div class="value">${data.levels ? data.levels.totalVoiceHours || 0 : '?'}</div>
      </div>
      <div class="stat-card">
        <div class="label">Active Temp Channels</div>
        <div class="value">${data.tempChannels || 0}</div>
      </div>
      <div class="stat-card">
        <div class="label">Avg XP per User</div>
        <div class="value">${data.levels ? data.levels.avgXp || 0 : '?'}</div>
      </div>
    </div>
    <h2 style="margin-top:24px;margin-bottom:12px;font-size:18px;">🏆 Leaderboard</h2>
    <div id="dashboard-leaderboard">Loading...</div>
  `;

  const lb = await api('GET', '/api/users/leaderboard');
  if (lb && lb.length) {
    const medals = ['🥇', '🥈', '🥉'];
    document.getElementById('dashboard-leaderboard').innerHTML =
      '<table><tr><th>#</th><th>User</th><th>XP</th><th>Voice Hours</th><th>Streak</th></tr>' +
      lb.slice(0, 10).map((u, i) =>
        `<tr><td>${medals[i] || i+1}</td><td>${u.name || 'Unknown'}</td><td>${u.xp}</td><td>${Math.round((u.total_voice_minutes||0)/60)}h</td><td>${u.streak || 0}d</td></tr>`
      ).join('') + '</table>';
  } else {
    document.getElementById('dashboard-leaderboard').innerHTML = '<p class="text2">No data yet.</p>';
  }
}

let ticketFilterValue = '';

async function loadTickets() {
  const el = document.getElementById('page-tickets');
  const filter = ticketFilterValue;
  const [tickets, stats] = await Promise.all([
    api('GET', `/api/tickets${filter ? '?status=' + filter : ''}`),
    api('GET', '/api/tickets/stats')
  ]);
  if (!tickets) return;

  el.innerHTML = `
    <h1>🆘 Tickets</h1>
    <div class="stats-grid">
      <div class="stat-card"><div class="label">Open</div><div class="value yellow">${stats ? stats.open_count || 0 : 0}</div></div>
      <div class="stat-card"><div class="label">Claimed</div><div class="value yellow">${stats ? stats.claimed_count || 0 : 0}</div></div>
      <div class="stat-card"><div class="label">Active</div><div class="value">${stats ? stats.active_count || 0 : 0}</div></div>
      <div class="stat-card"><div class="label">Closed</div><div class="value green">${stats ? stats.closed_count || 0 : 0}</div></div>
    </div>
    <div class="form-group" style="max-width:300px">
      <select id="ticket-filter">
        <option value="">All Tickets</option>
        <option value="open" ${filter === 'open' ? 'selected' : ''}>Open</option>
        <option value="claimed" ${filter === 'claimed' ? 'selected' : ''}>Claimed</option>
        <option value="closed" ${filter === 'closed' ? 'selected' : ''}>Closed</option>
        <option value="resolved" ${filter === 'resolved' ? 'selected' : ''}>Resolved</option>
      </select>
    </div>
    <div id="ticket-list">
      <table>
        <tr><th>ID</th><th>User</th><th>Subject</th><th>Status</th><th>Staff</th><th>Created</th><th>Action</th></tr>
        ${tickets.map(t => `
          <tr>
            <td>#${t.id}</td>
            <td>${t.creator_name}</td>
            <td>${t.subject || '-'}</td>
            <td><span class="badge ${t.status}">${t.status}</span></td>
            <td>${t.claimed_by_name || '-'}</td>
            <td>${new Date(t.created_at * 1000).toLocaleDateString()}</td>
            <td><button class="btn btn-primary btn-sm" onclick="showTicket(${t.id})">View</button></td>
          </tr>
        `).join('')}
      </table>
    </div>
    <div id="ticket-detail" class="hidden" style="margin-top:20px"></div>
  `;

  document.getElementById('ticket-filter').addEventListener('change', (e) => {
    ticketFilterValue = e.target.value;
    loadTickets();
  });
}

async function showTicket(id) {
  const data = await api('GET', `/api/tickets/${id}`);
  if (!data) return;
  const el = document.getElementById('ticket-detail');
  el.classList.remove('hidden');
  el.innerHTML = `
    <h2>Ticket #${data.id} — ${data.creator_name}</h2>
    <p style="color:#888;font-size:13px;margin-bottom:12px">Subject: ${data.subject || 'N/A'} | Status: <span class="badge ${data.status}">${data.status}</span> | Staff: ${data.claimed_by_name || 'Unclaimed'}</p>
    <div class="ticket-messages">
      ${(data.messages || []).map(m => `
        <div class="ticket-msg ${m.is_staff_note ? 'note' : (m.user_name === data.creator_name ? '' : 'staff')}">
          <div class="meta">${m.user_name} · ${new Date(m.timestamp * 1000).toLocaleString()} ${m.is_staff_note ? '· STAFF NOTE' : ''}</div>
          <div class="text">${m.message}</div>
        </div>
      `).join('') || '<p style="color:#888">No messages</p>'}
    </div>
    <div style="display:flex;gap:8px;flex-wrap:wrap">
      <button class="btn btn-success btn-sm" onclick="claimTicket(${data.id})">Claim</button>
      <button class="btn btn-primary btn-sm" onclick="resolveTicket(${data.id})">Resolve</button>
      <button class="btn btn-danger btn-sm" onclick="closeTicket(${data.id})">Close</button>
    </div>
    <div style="margin-top:12px;display:flex;gap:8px">
      <input type="text" id="reply-input" placeholder="Type a reply..." style="flex:1">
      <button class="btn btn-primary" onclick="replyTicket(${data.id})">Send</button>
    </div>
    <div style="margin-top:8px;display:flex;gap:8px">
      <input type="text" id="note-input" placeholder="Add staff note (invisible to user)..." style="flex:1">
      <button class="btn btn-sm" style="background:#555" onclick="noteTicket(${data.id})">Add Note</button>
    </div>
  `;
  document.getElementById('ticket-list').classList.add('hidden');
}

async function claimTicket(id) { await api('POST', `/api/tickets/${id}/claim`); showTicket(id); }
async function resolveTicket(id) { await api('POST', `/api/tickets/${id}/resolve`); loadTickets(); }
async function closeTicket(id) {
  const reason = prompt('Close reason (optional):');
  await api('POST', `/api/tickets/${id}/close`, { reason: reason || 'Closed via panel' });
  loadTickets();
}
async function replyTicket(id) {
  const msg = document.getElementById('reply-input').value;
  if (!msg) return;
  await api('POST', `/api/tickets/${id}/reply`, { message: msg });
  document.getElementById('reply-input').value = '';
  showTicket(id);
}
async function noteTicket(id) {
  const note = document.getElementById('note-input').value;
  if (!note) return;
  await api('POST', `/api/tickets/${id}/note`, { note });
  document.getElementById('note-input').value = '';
  showTicket(id);
}

async function loadUsers() {
  const el = document.getElementById('page-users');
  el.innerHTML = `
    <h1>👥 Users & Leaderboard</h1>
    <div class="form-group" style="max-width:300px">
      <input type="text" id="user-search" placeholder="Search online users..." onkeyup="searchUsers()">
    </div>
    <div id="user-results"></div>
    <h2 style="margin-top:24px;font-size:18px;">🏆 Top 50 Leaderboard</h2>
    <div id="user-leaderboard">Loading...</div>
  `;
  const lb = await api('GET', '/api/users/leaderboard');
  if (lb) {
    document.getElementById('user-leaderboard').innerHTML =
      '<table><tr><th>#</th><th>Name</th><th>XP</th><th>Voice Hours</th><th>Streak</th><th>Action</th></tr>' +
      lb.map((u, i) => `
        <tr>
          <td>${i+1}</td>
          <td>${u.name || 'Unknown'}</td>
          <td>${u.xp}</td>
          <td>${Math.round((u.total_voice_minutes||0)/60)}h</td>
          <td>${u.streak || 0}d</td>
          <td><button class="btn btn-sm btn-primary" onclick="editXp('${u.client_uid || ''}','${(u.name||'').replace(/'/g,"\\'")}')">Edit XP</button></td>
        </tr>
      `).join('') + '</table>';
  }
}

async function searchUsers() {
  const q = document.getElementById('user-search').value;
  if (q.length < 2) { document.getElementById('user-results').innerHTML = ''; return; }
  const users = await api('GET', `/api/users?search=${encodeURIComponent(q)}`);
  if (users) {
    document.getElementById('user-results').innerHTML =
      '<table><tr><th>Name</th><th>UID</th><th>Channel</th></tr>' +
      users.map(u => `<tr><td>${u.client_nickname}</td><td style="font-size:11px;color:#888">${u.client_unique_identifier}</td><td>${u.cid}</td></tr>`).join('') +
      '</table>';
  }
}

function editXp(uid, name) {
  const amount = prompt(`Set XP for ${name}:`, '100');
  if (amount === null) return;
  api('PUT', '/api/users/xp', { uid, amount: parseInt(amount), action: 'set' }).then(() => loadUsers());
}

async function loadChannels() {
  const el = document.getElementById('page-channels');
  const channels = await api('GET', '/api/channels');
  if (!channels) return;
  function renderTree(items, depth) {
    if (!items || !items.length) return '';
    return items.map(c => {
      const indent = '&nbsp;&nbsp;'.repeat(depth);
      const icon = c.pid == 0 ? '📁' : '🎧';
      const desc = c.channel_topic ? `<span style="color:#666;font-size:12px"> — ${c.channel_topic.substring(0, 60)}</span>` : '';
      return `<div style="padding:6px 0">${indent}${icon} ${c.channel_name}${desc} <span style="color:#555;font-size:11px">(cid:${c.cid})</span></div>` +
        (c.children ? renderTree(c.children, depth + 1) : '');
    }).join('');
  }
  const tree = [];
  const map = {};
  (channels || []).forEach(c => { map[c.cid] = { ...c, children: [] }; });
  (channels || []).forEach(c => {
    if (c.pid == 0) tree.push(map[c.cid]);
    else if (map[c.pid]) map[c.pid].children.push(map[c.cid]);
  });
  el.innerHTML = `<h1>🎧 Channel Tree</h1><div style="background:var(--bg2);border-radius:10px;padding:20px;font-size:14px">${renderTree(tree, 0)}</div>`;
}

async function loadRoles() {
  const el = document.getElementById('page-roles');
  const data = await api('GET', '/api/roles');
  if (!data) return;
  const config = data.config || [];
  el.innerHTML = `
    <h1>🏷️ Roles</h1>
    <table>
      <tr><th>Role</th><th>Color</th><th>XP Required</th><th>Description</th></tr>
      ${config.map(r => `
        <tr>
          <td>${r.icon || ''} ${r.name}</td>
          <td><span style="display:inline-block;width:20px;height:20px;border-radius:4px;background:#${r.hex};vertical-align:middle"></span> #${r.hex}</td>
          <td>${r.xp_required}</td>
          <td style="color:#888;font-size:12px">${r.description || ''}</td>
        </tr>
      `).join('')}
    </table>
    <h2 style="margin-top:24px;font-size:18px;">Current Server Groups</h2>
    <table>
      <tr><th>ID</th><th>Name</th><th>Type</th></tr>
      ${(data.groups || []).map(g => `<tr><td>${g.sgid}</td><td>${g.name || g.sgid}</td><td>${g.type == 0 ? 'Template' : g.type == 1 ? 'Normal' : 'Query'}</td></tr>`).join('')}
    </table>
  `;
}

async function loadBots() {
  const el = document.getElementById('page-bots');
  const bots = ['level', 'temp', 'support'];
  const statuses = await Promise.all(bots.map(b => api('GET', `/api/bots/${b}/status`)));
  const names = { level: 'Level-Up Bot', temp: 'Temp Channel Bot', support: 'Support Bot' };
  const icons = { level: '📈', temp: '⏳', support: '🆘' };
  el.innerHTML = `
    <h1>🤖 Bot Management</h1>
    <div class="stats-grid">
      ${bots.map((b, i) => `
        <div class="stat-card">
          <div class="label">${icons[b]} ${names[b]}</div>
          <div class="value ${statuses[i] && statuses[i].status === 'running' ? 'green' : 'red'}">
            ${statuses[i] ? statuses[i].status : 'unknown'}
          </div>
          <div style="margin-top:12px;display:flex;gap:4px">
            <button class="btn btn-sm btn-primary" onclick="botAction('${b}','restart')">Restart</button>
            <button class="btn btn-sm btn-success" onclick="botAction('${b}','on')">Start</button>
            <button class="btn btn-sm btn-danger" onclick="botAction('${b}','off')">Stop</button>
          </div>
        </div>
      `).join('')}
    </div>
  `;
}

async function botAction(name, action) {
  await api('POST', `/api/bots/${name}/${action}`);
  loadBots();
}

async function loadSettings() {
  const el = document.getElementById('page-settings');
  const settings = await api('GET', '/api/settings');
  el.innerHTML = `
    <h1>⚙️ Server Settings</h1>
    <div class="stats-grid">
      <div class="stat-card"><div class="label">Server Name</div><div class="value" style="font-size:16px">${settings && settings.virtualserver_name || 'N/A'}</div></div>
      <div class="stat-card"><div class="label">Slots</div><div class="value">${settings ? `${settings.virtualserver_clientsonline || 0}/${settings.virtualserver_maxclients || '?'}` : 'N/A'}</div></div>
      <div class="stat-card"><div class="label">Uptime</div><div class="value">${settings ? Math.floor((settings.virtualserver_uptime || 0) / 3600) + 'h' : 'N/A'}</div></div>
      <div class="stat-card"><div class="label">Voice Port</div><div class="value">${settings && settings.virtualserver_port || 'N/A'}</div></div>
    </div>
    <div style="margin-top:16px;display:flex;gap:8px">
      <button class="btn btn-primary" onclick="renewSsl()">Renew SSL</button>
    </div>
  `;
}

async function renewSsl() {
  const res = await api('POST', '/api/ssl/renew');
  alert(res && res.success ? 'SSL renewed successfully' : 'SSL renewal failed');
}

async function loadBackup() {
  const el = document.getElementById('page-backup');
  const backups = await api('GET', '/api/backups');
  el.innerHTML = `
    <h1>📦 Backup</h1>
    <button class="btn btn-primary" onclick="createBackup()" style="margin-bottom:16px">Create Backup Now</button>
    <div id="backup-status"></div>
    <h2 style="font-size:18px;margin-bottom:12px">Existing Backups</h2>
    <table>
      <tr><th>Name</th><th>Size</th><th>Date</th></tr>
      ${(backups || []).map(b => `<tr><td>${b.name}</td><td>${(b.size / 1024 / 1024).toFixed(2)} MB</td><td>${new Date(b.date).toLocaleString()}</td></tr>`).join('') || '<tr><td colspan="3" style="color:#888">No backups yet.</td></tr>'}
    </table>
  `;
}

async function createBackup() {
  const res = await api('POST', '/api/backup');
  document.getElementById('backup-status').innerHTML =
    `<p style="color:${res && res.success ? '#2ECC71' : '#E74C3C'}">${res && res.success ? 'Backup created: ' + res.filename : 'Backup failed'}</p>`;
  loadBackup();
}

async function loadLogs() {
  const el = document.getElementById('page-logs');
  const logs = await api('GET', '/api/logs');
  el.innerHTML = `
    <h1>📝 Logs</h1>
    ${(logs || []).map(l => `
      <div style="background:var(--bg2);border-radius:10px;padding:16px;margin-bottom:12px">
        <h3 style="font-size:14px;margin-bottom:8px;color:#888">${l.file}</h3>
        <pre style="font-size:12px;color:#aaa;overflow-x:auto;white-space:pre-wrap">${l.content || 'Empty'}</pre>
      </div>
    `).join('') || '<p>No logs available.</p>'}
  `;
}
