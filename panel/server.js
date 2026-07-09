const express = require('express');
const http = require('http');
const socketIo = require('socket.io');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcrypt');
const helmet = require('helmet');
const path = require('path');
const fs = require('fs');
const { TS6Client } = require('../shared/ts6-rest');
const { TicketDB } = require('../shared/ticket-db');

const JWT_SECRET = process.env.PANEL_JWT_SECRET;
const JWT_REFRESH_SECRET = process.env.PANEL_REFRESH_SECRET;
const PORT = parseInt(process.env.PANEL_PORT || '3000');
const BIND_ADDR = process.env.PANEL_BIND || '127.0.0.1';

if (!JWT_SECRET || JWT_SECRET === 'change-me-in-env') {
  console.error('[Panel] PANEL_JWT_SECRET not set in .env');
  process.exit(1);
}

const ts6 = new TS6Client({
  baseUrl: process.env.TS6_BASE_URL || 'http://127.0.0.1:10080',
  apiKey: process.env.TS6_API_KEY || ''
});

const ticketDb = new TicketDB(path.join(__dirname, '..', 'bots', 'support-bot', 'tickets.sqlite'));

function loadAdmins() {
  const envPath = path.join(__dirname, '..', '.env');
  try {
    const data = fs.readFileSync(envPath, 'utf8');
    const vars = {};
    data.split('\n').forEach(line => {
      const m = line.match(/^([A-Z_]+)=(.*)$/);
      if (m) vars[m[1]] = m[2];
    });
    if (vars.PANEL_ADMIN_USER && vars.PANEL_ADMIN_HASH) {
      return [{ username: vars.PANEL_ADMIN_USER, passwordHash: vars.PANEL_ADMIN_HASH }];
    }
  } catch {}
  return [{ username: 'admin', passwordHash: bcrypt.hashSync('teamtp', 10) }];
}

let ADMINS = loadAdmins();

const app = express();
const server = http.createServer(app);
const io = socketIo(server, { cors: { origin: true, credentials: true } });

app.set('trust proxy', 1);
app.use(helmet({ contentSecurityPolicy: false, crossOriginEmbedderPolicy: false }));
app.use(express.json({ limit: '1mb' }));
app.use(express.static(path.join(__dirname, 'public'), { maxAge: '1h' }));

const loginAttempts = new Map();
setInterval(() => loginAttempts.clear(), 600000);

function loginRateLimit(req, res, next) {
  const ip = req.ip || req.connection.remoteAddress;
  const now = Date.now();
  if (!loginAttempts.has(ip)) loginAttempts.set(ip, []);
  const attempts = loginAttempts.get(ip).filter(t => now - t < 60000);
  loginAttempts.set(ip, attempts);
  if (attempts.length >= 5) {
    return res.status(429).json({ error: 'Too many attempts. Wait 1 minute.' });
  }
  attempts.push(now);
  next();
}

function authenticateToken(req, res, next) {
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'No token' });
  jwt.verify(token, JWT_SECRET, (err, user) => {
    if (err) return res.status(403).json({ error: 'Token expired' });
    req.user = user;
    next();
  });
}

function adminOnly(req, res, next) {
  if (req.user && req.user.role === 'admin') return next();
  res.status(403).json({ error: 'Admin only' });
}

app.post('/api/auth/login', loginRateLimit, async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) return res.status(400).json({ error: 'Username and password required' });
  const admin = ADMINS.find(a => a.username === username);
  if (!admin) return res.status(401).json({ error: 'Invalid credentials' });
  try {
    const valid = await bcrypt.compare(password, admin.passwordHash);
    if (!valid) return res.status(401).json({ error: 'Invalid credentials' });
  } catch {
    return res.status(500).json({ error: 'Auth error' });
  }
  const token = jwt.sign({ username, role: 'admin' }, JWT_SECRET, { expiresIn: '15m' });
  const refreshToken = jwt.sign({ username, role: 'admin' }, JWT_REFRESH_SECRET, { expiresIn: '7d' });
  res.json({ token, refreshToken, user: username });
});

app.post('/api/auth/refresh', (req, res) => {
  const { refreshToken } = req.body;
  if (!refreshToken) return res.status(401).json({ error: 'No refresh token' });
  jwt.verify(refreshToken, JWT_REFRESH_SECRET, (err, user) => {
    if (err) return res.status(403).json({ error: 'Refresh expired' });
    const token = jwt.sign({ username: user.username, role: 'admin' }, JWT_SECRET, { expiresIn: '15m' });
    res.json({ token });
  });
});

app.get('/api/dashboard/stats', authenticateToken, async (req, res) => {
  try {
    const health = await ts6.health();
    let serverInfo = null;
    let clientCount = 0;
    if (health) {
      try {
        serverInfo = await ts6.getServerInfo();
        const clients = await ts6.getClients();
        clientCount = clients ? clients.filter(c => parseInt(c.client_type) === 0).length : 0;
      } catch {}
    }
    const ticketStats = ticketDb.getTicketStats();
    const lbPath = path.join(__dirname, '..', 'bots', 'level-bot', 'data.sqlite');
    let levelStats = { totalUsers: 0, totalXp: 0, avgXp: 0, totalVoiceHours: 0 };
    try {
      if (fs.existsSync(lbPath)) {
        const ldb = require('better-sqlite3')(lbPath);
        levelStats = {
          totalUsers: ldb.prepare('SELECT COUNT(*) as c FROM users').get().c,
          totalXp: ldb.prepare('SELECT COALESCE(SUM(xp), 0) as s FROM users').get().s,
          avgXp: ldb.prepare('SELECT COALESCE(ROUND(AVG(xp)), 0) as a FROM users').get().a,
          totalVoiceHours: Math.round((ldb.prepare('SELECT COALESCE(SUM(total_voice_minutes), 0) as s FROM users').get().s || 0) / 60)
        };
        ldb.close();
      }
    } catch {}
    const tempDbPath = path.join(__dirname, '..', 'bots', 'temp-channel-bot', 'temp-channels.sqlite');
    let activeTempChannels = 0;
    try {
      if (fs.existsSync(tempDbPath)) {
        const tdb = require('better-sqlite3')(tempDbPath);
        activeTempChannels = tdb.prepare('SELECT COUNT(*) as c FROM temp_channels WHERE deleted = 0').get().c;
        tdb.close();
      }
    } catch {}
    res.json({ server: { online: health, onlineClients: clientCount }, tickets: ticketStats, levels: levelStats, tempChannels: activeTempChannels });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/tickets', authenticateToken, (req, res) => {
  const status = req.query.status || null;
  res.json(ticketDb.listTickets(status));
});

app.get('/api/tickets/stats', authenticateToken, (req, res) => {
  res.json(ticketDb.getTicketStats());
});

app.get('/api/tickets/:id', authenticateToken, (req, res) => {
  const ticket = ticketDb.getTicket(parseInt(req.params.id));
  if (!ticket) return res.status(404).json({ error: 'Not found' });
  res.json({ ...ticket, messages: ticketDb.getMessages(ticket.id) });
});

app.post('/api/tickets/:id/claim', authenticateToken, async (req, res) => {
  const ticket = ticketDb.getTicket(parseInt(req.params.id));
  if (!ticket) return res.status(404).json({ error: 'Not found' });
  ticketDb.claimTicket(ticket.id, 0, req.user.username);
  io.emit('ticket:update', { id: ticket.id, status: 'claimed', claimed_by_name: req.user.username });
  res.json({ success: true });
});

app.post('/api/tickets/:id/close', authenticateToken, async (req, res) => {
  const ticket = ticketDb.getTicket(parseInt(req.params.id));
  if (!ticket) return res.status(404).json({ error: 'Not found' });
  ticketDb.closeTicket(ticket.id, 0, (req.body && req.body.reason) || 'Closed via panel');
  io.emit('ticket:update', { id: ticket.id, status: 'closed' });
  res.json({ success: true });
});

app.post('/api/tickets/:id/resolve', authenticateToken, async (req, res) => {
  const ticket = ticketDb.getTicket(parseInt(req.params.id));
  if (!ticket) return res.status(404).json({ error: 'Not found' });
  ticketDb.resolveTicket(ticket.id, 0);
  ticketDb.closeTicket(ticket.id, 0, 'Resolved');
  io.emit('ticket:update', { id: ticket.id, status: 'resolved' });
  res.json({ success: true });
});

app.post('/api/tickets/:id/note', authenticateToken, (req, res) => {
  const ticket = ticketDb.getTicket(parseInt(req.params.id));
  if (!ticket) return res.status(404).json({ error: 'Not found' });
  ticketDb.addMessage(ticket.id, 0, 'panel', req.user.username, `[NOTE] ${(req.body && req.body.note) || ''}`, true);
  res.json({ success: true });
});

app.post('/api/tickets/:id/reply', authenticateToken, (req, res) => {
  const ticket = ticketDb.getTicket(parseInt(req.params.id));
  if (!ticket) return res.status(404).json({ error: 'Not found' });
  if (!req.body || !req.body.message) return res.status(400).json({ error: 'Message required' });
  ticketDb.addMessage(ticket.id, 0, 'panel', req.user.username, req.body.message, false);
  io.emit('ticket:message', { id: ticket.id, user: req.user.username });
  res.json({ success: true });
});

app.get('/api/tickets/:id/transcript', authenticateToken, (req, res) => {
  const ticket = ticketDb.getTicket(parseInt(req.params.id));
  if (!ticket) return res.status(404).json({ error: 'Not found' });
  if (ticket.transcript_path && fs.existsSync(ticket.transcript_path)) {
    return res.download(ticket.transcript_path);
  }
  res.status(404).json({ error: 'No transcript' });
});

app.get('/api/users', authenticateToken, async (req, res) => {
  try {
    const clients = await ts6.getClients();
    const search = req.query.search ? req.query.search.toLowerCase() : '';
    const filtered = (clients || []).filter(c =>
      parseInt(c.client_type) === 0 && c.client_nickname && c.client_nickname.toLowerCase().includes(search)
    );
    res.json(filtered.slice(0, 50));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/users/leaderboard', authenticateToken, (req, res) => {
  const lbPath = path.join(__dirname, '..', 'bots', 'level-bot', 'data.sqlite');
  try {
    if (fs.existsSync(lbPath)) {
      const ldb = require('better-sqlite3')(lbPath);
      const users = ldb.prepare('SELECT client_uid, name, xp, total_voice_minutes, streak FROM users ORDER BY xp DESC LIMIT 50').all();
      ldb.close();
      return res.json(users);
    }
    res.json([]);
  } catch { res.json([]); }
});

app.put('/api/users/xp', authenticateToken, adminOnly, async (req, res) => {
  const { uid, amount, action } = req.body;
  if (!uid || amount === undefined) return res.status(400).json({ error: 'uid and amount required' });
  const lbPath = path.join(__dirname, '..', 'bots', 'level-bot', 'data.sqlite');
  try {
    const ldb = require('better-sqlite3')(lbPath);
    const user = ldb.prepare('SELECT * FROM users WHERE client_uid = ?').get(uid);
    if (!user) return res.status(404).json({ error: 'User not found' });
    if (action === 'set') {
      ldb.prepare('UPDATE users SET xp = ? WHERE client_uid = ?').run(amount, uid);
    } else {
      ldb.prepare('UPDATE users SET xp = xp + ? WHERE client_uid = ?').run(amount, uid);
    }
    const updated = ldb.prepare('SELECT * FROM users WHERE client_uid = ?').get(uid);
    ldb.close();
    res.json(updated);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/channels', authenticateToken, async (req, res) => {
  try { res.json((await ts6.getChannels()) || []); }
  catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/roles', authenticateToken, async (req, res) => {
  try {
    const groups = await ts6.getServerGroups();
    let roleConfig = [];
    try {
      roleConfig = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'config', 'roles.json'), 'utf8'));
    } catch {}
    res.json({ groups: groups || [], config: roleConfig });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.post('/api/bots/:name/:action', authenticateToken, adminOnly, async (req, res) => {
  const { name, action } = req.params;
  if (!['level', 'temp', 'support'].includes(name)) return res.status(400).json({ error: 'Invalid bot' });
  if (!['status', 'restart', 'start', 'stop'].includes(action)) return res.status(400).json({ error: 'Invalid action' });
  try {
    const exec = require('child_process').execSync;
    if (action === 'status') {
      const out = exec(`systemctl is-active teamtp-${name}-bot 2>/dev/null || echo inactive`, { encoding: 'utf8' }).trim();
      return res.json({ status: out === 'active' ? 'running' : 'stopped' });
    }
    exec(`systemctl ${action === 'start' ? 'start' : action === 'stop' ? 'stop' : 'restart'} teamtp-${name}-bot`, { encoding: 'utf8' });
    res.json({ status: action === 'start' ? 'started' : action === 'stop' ? 'stopped' : 'restarted' });
  } catch { res.json({ status: 'error' }); }
});

app.post('/api/ssl/renew', authenticateToken, adminOnly, (req, res) => {
  try {
    require('child_process').execSync('certbot renew 2>&1', { encoding: 'utf8' });
    res.json({ success: true });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.post('/api/backup', authenticateToken, adminOnly, (req, res) => {
  const backupDir = path.join(__dirname, '..', 'backups');
  fs.mkdirSync(backupDir, { recursive: true });
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const filename = `teamtp-${ts}.tar.gz`;
  try {
    require('child_process').execSync(
      `tar -czf ${path.join(backupDir, filename)} -C ${path.join(__dirname, '..')} .env config/ ${['bots/level-bot/data.sqlite', 'bots/temp-channel-bot/temp-channels.sqlite', 'bots/support-bot/tickets.sqlite'].filter(f => fs.existsSync(path.join(__dirname, '..', f))).join(' ')}`,
      { encoding: 'utf8', timeout: 30000 }
    );
    res.json({ success: true, filename });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/backups', authenticateToken, adminOnly, (req, res) => {
  const backupDir = path.join(__dirname, '..', 'backups');
  try {
    if (!fs.existsSync(backupDir)) return res.json([]);
    const files = fs.readdirSync(backupDir).filter(f => f.endsWith('.tar.gz')).map(f => {
      const stat = fs.statSync(path.join(backupDir, f));
      return { name: f, size: stat.size, date: stat.mtime };
    });
    res.json(files);
  } catch { res.json([]); }
});

app.get('/api/faq', authenticateToken, (req, res) => {
  res.json(ticketDb.listFAQ(req.query.category || null));
});

app.post('/api/faq', authenticateToken, adminOnly, (req, res) => {
  if (!req.body || !req.body.question || !req.body.answer) return res.status(400).json({ error: 'question and answer required' });
  const id = ticketDb.addFAQ((req.body.keywords || ''), req.body.question, req.body.answer, req.body.category || 'general');
  res.json({ id });
});

app.delete('/api/faq/:id', authenticateToken, adminOnly, (req, res) => {
  ticketDb.removeFAQ(parseInt(req.params.id));
  res.json({ success: true });
});

app.get('/api/logs', authenticateToken, adminOnly, (req, res) => {
  const logFiles = ['/var/log/teamtp-install.log', '/var/log/teamtp/panel.log'];
  const results = [];
  for (const f of logFiles) {
    try {
      if (fs.existsSync(f)) {
        const content = fs.readFileSync(f, 'utf8');
        results.push({ file: path.basename(f), content: content.split('\n').slice(-100).join('\n') });
      }
    } catch {}
  }
  res.json(results);
});

app.get('/api/settings', authenticateToken, async (req, res) => {
  try { res.json((await ts6.getServerInfo()) || {}); }
  catch { res.json({}); }
});

io.on('connection', (socket) => {
  socket.on('disconnect', () => {});
});

app.get('*', (req, res) => {
  if (req.path.startsWith('/api')) return res.status(404).json({ error: 'Not found' });
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

server.listen(PORT, BIND_ADDR, () => {
  console.log(`[Panel] Web panel on http://${BIND_ADDR}:${PORT}`);
});
