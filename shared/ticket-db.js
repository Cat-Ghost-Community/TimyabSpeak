const Database = require('better-sqlite3');
const path = require('path');

class TicketDB {
  constructor(dbPath) {
    this.db = new Database(dbPath || path.join(__dirname, '..', 'bots', 'support-bot', 'tickets.sqlite'));
    this.db.pragma('journal_mode = WAL');
    this.db.pragma('busy_timeout = 5000');
    this._init();
  }

  _init() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS tickets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_id INTEGER NOT NULL UNIQUE,
        creator_id INTEGER NOT NULL,
        creator_uid TEXT NOT NULL,
        creator_name TEXT NOT NULL DEFAULT '',
        subject TEXT DEFAULT '',
        status TEXT NOT NULL DEFAULT 'open',
        claimed_by INTEGER,
        claimed_by_name TEXT DEFAULT '',
        claimed_at INTEGER,
        created_at INTEGER NOT NULL,
        closed_at INTEGER,
        closed_by INTEGER,
        close_reason TEXT,
        transcript_path TEXT
      );
      CREATE TABLE IF NOT EXISTS ticket_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ticket_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        user_uid TEXT NOT NULL,
        user_name TEXT NOT NULL,
        message TEXT NOT NULL,
        is_staff_note INTEGER DEFAULT 0,
        timestamp INTEGER NOT NULL,
        FOREIGN KEY (ticket_id) REFERENCES tickets(id)
      );
      CREATE TABLE IF NOT EXISTS ticket_blocklist (
        user_id INTEGER PRIMARY KEY,
        user_uid TEXT NOT NULL,
        reason TEXT,
        blocked_by INTEGER,
        blocked_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS faq (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        keywords TEXT NOT NULL DEFAULT '',
        question TEXT NOT NULL,
        answer TEXT NOT NULL,
        category TEXT DEFAULT 'general',
        created_at INTEGER
      );
      CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status);
      CREATE INDEX IF NOT EXISTS idx_tickets_creator ON tickets(creator_id);
      CREATE INDEX IF NOT EXISTS idx_messages_ticket ON ticket_messages(ticket_id);
    `);
  }

  createTicket(channelId, creatorId, creatorUid, creatorName, subject) {
    const stmt = this.db.prepare(`
      INSERT INTO tickets (channel_id, creator_id, creator_uid, creator_name, subject, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `);
    const now = Math.floor(Date.now() / 1000);
    const result = stmt.run(channelId, creatorId, creatorUid, creatorName, subject, now);
    return result.lastInsertRowid;
  }

  getTicket(ticketId) {
    return this.db.prepare('SELECT * FROM tickets WHERE id = ?').get(ticketId);
  }

  getTicketByChannel(channelId) {
    return this.db.prepare('SELECT * FROM tickets WHERE channel_id = ?').get(channelId);
  }

  listTickets(status) {
    if (status) {
      return this.db.prepare('SELECT * FROM tickets WHERE status = ? ORDER BY created_at DESC').all(status);
    }
    return this.db.prepare('SELECT * FROM tickets ORDER BY created_at DESC').all();
  }

  claimTicket(ticketId, staffId, staffName) {
    const now = Math.floor(Date.now() / 1000);
    this.db.prepare(`
      UPDATE tickets SET status = 'claimed', claimed_by = ?, claimed_by_name = ?, claimed_at = ?
      WHERE id = ? AND status = 'open'
    `).run(staffId, staffName, now, ticketId);
  }

  closeTicket(ticketId, closedBy, reason) {
    const now = Math.floor(Date.now() / 1000);
    this.db.prepare(`
      UPDATE tickets SET status = 'closed', closed_at = ?, closed_by = ?, close_reason = ?
      WHERE id = ?
    `).run(now, closedBy, reason || '', ticketId);
  }

  resolveTicket(ticketId, closedBy) {
    const now = Math.floor(Date.now() / 1000);
    this.db.prepare(`
      UPDATE tickets SET status = 'resolved', closed_at = ?, closed_by = ?
      WHERE id = ?
    `).run(now, closedBy, ticketId);
  }

  addMessage(ticketId, userId, userUid, userName, message, isStaffNote) {
    const now = Math.floor(Date.now() / 1000);
    this.db.prepare(`
      INSERT INTO ticket_messages (ticket_id, user_id, user_uid, user_name, message, is_staff_note, timestamp)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).run(ticketId, userId, userUid, userName, message, isStaffNote ? 1 : 0, now);
  }

  getMessages(ticketId) {
    return this.db.prepare('SELECT * FROM ticket_messages WHERE ticket_id = ? ORDER BY timestamp ASC').all(ticketId);
  }

  userHasOpenTicket(userId) {
    const ticket = this.db.prepare(`
      SELECT id FROM tickets WHERE creator_id = ? AND status IN ('open', 'claimed') LIMIT 1
    `).get(userId);
    return !!ticket;
  }

  getUserOpenTickets(userId) {
    return this.db.prepare(`
      SELECT * FROM tickets WHERE creator_id = ? AND status IN ('open', 'claimed')
      ORDER BY created_at DESC
    `).all(userId);
  }

  getTicketStats() {
    const stats = this.db.prepare(`
      SELECT
        COUNT(CASE WHEN status = 'open' THEN 1 END) as open_count,
        COUNT(CASE WHEN status = 'claimed' THEN 1 END) as claimed_count,
        COUNT(CASE WHEN status IN ('open', 'claimed') THEN 1 END) as active_count,
        COUNT(CASE WHEN status IN ('closed', 'resolved') THEN 1 END) as closed_count,
        ROUND(AVG(CASE WHEN status IN ('closed', 'resolved') THEN (closed_at - created_at) END)) as avg_resolve_seconds
      FROM tickets
    `).get();
    return stats;
  }

  isBlocked(userId) {
    const block = this.db.prepare('SELECT * FROM ticket_blocklist WHERE user_id = ?').get(userId);
    return !!block;
  }

  blockUser(userId, userUid, reason, blockedBy) {
    const now = Math.floor(Date.now() / 1000);
    this.db.prepare(`
      INSERT OR REPLACE INTO ticket_blocklist (user_id, user_uid, reason, blocked_by, blocked_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(userId, userUid, reason, blockedBy, now);
  }

  unblockUser(userId) {
    this.db.prepare('DELETE FROM ticket_blocklist WHERE user_id = ?').run(userId);
  }

  getBlockList() {
    return this.db.prepare('SELECT * FROM ticket_blocklist').all();
  }

  listFAQ(category) {
    if (category) {
      return this.db.prepare('SELECT * FROM faq WHERE category = ? ORDER BY id').all(category);
    }
    return this.db.prepare('SELECT * FROM faq ORDER BY id').all();
  }

  searchFAQ(query) {
    const q = `%${query.toLowerCase()}%`;
    return this.db.prepare(`
      SELECT * FROM faq WHERE LOWER(question) LIKE ? OR LOWER(keywords) LIKE ? OR LOWER(answer) LIKE ?
      ORDER BY id LIMIT 5
    `).all(q, q, q);
  }

  addFAQ(keywords, question, answer, category) {
    const now = Math.floor(Date.now() / 1000);
    return this.db.prepare(`
      INSERT INTO faq (keywords, question, answer, category, created_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(keywords, question, answer, category || 'general', now).lastInsertRowid;
  }

  removeFAQ(id) {
    this.db.prepare('DELETE FROM faq WHERE id = ?').run(id);
  }

  setTranscriptPath(ticketId, filePath) {
    this.db.prepare('UPDATE tickets SET transcript_path = ? WHERE id = ?').run(filePath, ticketId);
  }

  close() {
    this.db.close();
  }
}

module.exports = { TicketDB };
