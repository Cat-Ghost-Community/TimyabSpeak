const { TS6Client } = require('../../shared/ts6-rest');
const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

const CONFIG = {
  apiKey: process.env.TS6_API_KEY || '',
  baseUrl: process.env.TS6_BASE_URL || 'http://127.0.0.1:10080',
  triggerChannelNames: ['🎫 ➕ Create Channel', '🎫?➕ Create Channel'],
  timeWindowCategoryName: '⏳ Time Window',
  maxChannelsPerUser: 1,
  maxCreationsPerHour: 5,
  commandCooldownMs: 2000,
  deleteGraceSeconds: 30,
  claimGraceSeconds: 60,
  orphanTimeoutMinutes: 5,
  dbPath: path.join(__dirname, 'temp-channels.sqlite'),
  pollIntervalMs: 15000,
  channelAdminGroupName: 'Channel Admin'
};

class TempChannelBot {
  constructor() {
    this.ts6 = new TS6Client({ baseUrl: CONFIG.baseUrl, apiKey: CONFIG.apiKey });
    this.db = new Database(CONFIG.dbPath);
    this.db.pragma('journal_mode = WAL');
    this._initDb();
    this._activeTimers = new Map();
    this._commandCooldowns = new Map();
    this._channelCache = null;
    this._categoryCache = null;
    this._channelGroupCache = null;
    this._pollTimer = null;
  }

  _initDb() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS temp_channels (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_id INTEGER NOT NULL UNIQUE,
        creator_id INTEGER NOT NULL,
        creator_uid TEXT NOT NULL,
        creator_name TEXT NOT NULL DEFAULT '',
        channel_name TEXT NOT NULL,
        mode TEXT NOT NULL DEFAULT 'public',
        password_hash TEXT,
        user_limit INTEGER NOT NULL DEFAULT 0,
        bitrate INTEGER NOT NULL DEFAULT 96,
        description TEXT DEFAULT '',
        invited_users TEXT DEFAULT '[]',
        is_permanent INTEGER DEFAULT 0,
        idle_timeout_sec INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        last_active INTEGER NOT NULL,
        deleted INTEGER DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS creation_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_temp_creator ON temp_channels(creator_id);
      CREATE INDEX IF NOT EXISTS idx_temp_channel ON temp_channels(channel_id);
      CREATE INDEX IF NOT EXISTS idx_creation_log_user ON creation_log(user_id, created_at);
    `);
  }

  async start() {
    console.log('[TempBot] Starting...');
    await this._recoverState();
    this._pollTimer = setInterval(() => this._poll(), CONFIG.pollIntervalMs);
    console.log('[TempBot] Running. Poll interval:', CONFIG.pollIntervalMs + 'ms');
  }

  async stop() {
    console.log('[TempBot] Shutting down gracefully...');
    if (this._pollTimer) clearInterval(this._pollTimer);
    for (const [channelId, timer] of this._activeTimers) {
      clearTimeout(timer);
    }
    this._activeTimers.clear();
    this.db.close();
  }

  async _recoverState() {
    try {
      const active = this.db.prepare('SELECT * FROM temp_channels WHERE deleted = 0').all();
      const channels = await this.ts6.getChannels();
      const channelMap = new Map(channels.map(c => [c.cid, c]));
      const now = Math.floor(Date.now() / 1000);

      for (const record of active) {
        if (channelMap.has(record.channel_id)) {
          const ch = channelMap.get(record.channel_id);
          this._startEmptyTimer(record);
          console.log(`[TempBot] Recovered: "${ch.channel_name}" (cid: ${record.channel_id})`);
        } else {
          console.log(`[TempBot] Cleaning orphan DB entry: ${record.channel_name}`);
          this.db.prepare('UPDATE temp_channels SET deleted = 1 WHERE channel_id = ?').run(record.channel_id);
        }
      }

      this.db.prepare(`
        DELETE FROM creation_log WHERE created_at < ?
      `).run(now - 3600);
    } catch (err) {
      console.error('[TempBot] Recover error:', err.message);
    }
  }

  async _poll() {
    try {
      const clients = await this.ts6.getClients();
      const channels = await this.ts6.getChannels();
      const now = Math.floor(Date.now() / 1000);
      const oneHourAgo = now - 3600;

      this.db.prepare('DELETE FROM creation_log WHERE created_at < ?').run(oneHourAgo);

      // Detect clients in trigger channels → auto-create temp channels
      const triggerChannels = channels.filter(c => CONFIG.triggerChannelNames.some(t => c.channel_name.includes(t)));
      for (const tc of triggerChannels) {
        const triggerClients = clients.filter(c => parseInt(c.client_type) === 0 && c.cid == tc.cid);
        for (const client of triggerClients) {
          const existing = this.db.prepare('SELECT id FROM temp_channels WHERE creator_uid = ? AND deleted = 0').get(client.client_unique_identifier);
          if (!existing) {
            await this.handleClientJoinChannel(client, tc.cid);
          }
        }
      }

      const tempRecords = this.db.prepare('SELECT * FROM temp_channels WHERE deleted = 0').all();
      const channelMap = new Map(channels.map(c => [c.cid, c]));

      for (const record of tempRecords) {
        if (!channelMap.has(record.channel_id)) {
          this._handleChannelDeleted(record);
          continue;
        }

        const ch = channelMap.get(record.channel_id);
        const clientsInChannel = clients.filter(c => c.cid == record.channel_id);

        this.db.prepare('UPDATE temp_channels SET last_active = ? WHERE id = ?').run(now, record.id);

        if (clientsInChannel.length > 0) {
          const creatorOnline = clientsInChannel.some(c => c.client_unique_identifier === record.creator_uid);
          if (creatorOnline) {
            this._cancelEmptyTimer(record.channel_id);
          } else if (record.creator_uid) {
            const creatorDisconnected = !clients.some(c => c.client_unique_identifier === record.creator_uid);
            if (creatorDisconnected && (now - record.last_active) > CONFIG.claimGraceSeconds) {
              this._startEmptyTimer(record);
            }
          }
        } else {
          this._startEmptyTimer(record);
        }
      }
    } catch (err) {
      console.error('[TempBot] Poll error:', err.message);
    }
  }

  async handleTextCommand(client, text) {
    const now = Date.now();
    const cooldownKey = `${client.clid}`;
    const lastCmd = this._commandCooldowns.get(cooldownKey) || 0;
    if (now - lastCmd < CONFIG.commandCooldownMs) return;
    this._commandCooldowns.set(cooldownKey, now);

    if (text.startsWith('/new') || text.startsWith('/level') || text.startsWith('/stats') || text.startsWith('/leaderboard') || text.startsWith('/faq')) {
      return;
    }

    const tempRecord = this.db.prepare(`
      SELECT tc.* FROM temp_channels tc
      JOIN clients c ON c.cid = tc.channel_id
      WHERE c.clid = ? AND tc.deleted = 0
    `).get(client.clid);

    if (!tempRecord) {
      if (text === '/help') {
        await this.ts6.sendPrivateMessage(client.clid,
          '╔══════════════════════════════╗\n' +
          '║  General Commands            ║\n' +
          '║  /new [subject] — Open ticket║\n' +
          '║  /level        — Your XP    ║\n' +
          '║  /stats        — Voice stats║\n' +
          '║  /leaderboard  — Top 10 XP  ║\n' +
          '║  /faq [q]      — Search FAQ ║\n' +
          '║                              ║\n' +
          '║  Join a 🎫 Create Channel    ║\n' +
          '║  then type /help for more    ║\n' +
          '╚══════════════════════════════╝'
        );
      }
      return;
    }

    const isCreator = client.client_unique_identifier === tempRecord.creator_uid;
    const canClaim = tempRecord.creator_uid && !isCreator && this._canClaim(tempRecord);

    if (text === '/help') {
      await this._showHelp(client, tempRecord);
      return;
    }

    if (text.startsWith('/name ')) {
      if (!isCreator && !canClaim) return await this._notOwner(client);
      const name = text.slice(6).trim().substring(0, 40);
      if (!name) return await this._error(client, 'Usage: /name <channel name>');
      await this.ts6.editChannel(tempRecord.channel_id, { channel_name: name });
      await this.ts6.sendPrivateMessage(client.clid, `Channel renamed to: ${name}`);
      this.db.prepare('UPDATE temp_channels SET channel_name = ? WHERE id = ?').run(name, tempRecord.id);
      return;
    }

    if (text.startsWith('/limit ')) {
      if (!isCreator) return await this._notOwner(client);
      const limit = parseInt(text.slice(7).trim());
      if (isNaN(limit) || limit < 0 || limit > 100) return await this._error(client, 'Limit must be 0-100 (0 = unlimited)');
      await this.ts6.editChannel(tempRecord.channel_id, { channel_maxclients: limit });
      await this.ts6.sendPrivateMessage(client.clid, `User limit set to: ${limit || 'unlimited'}`);
      this.db.prepare('UPDATE temp_channels SET user_limit = ? WHERE id = ?').run(limit, tempRecord.id);
      return;
    }

    if (text.startsWith('/password ')) {
      if (!isCreator) return await this._notOwner(client);
      const pw = text.slice(10).trim();
      if (pw) {
        await this.ts6.editChannel(tempRecord.channel_id, { channel_password: pw });
        await this.ts6.sendPrivateMessage(client.clid, `Password set. Share with friends to let them join.`);
        this.db.prepare('UPDATE temp_channels SET mode = ?, password_hash = ? WHERE id = ?').run('password', pw, tempRecord.id);
      } else {
        await this.ts6.editChannel(tempRecord.channel_id, { channel_password: '' });
        await this.ts6.sendPrivateMessage(client.clid, 'Password removed.');
        this.db.prepare('UPDATE temp_channels SET mode = ?, password_hash = ? WHERE id = ?').run('public', '', tempRecord.id);
      }
      return;
    }

    if (text === '/public') {
      if (!isCreator) return await this._notOwner(client);
      await this.ts6.setChannelPerm(tempRecord.channel_id, 'i_channel_needed_join_power', 0);
      await this.ts6.editChannel(tempRecord.channel_id, { channel_password: '' });
      this.db.prepare('UPDATE temp_channels SET mode = ?, password_hash = ? WHERE id = ?').run('public', '', tempRecord.id);
      await this.ts6.sendPrivateMessage(client.clid, 'Channel set to public. Anyone can join.');
      return;
    }

    if (text === '/private') {
      if (!isCreator) return await this._notOwner(client);
      await this.ts6.setChannelPerm(tempRecord.channel_id, 'i_channel_needed_join_power', 100);
      await this.ts6.editChannel(tempRecord.channel_id, { channel_password: '' });
      this.db.prepare('UPDATE temp_channels SET mode = ?, password_hash = ? WHERE id = ?').run('private', '', tempRecord.id);
      await this.ts6.sendPrivateMessage(client.clid, 'Channel set to private. Use /invite @user to let people in.');
      return;
    }

    if (text.startsWith('/invite ')) {
      if (!isCreator) return await this._notOwner(client);
      const targetName = text.slice(8).trim();
      const clients = await this.ts6.getClients();
      const target = clients.find(c => c.client_nickname.toLowerCase() === targetName.toLowerCase());
      if (!target) return await this._error(client, 'User not found or not online.');
      await this.ts6.setClientChannelPerm(target.cldbid, tempRecord.channel_id, 'i_channel_needed_join_power', 100);
      const invited = JSON.parse(tempRecord.invited_users || '[]');
      invited.push(target.client_unique_identifier);
      this.db.prepare('UPDATE temp_channels SET invited_users = ? WHERE id = ?').run(JSON.stringify(invited), tempRecord.id);
      await this.ts6.sendPrivateMessage(client.clid, `Invited ${target.client_nickname} to your channel.`);
      await this.ts6.sendPrivateMessage(target.clid, `${client.client_nickname} invited you to their channel! Join now.`);
      return;
    }

    if (text === '/lock') {
      if (!isCreator) return await this._notOwner(client);
      const pw = Math.random().toString(36).slice(2, 10);
      await this.ts6.editChannel(tempRecord.channel_id, { channel_password: pw });
      await this.ts6.setChannelPerm(tempRecord.channel_id, 'i_channel_needed_join_power', 100);
      await this.ts6.setClientChannelPerm(tempRecord.creator_id, tempRecord.channel_id, 'i_channel_needed_join_power', 0);
      this.db.prepare('UPDATE temp_channels SET mode = ?, password_hash = ? WHERE id = ?').run('locked', pw, tempRecord.id);
      await this.ts6.sendPrivateMessage(client.clid, `🔒 Channel locked. Password: ${pw}\nKeep this private. /unlock to unlock.`);
      return;
    }

    if (text === '/unlock') {
      if (!isCreator) return await this._notOwner(client);
      await this.ts6.editChannel(tempRecord.channel_id, { channel_password: '' });
      await this.ts6.deleteChannelPerm(tempRecord.channel_id, 'i_channel_needed_join_power');
      this.db.prepare('UPDATE temp_channels SET mode = ?, password_hash = ? WHERE id = ?').run('public', '', tempRecord.id);
      await this.ts6.sendPrivateMessage(client.clid, '🔓 Channel unlocked.');
      return;
    }

    if (text.startsWith('/kick ')) {
      if (!isCreator) return await this._notOwner(client);
      const targetName = text.slice(6).trim();
      const clients = await this.ts6.getClients();
      const target = clients.find(c => c.cid == tempRecord.channel_id && c.client_nickname.toLowerCase() === targetName.toLowerCase());
      if (!target) return await this._error(client, 'User not found in your channel.');
      await this.ts6.kickClientFromChannel(target.clid, 'Kicked by channel owner');
      await this.ts6.sendPrivateMessage(client.clid, `Kicked ${target.client_nickname} from your channel.`);
      return;
    }

    if (text.startsWith('/bitrate ')) {
      if (!isCreator) return await this._notOwner(client);
      const br = parseInt(text.slice(9).trim());
      if (isNaN(br) || br < 8 || br > 512) return await this._error(client, 'Bitrate must be 8-512 kbps');
      const quality = Math.round((br / 512) * 10);
      await this.ts6.editChannel(tempRecord.channel_id, { channel_codec_quality: Math.max(1, quality) });
      this.db.prepare('UPDATE temp_channels SET bitrate = ? WHERE id = ?').run(br, tempRecord.id);
      await this.ts6.sendPrivateMessage(client.clid, `Bitrate set to ${br} kbps.`);
      return;
    }

    if (text.startsWith('/desc ')) {
      if (!isCreator) return await this._notOwner(client);
      const desc = text.slice(6).trim().substring(0, 200);
      await this.ts6.editChannel(tempRecord.channel_id, { channel_topic: desc });
      this.db.prepare('UPDATE temp_channels SET description = ? WHERE id = ?').run(desc, tempRecord.id);
      await this.ts6.sendPrivateMessage(client.clid, 'Description updated.');
      return;
    }

    if (text.startsWith('/give ')) {
      if (!isCreator) return await this._notOwner(client);
      const targetName = text.slice(6).trim();
      const clients = await this.ts6.getClients();
      const target = clients.find(c => c.clid != client.clid && c.client_nickname.toLowerCase() === targetName.toLowerCase());
      if (!target) return await this._error(client, 'User not found online.');
      this.db.prepare('UPDATE temp_channels SET creator_id = ?, creator_uid = ?, creator_name = ? WHERE id = ?')
        .run(target.cldbid, target.client_unique_identifier, target.client_nickname, tempRecord.id);
      const cg = await this._getChannelAdminGroup();
      if (cg) {
        await this.ts6.setClientChannelGroup(client.cldbid, tempRecord.channel_id, 0);
        await this.ts6.setClientChannelGroup(target.cldbid, tempRecord.channel_id, cg.cgid);
      }
      await this.ts6.sendPrivateMessage(client.clid, `Transferred ownership to ${target.client_nickname}.`);
      await this.ts6.sendPrivateMessage(target.clid, `${client.client_nickname} made you the owner of ${tempRecord.channel_name}!`);
      return;
    }

    if (text === '/claim') {
      if (isCreator) return await this._error(client, 'You already own this channel.');
      if (!this._canClaim(tempRecord)) return await this._error(client, `Cannot claim yet. Wait ${CONFIG.claimGraceSeconds}s after owner leaves.`);
      const now = Math.floor(Date.now() / 1000);
      this.db.prepare('UPDATE temp_channels SET creator_id = ?, creator_uid = ?, creator_name = ? WHERE id = ?')
        .run(client.cldbid, client.client_unique_identifier, client.client_nickname, tempRecord.id);
      const cg = await this._getChannelAdminGroup();
      if (cg) {
        await this.ts6.setClientChannelGroup(client.cldbid, tempRecord.channel_id, cg.cgid);
      }
      this._cancelEmptyTimer(tempRecord.channel_id);
      await this.ts6.sendPrivateMessage(client.clid, `You are now the owner of ${tempRecord.channel_name}!`);
      return;
    }

    if (text === '/hide') {
      if (!isCreator) return await this._notOwner(client);
      const channels = await this.ts6.getChannels();
      const timeWindow = this._findTimeWindowCategory(channels);
      if (timeWindow) {
        await this.ts6.editChannel(tempRecord.channel_id, { cpid: timeWindow.cid });
        await this.ts6.sendPrivateMessage(client.clid, 'Channel hidden in Time Window.');
      }
      return;
    }

    if (text === '/show') {
      if (!isCreator) return await this._notOwner(client);
      const channels = await this.ts6.getChannels();
      const triggerCh = channels.find(c => CONFIG.triggerChannelNames.includes(c.channel_name));
      if (triggerCh) {
        await this.ts6.editChannel(tempRecord.channel_id, { cpid: triggerCh.cpid });
        await this.ts6.sendPrivateMessage(client.clid, 'Channel restored to original category.');
      }
      return;
    }

    if (text.startsWith('/timeout ')) {
      if (!isCreator) return await this._notOwner(client);
      const mins = parseInt(text.slice(9).trim());
      if (isNaN(mins) || mins < 0) return await this._error(client, 'Timeout must be 0+ minutes (0 = delete immediately when empty)');
      this.db.prepare('UPDATE temp_channels SET idle_timeout_sec = ? WHERE id = ?').run(mins * 60, tempRecord.id);
      await this.ts6.sendPrivateMessage(client.clid, `Auto-delete set to ${mins} min idle.`);
      return;
    }

    if (text === '/permanent') {
      if (!isCreator) return await this._notOwner(client);
      const current = this.db.prepare('SELECT is_permanent FROM temp_channels WHERE id = ?').get(tempRecord.id);
      const newVal = current && current.is_permanent ? 0 : 1;
      this.db.prepare('UPDATE temp_channels SET is_permanent = ? WHERE id = ?').run(newVal, tempRecord.id);
      await this.ts6.sendPrivateMessage(client.clid, newVal ? 'Channel is now permanent (never auto-deletes).' : 'Channel is no longer permanent.');
      if (!newVal) this._startEmptyTimer(tempRecord);
      return;
    }

    if (text === '/delete') {
      if (!isCreator) return await this._notOwner(client);
      await this._deleteChannel(tempRecord);
      return;
    }

    if (text === '/settings') {
      const modeIcons = { public: '🌐', private: '🔒', password: '🔑', locked: '🔐' };
      await this.ts6.sendPrivateMessage(client.clid,
        `╔══════════════════════════════╗\n` +
        `║  ${tempRecord.channel_name}       \n` +
        `║  Mode: ${modeIcons[tempRecord.mode] || '🌐'} ${tempRecord.mode}        \n` +
        `║  Limit: ${tempRecord.user_limit || 'unlimited'}       \n` +
        `║  Bitrate: ${tempRecord.bitrate} kbps  \n` +
        `║  Permanent: ${tempRecord.is_permanent ? 'Yes' : 'No'}     \n` +
        `║  Idle timeout: ${tempRecord.idle_timeout_sec ? Math.round(tempRecord.idle_timeout_sec/60) + ' min' : 'immediate'}  \n` +
        `║  Created: ${new Date(tempRecord.created_at * 1000).toLocaleString()}  \n` +
        `╚══════════════════════════════╝`
      );
      return;
    }
  }

  async handleClientJoinChannel(client, channelId) {
    const channels = await this.ts6.getChannels();
    const channel = channels.find(c => c.cid == channelId);
    if (!channel) return;

    const isTrigger = CONFIG.triggerChannelNames.some(t => channel.channel_name.includes(t));
    if (!isTrigger) return;

    const now = Math.floor(Date.now() / 1000);

    const userChannelCount = this.db.prepare('SELECT COUNT(*) as cnt FROM temp_channels WHERE creator_uid = ? AND deleted = 0').get(client.client_unique_identifier);
    if (userChannelCount.cnt >= CONFIG.maxChannelsPerUser) {
      await this.ts6.sendPrivateMessage(client.clid, `You already have ${userChannelCount.cnt} channel(s). Max is ${CONFIG.maxChannelsPerUser}.`);
      return;
    }

    const recentCreations = this.db.prepare('SELECT COUNT(*) as cnt FROM creation_log WHERE user_id = ? AND created_at > ?').get(client.cldbid, now - 3600);
    if (recentCreations.cnt >= CONFIG.maxCreationsPerHour) {
      await this.ts6.sendPrivateMessage(client.clid, `Too many channel creations (${recentCreations.cnt}/${CONFIG.maxCreationsPerHour} per hour).`);
      return;
    }

    const totalActive = this.db.prepare('SELECT COUNT(*) as cnt FROM temp_channels WHERE deleted = 0').get();
    if (totalActive.cnt >= 30) {
      await this.ts6.sendPrivateMessage(client.clid, 'Server at max temp channel capacity (30). Try again later.');
      return;
    }

    const timeWindow = this._findTimeWindowCategory(channels);
    const parentId = timeWindow ? timeWindow.cid : channel.cpid;

    const chName = `${client.client_nickname}'s Room`.substring(0, 40);
    try {
      const newChannel = await this.ts6.createChannel(chName, parentId, {
        codec: 4,
        codecQuality: 10,
        maxClients: 0,
        topic: `Created by ${client.client_nickname} · /help for commands`
      });

      const cg = await this._getChannelAdminGroup();
      if (cg && newChannel.cid) {
        await this.ts6.setClientChannelGroup(client.cldbid, newChannel.cid, cg.cgid);
      }

      const recordId = this.db.prepare(`
        INSERT INTO temp_channels (channel_id, creator_id, creator_uid, creator_name, channel_name, created_at, last_active)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `).run(newChannel.cid, client.cldbid, client.client_unique_identifier, client.client_nickname, chName, now, now).lastInsertRowid;

      this.db.prepare('INSERT INTO creation_log (user_id, created_at) VALUES (?, ?)').run(client.cldbid, now);

      await this.ts6.moveClient(client.clid, newChannel.cid);

      await this.ts6.sendPrivateMessage(client.clid,
        `╔══════════════════════════════════════╗\n` +
        `║  🎧 Welcome to your channel!         ║\n` +
        `║                                      ║\n` +
        `║  Commands:                           ║\n` +
        `║  /name <text>   — Rename your room   ║\n` +
        `║  /limit <N>     — Set max users      ║\n` +
        `║  /lock          — Only you can join  ║\n` +
        `║  /private       — Invite-only mode   ║\n` +
        `║  /password <pw> — Lock with password ║\n` +
        `║  /public        — Let anyone join    ║\n` +
        `║  /invite @user  — Invite someone     ║\n` +
        `║  /delete        — Delete your room   ║\n` +
        `║  /settings      — Show room settings ║\n` +
        `║  /help          — All commands       ║\n` +
        `╚══════════════════════════════════════╝`
      );

      console.log(`[TempBot] Created channel "${chName}" for ${client.client_nickname}`);
    } catch (err) {
      console.error('[TempBot] Create channel error:', err.message);
      await this.ts6.sendPrivateMessage(client.clid, 'Failed to create channel. Please try again.');
    }
  }

  async _getChannelAdminGroup() {
    if (this._channelGroupCache) return this._channelGroupCache;
    try {
      const groups = await this.ts6.getChannelGroups();
      const admin = groups.find(g => g.cgid == 6 || g.name === CONFIG.channelAdminGroupName);
      if (admin) this._channelGroupCache = admin;
      return admin;
    } catch { return null; }
  }

  _findTimeWindowCategory(channels) {
    return channels.find(c => c.channel_name === CONFIG.timeWindowCategoryName && c.pid == 0);
  }

  _startEmptyTimer(record) {
    if (this._activeTimers.has(record.channel_id)) return;
    const timeoutMs = record.idle_timeout_sec > 0 ? record.idle_timeout_sec * 1000 : CONFIG.deleteGraceSeconds * 1000;

    const timer = setTimeout(async () => {
      try {
        const channels = await this.ts6.getChannels();
        const ch = channels.find(c => c.cid == record.channel_id);
        if (!ch) { this._handleChannelDeleted(record); return; }
        const clients = await this.ts6.getChannelClients(record.channel_id);
        if (clients.length === 0) {
          if (record.is_permanent) {
            const now = Math.floor(Date.now() / 1000);
            if (record.idle_timeout_sec > 0 && (now - record.last_active) > record.idle_timeout_sec) {
              const ownerOnline = await this._isUserOnline(record.creator_uid);
              if (!ownerOnline) { await this._deleteChannel(record); return; }
            }
          } else {
            await this._deleteChannel(record);
          }
        }
      } catch (err) {
        console.error('[TempBot] Empty timer error:', err.message);
      }
      this._activeTimers.delete(record.channel_id);
    }, timeoutMs);

    this._activeTimers.set(record.channel_id, timer);
  }

  _cancelEmptyTimer(channelId) {
    const timer = this._activeTimers.get(channelId);
    if (timer) { clearTimeout(timer); this._activeTimers.delete(channelId); }
  }

  async _deleteChannel(record) {
    try {
      await this.ts6.deleteChannel(record.channel_id);
    } catch (err) {
      console.error(`[TempBot] Delete channel ${record.channel_id} error:`, err.message);
    }
    this.db.prepare('UPDATE temp_channels SET deleted = 1 WHERE id = ?').run(record.id);
    this._cancelEmptyTimer(record.channel_id);
    console.log(`[TempBot] Deleted channel: "${record.channel_name}"`);
  }

  _handleChannelDeleted(record) {
    this.db.prepare('UPDATE temp_channels SET deleted = 1 WHERE channel_id = ?').run(record.channel_id);
    this._cancelEmptyTimer(record.channel_id);
  }

  async _isUserOnline(uid) {
    try {
      const clients = await this.ts6.getClients();
      return clients.some(c => c.client_unique_identifier === uid);
    } catch { return false; }
  }

  _canClaim(record) {
    const now = Math.floor(Date.now() / 1000);
    return (now - record.last_active) > CONFIG.claimGraceSeconds;
  }

  async _notOwner(client) {
    await this.ts6.sendPrivateMessage(client.clid, `You don't own this channel. /claim to claim it if the owner left.`);
  }

  async _error(client, msg) {
    await this.ts6.sendPrivateMessage(client.clid, `❌ ${msg}`);
  }

  async _showHelp(client, record) {
    const isCreator = client.client_unique_identifier === record.creator_uid;
    const canClaim = this._canClaim(record);
    const ownerStatus = isCreator ? ' (you)' : (canClaim ? ' (claimable)' : '');

    await this.ts6.sendPrivateMessage(client.clid,
      `╔══════════════════════════════════════╗\n` +
      `║  Temp Channel Commands               ║\n` +
      `║  Owner: ${record.creator_name}${ownerStatus}  \n` +
      `║                                      ║\n` +
      `║  /name <text>   — Rename             ║\n` +
      `║  /limit <N>     — Max users          ║\n` +
      `║  /password <pw> — Set/remove password║\n` +
      `║  /public        — Anyone can join    ║\n` +
      `║  /private       — Invite-only        ║\n` +
      `║  /invite @user  — Invite someone     ║\n` +
      `║  /lock          — Only you           ║\n` +
      `║  /unlock        — Unlock             ║\n` +
      `║  /kick @user    — Kick user          ║\n` +
      `║  /bitrate <N>   — Audio quality      ║\n` +
      `║  /desc <text>   — Channel description║\n` +
      `║  /give @user    — Transfer ownership ║\n` +
      (canClaim ? `║  /claim         — Claim ownership    ║\n` : '') +
      `║  /hide          — Hide in Time Window║\n` +
      `║  /show          — Restore visibility ║\n` +
      `║  /timeout <N>   — Auto-delete N min  ║\n` +
      `║  /permanent     — Toggle permanent   ║\n` +
      `║  /delete        — Delete now         ║\n` +
      `║  /settings      — Show config        ║\n` +
      `╚══════════════════════════════════════╝`
    );
  }
}

if (require.main === module) {
  const bot = new TempChannelBot();
  bot.start().catch(err => {
    console.error('[TempBot] Fatal:', err);
    process.exit(1);
  });
  process.on('SIGINT', async () => { await bot.stop(); process.exit(0); });
  process.on('SIGTERM', async () => { await bot.stop(); process.exit(0); });
}

module.exports = { TempChannelBot };

