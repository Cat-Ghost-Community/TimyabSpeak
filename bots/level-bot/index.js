const { TS3Client } = require('../../shared/ts3-query');
const Database = require('better-sqlite3');
const path = require('path');

const XP_CONFIG = {
  voicePer10Min: 10,
  hourlyBonus: 20,
  firstJoinDaily: 15,
  streak3Day: 25,
  streak7Day: 50,
  createChannel: 10,
  inviteAccepted: 50,
  weeklyChallenge: 100,
  pollIntervalMs: 60000,
  maxVoiceClients: 500
};

const ROLE_THRESHOLDS = [
  { minXp: 0,    role: 'Guest' },
  { minXp: 100,  role: 'Member' },
  { minXp: 500,  role: 'Veteran' },
  { minXp: 1000, role: 'Elite' }
];

const ROLE_GROUP_NAMES = ['Guest', 'Member', 'Veteran', 'Elite'];

class LevelBot {
  constructor() {
    this.ts3 = new TS3Client({
      host: process.env.TS3_QUERY_HOST || '127.0.0.1',
      port: parseInt(process.env.TS3_QUERY_PORT || '10011'),
      password: process.env.TS3_QUERY_PASSWORD || ''
    });
    this.db = new Database(path.join(__dirname, 'data.sqlite'));
    this.db.pragma('journal_mode = WAL');
    this._initDb();
    this._voiceSessions = new Map();
    this._pollTimer = null;
    this._serverGroupCache = null;
  }

  _initDb() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cldbid INTEGER NOT NULL UNIQUE,
        client_uid TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        xp INTEGER DEFAULT 0,
        total_voice_minutes INTEGER DEFAULT 0,
        sessions INTEGER DEFAULT 0,
        last_seen INTEGER,
        join_date INTEGER,
        streak INTEGER DEFAULT 0,
        last_streak_date TEXT
      );
      CREATE TABLE IF NOT EXISTS xp_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        amount INTEGER NOT NULL,
        source TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id)
      );
      CREATE TABLE IF NOT EXISTS achievements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        achievement_id TEXT NOT NULL,
        unlocked_at INTEGER NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id)
      );
      CREATE INDEX IF NOT EXISTS idx_users_uid ON users(client_uid);
      CREATE INDEX IF NOT EXISTS idx_xp_log_user ON xp_log(user_id);
      CREATE INDEX IF NOT EXISTS idx_achievements_user ON achievements(user_id);
    `);
  }

  async start() {
    console.log('[LevelBot] Starting...');
    await this._syncServerGroups();
    this._pollTimer = setInterval(() => this._tick(), XP_CONFIG.pollIntervalMs);
    await this._tick();
    console.log('[LevelBot] Running.');
  }

  stop() {
    if (this._pollTimer) clearInterval(this._pollTimer);
    this.db.close();
  }

  async _syncServerGroups() {
    try {
      const groups = await this.ts3.getServerGroups();
      this._serverGroupCache = groups;
    } catch (err) {
      console.error('[LevelBot] Server group sync error:', err.message);
    }
  }

  getGroupByName(name) {
    if (!this._serverGroupCache) return null;
    return this._serverGroupCache.find(g =>
      g.name.toLowerCase() === name.toLowerCase() ||
      g.name.includes(name)
    );
  }

  async _tick() {
    try {
      const clients = await this.ts3.getClients();
      const voiceClients = clients.filter(c => c.client_type === 0 && c.cid > 0);
      const now = Math.floor(Date.now() / 1000);

      for (const client of voiceClients.slice(0, XP_CONFIG.maxVoiceClients)) {
        let user = this.db.prepare('SELECT * FROM users WHERE client_uid = ?').get(client.client_unique_identifier);
        if (!user) {
          this.db.prepare(`
            INSERT INTO users (cldbid, client_uid, name, xp, join_date, last_seen)
            VALUES (?, ?, ?, 0, ?, ?)
          `).run(client.cldbid, client.client_unique_identifier, client.client_nickname, now, now);
          user = this.db.prepare('SELECT * FROM users WHERE client_uid = ?').get(client.client_unique_identifier);
          await this._handleFirstJoin(client, user);
        }

          if (user.name !== client.client_nickname) {
            this.db.prepare('UPDATE users SET name = ? WHERE id = ?').run(client.client_nickname, user.id);
          }

          await this._checkStreak(user);

          const sessionKey = client.client_unique_identifier;
          if (this._voiceSessions.has(sessionKey)) {
          const session = this._voiceSessions.get(sessionKey);
          const elapsed = now - session.lastTick;
          if (elapsed >= 600) {
            const xpGained = XP_CONFIG.voicePer10Min * Math.floor(elapsed / 600);
            const bonusHours = Math.floor(elapsed / 3600);
            let totalXp = xpGained;

            if (bonusHours > session.lastHourBonus) {
              const newBonuses = bonusHours - session.lastHourBonus;
              totalXp += newBonuses * XP_CONFIG.hourlyBonus;
              session.lastHourBonus = bonusHours;
            }

            if (totalXp > 0) {
              await this._addXp(user.id, totalXp, 'voice');
              user.xp += totalXp;
            }

            session.lastTick = now;
            const minutes = Math.floor(elapsed / 60);
            this.db.prepare('UPDATE users SET total_voice_minutes = total_voice_minutes + ?, last_seen = ? WHERE id = ?')
              .run(minutes, now, user.id);
          }
        } else {
          this._voiceSessions.set(sessionKey, {
            clid: client.clid,
            cldbid: client.cldbid,
            startTime: now,
            lastTick: now,
            lastHourBonus: 0
          });
          try {
            const channelClients = await this.ts3.getChannelClients(client.cid);
            const count = channelClients.length;
            if (count >= 5) {
              const achievements = this.db.prepare('SELECT achievement_id FROM achievements WHERE user_id = ?').all(user.id).map(a => a.achievement_id);
              if (!achievements.includes('party_starter')) {
                await this._unlockAchievement(user.id, 'party_starter');
              }
            }
          } catch {}
          this.db.prepare('UPDATE users SET last_seen = ? WHERE id = ?').run(now, user.id);
        }

        await this._checkRoleUpgrade(client, user);
        await this._checkVoiceAchievements(client, user, now);
      }

      for (const [uid, session] of this._voiceSessions) {
        if (!voiceClients.some(c => c.client_unique_identifier === uid)) {
          this._voiceSessions.delete(uid);
        }
      }

      await this._updateLeaderboardChannel();
    } catch (err) {
      console.error('[LevelBot] Tick error:', err.message);
    }
  }

  async _handleFirstJoin(client, user) {
    const now = Math.floor(Date.now() / 1000);
    const today = new Date().toISOString().split('T')[0];

    this.db.prepare(`
      UPDATE users SET last_seen = ?, streak = 1, last_streak_date = ?, sessions = sessions + 1
      WHERE id = ?
    `).run(now, today, user.id);

    await this._addXp(user.id, XP_CONFIG.firstJoinDaily, 'first_join');

    const achievements = this.db.prepare('SELECT achievement_id FROM achievements WHERE user_id = ?').all(user.id).map(a => a.achievement_id);
    if (!achievements.includes('first_words')) {
      await this._unlockAchievement(user.id, 'first_words');
    }
  }

  async _checkStreak(user) {
    const today = new Date().toISOString().split('T')[0];
    if (user.last_streak_date === today) return;

    const yesterday = new Date(Date.now() - 86400000).toISOString().split('T')[0];
    let newStreak = 1;

    if (user.last_streak_date === yesterday) {
      newStreak = user.streak + 1;
    }

    this.db.prepare('UPDATE users SET streak = ?, last_streak_date = ? WHERE id = ?')
      .run(newStreak, today, user.id);

    if (newStreak >= 7) {
      await this._addXp(user.id, XP_CONFIG.streak7Day, 'streak_7day');
      const achievements = this.db.prepare('SELECT achievement_id FROM achievements WHERE user_id = ?').all(user.id).map(a => a.achievement_id);
      if (!achievements.includes('comeback_kid')) {
        await this._unlockAchievement(user.id, 'comeback_kid');
      }
    } else if (newStreak >= 3) {
      await this._addXp(user.id, XP_CONFIG.streak3Day, 'streak_3day');
    }

    await this._addXp(user.id, XP_CONFIG.firstJoinDaily, 'first_join');
  }

  async _addXp(userId, amount, source) {
    const now = Math.floor(Date.now() / 1000);
    this.db.prepare('UPDATE users SET xp = xp + ? WHERE id = ?').run(amount, userId);
    this.db.prepare('INSERT INTO xp_log (user_id, amount, source, timestamp) VALUES (?, ?, ?, ?)')
      .run(userId, amount, source, now);
  }

  async _checkRoleUpgrade(client, user) {
    const currentRole = this._getCurrentRole(user.xp);
    let targetRole = this.getGroupByName(currentRole.role);
    if (!targetRole) return;

    const userGroups = await this.ts3.getServerGroups();
    const groupList = Array.isArray(userGroups) ? userGroups : [];
    const hasRole = groupList.some(g => g.sgid == targetRole.sgid && g.cldbid == client.cldbid);

    if (!hasRole) {
      for (const rn of ROLE_GROUP_NAMES) {
        const rg = this.getGroupByName(rn);
        if (rg) {
          try { await this.ts3.removeClientFromServerGroup(rg.sgid, client.cldbid); } catch {}
        }
      }
      await this.ts3.addClientToServerGroup(targetRole.sgid, client.cldbid);
      console.log(`[LevelBot] ${client.client_nickname} → ${currentRole.role}`);

      if (currentRole.role === 'Veteran') {
        const achievements = this.db.prepare('SELECT achievement_id FROM achievements WHERE user_id = ?').all(user.id).map(a => a.achievement_id);
        if (!achievements.includes('veteran')) {
          await this._unlockAchievement(user.id, 'veteran');
        }
      }

      const channel = await this._findChannel('🏆 Leaderboard');
      if (channel) {
        await this.ts3.sendChannelMessage(channel.cid,
          `🎉 ${client.client_nickname} reached ${currentRole.role}! [${user.xp} XP]`
        );
      }
    }
  }

  _getCurrentRole(xp) {
    let role = ROLE_THRESHOLDS[0];
    for (const r of ROLE_THRESHOLDS) {
      if (xp >= r.minXp) role = r;
    }
    return role;
  }

  async _checkVoiceAchievements(client, user, now) {
    const achievements = this.db.prepare('SELECT achievement_id FROM achievements WHERE user_id = ?').all(user.id).map(a => a.achievement_id);
    const totalMin = this.db.prepare('SELECT total_voice_minutes FROM users WHERE id = ?').get(user.id).total_voice_minutes;

    if (totalMin >= 120 && !achievements.includes('night_owl')) {
      await this._unlockAchievement(user.id, 'night_owl');
    }

    if (totalMin >= 6000 && !achievements.includes('voice_champion')) {
      await this._unlockAchievement(user.id, 'voice_champion');
    }

    if (achievements.length >= 3 && !achievements.includes('social_butterfly')) {
      const visitedChannels = this.db.prepare(`
        SELECT COUNT(DISTINCT c.cid) as cnt FROM xp_log xl
        JOIN users u ON u.id = xl.user_id
        JOIN clients c ON c.client_unique_identifier = u.client_uid
        WHERE u.id = ? AND xl.source = 'voice'
      `).get(user.id);
      if (visitedChannels && visitedChannels.cnt >= 5) {
        await this._unlockAchievement(user.id, 'social_butterfly');
      }
    }
  }

  async _unlockAchievement(userId, achievementId) {
    const now = Math.floor(Date.now() / 1000);
    this.db.prepare('INSERT INTO achievements (user_id, achievement_id, unlocked_at) VALUES (?, ?, ?)').run(userId, achievementId, now);

    const user = this.db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    const config = require('../../config/xp-thresholds.json');
    const ach = config.achievements.find(a => a.id === achievementId);
    if (ach && ach.xp) {
      await this._addXp(userId, ach.xp, `achievement_${achievementId}`);
    }
  }

  async _updateLeaderboardChannel() {
    try {
      const channel = await this._findChannel('🏆 Leaderboard');
      if (!channel) return;

      const topUsers = this.db.prepare('SELECT name, xp FROM users ORDER BY xp DESC LIMIT 10').all();
      let content = '🏆 Top 10 Leaderboard 🏆\n';
      content += '─────────────────────\n';
      const medals = ['🥇', '🥈', '🥉'];
      topUsers.forEach((u, i) => {
        const icon = medals[i] || `${i + 1}.`;
        content += `${icon} ${u.name || 'Unknown'} — ${u.xp} XP\n`;
      });

      const channels = await this.ts3.getChannels();
      const ch = channels.find(c => c.cid == channel.cid);
      if (ch && ch.channel_topic !== content) {
        await this.ts3.editChannel(channel.cid, { channel_topic: content.substring(0, 200) });
      }
    } catch (err) {
      console.error('[LevelBot] Leaderboard update error:', err.message);
    }
  }

  async _findChannel(name) {
    try {
      const channels = await this.ts3.getChannels();
      return channels.find(c => c.channel_name.includes(name)) || null;
    } catch { return null; }
  }

  getUser(userId) {
    return this.db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
  }

  getUserByUid(uid) {
    return this.db.prepare('SELECT * FROM users WHERE client_uid = ?').get(uid);
  }

  getTopUsers(limit) {
    return this.db.prepare('SELECT name, xp, total_voice_minutes FROM users ORDER BY xp DESC LIMIT ?').all(limit || 50);
  }

  getUserAchievements(userId) {
    return this.db.prepare('SELECT achievement_id, unlocked_at FROM achievements WHERE user_id = ? ORDER BY unlocked_at').all(userId);
  }

  getStats() {
    return {
      totalUsers: this.db.prepare('SELECT COUNT(*) as c FROM users').get().c,
      totalXp: this.db.prepare('SELECT COALESCE(SUM(xp), 0) as s FROM users').get().s,
      avgXp: this.db.prepare('SELECT COALESCE(ROUND(AVG(xp)), 0) as a FROM users').get().a,
      totalVoiceHours: Math.round(this.db.prepare('SELECT COALESCE(SUM(total_voice_minutes), 0) as s FROM users').get().s / 60)
    };
  }

  async addXpByUid(uid, amount, source) {
    const user = this.getUserByUid(uid);
    if (!user) return null;
    await this._addXp(user.id, amount, source);
    user.xp += amount;
    const clients = await this.ts3.getClients();
    const client = clients.find(c => c.client_unique_identifier === uid);
    if (client) await this._checkRoleUpgrade(client, user);
    return { ...user, xp: user.xp + amount };
  }

  async setXpByUid(uid, amount) {
    const user = this.getUserByUid(uid);
    if (!user) return null;
    this.db.prepare('UPDATE users SET xp = ? WHERE client_uid = ?').run(amount, uid);
    const clients = await this.ts3.getClients();
    const client = clients.find(c => c.client_unique_identifier === uid);
    if (client) await this._checkRoleUpgrade(client, { ...user, xp: amount });
    return { ...user, xp: amount };
  }

  async rewardCreateChannel(uid) {
    const user = this.getUserByUid(uid);
    if (!user) return null;
    const now = Math.floor(Date.now() / 1000);
    const recent = this.db.prepare("SELECT id FROM xp_log WHERE user_id = ? AND source = 'create_channel' AND timestamp > ?").get(user.id, now - 3600);
    if (recent) return user;
    await this._addXp(user.id, XP_CONFIG.createChannel, 'create_channel');
    const achievements = this.db.prepare('SELECT achievement_id FROM achievements WHERE user_id = ?').all(user.id).map(a => a.achievement_id);
    if (!achievements.includes('home_owner')) {
      await this._unlockAchievement(user.id, 'home_owner');
    }
    user.xp += XP_CONFIG.createChannel;
    return user;
  }
}

if (require.main === module) {
  const bot = new LevelBot();
  bot.start().catch(err => {
    console.error('[LevelBot] Fatal:', err);
    process.exit(1);
  });
  process.on('SIGINT', () => { bot.stop(); process.exit(0); });
  process.on('SIGTERM', () => { bot.stop(); process.exit(0); });
}

module.exports = { LevelBot };
