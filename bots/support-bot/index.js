const { TS3Client } = require('../../shared/ts3-query');
const { TicketDB } = require('../../shared/ticket-db');
const path = require('path');
const fs = require('fs');

const CONFIG = {
  ticketCategoryName: '📋 Active Tickets',
  archivedCategoryName: '🔒 Archived Tickets',
  createTicketChannelName: '🎫 Create Ticket',
  staffChatChannelName: '💼 Staff Chat',
  staffLogsChannelName: '📝 Staff Logs',
  pollIntervalMs: 10000,
  autoCloseInactiveHours: 48,
  autoCloseMaxOpenHours: 72,
  slaWarningMinutes: 30,
  dbPath: path.join(__dirname, 'tickets.sqlite'),
  transcriptDir: path.join(__dirname, '..', '..', 'tickets'),
  supportRoleNames: ['Support', 'Moderator', 'Admin', 'Owner'],
  supportGroupCheck: true
};

class SupportBot {
  constructor() {
    this.ts3 = new TS3Client({
      host: process.env.TS3_QUERY_HOST || '127.0.0.1',
      port: parseInt(process.env.TS3_QUERY_PORT || '10011'),
      password: process.env.TS3_QUERY_PASSWORD || ''
    });
    this.db = new TicketDB(CONFIG.dbPath);
    this._pollTimer = null;
    this._commandCooldowns = new Map();
  }

  async start() {
    console.log('[SupportBot] Starting...');
    fs.mkdirSync(CONFIG.transcriptDir, { recursive: true });
    this._unclaimedNotified = new Set();
    this._pollTimer = setInterval(() => this._tick(), CONFIG.pollIntervalMs);
    console.log('[SupportBot] Running.');
  }

  stop() {
    if (this._pollTimer) clearInterval(this._pollTimer);
    this.db.close();
  }

  async _tick() {
    try {
      const now = Math.floor(Date.now() / 1000);
      const activeTickets = this.db.listTickets().filter(t => t.status === 'open' || t.status === 'claimed');

      for (const ticket of activeTickets) {
        if (ticket.status === 'open') {
          const elapsed = now - ticket.created_at;
          if (elapsed > CONFIG.slaWarningMinutes * 60) {
            await this._notifyStaffUnclaimed(ticket);
          }
          if (elapsed > CONFIG.autoCloseMaxOpenHours * 3600) {
            await this._autoCloseTicket(ticket, 'Auto-closed — no response for 72 hours');
          }
        }

        if (ticket.status === 'claimed') {
          const lastMessage = this.db.db.prepare(`
            SELECT timestamp, user_id FROM ticket_messages WHERE ticket_id = ? ORDER BY timestamp DESC LIMIT 1
          `).get(ticket.id);

          if (lastMessage && lastMessage.user_id === ticket.creator_id) {
            const idleHours = (now - lastMessage.timestamp) / 3600;
            if (idleHours > CONFIG.autoCloseInactiveHours) {
              await this._autoCloseTicket(ticket, 'Auto-closed due to inactivity');
            }
          }
        }
      }
    } catch (err) {
      console.error('[SupportBot] Tick error:', err.message);
    }
  }

  async handleTextCommand(client, text, channelId) {
    const now = Date.now();
    const cooldownKey = `cmd_${client.clid}`;
    const lastCmd = this._commandCooldowns.get(cooldownKey) || 0;
    if (now - lastCmd < 2000) return;
    this._commandCooldowns.set(cooldownKey, now);

    const lowerText = text.trim().toLowerCase();

    if (text.startsWith('/new')) {
      await this._handleNewTicket(client, text);
      return;
    }

    const channels = await this.ts3.getChannels();
    const currentChannel = channels.find(c => c.cid == channelId);
    if (!currentChannel) return;

    const ticket = this.db.getTicketByChannel(channelId);
    if (!ticket) return;

    const isStaff = await this._isStaff(client);
    const isCreator = ticket.creator_uid === client.client_unique_identifier;

    if (text === '/close') {
      if (isCreator || isStaff) {
        const reason = text.slice(6).trim();
        await this._handleCloseTicket(client, ticket, reason, isCreator);
      } else {
        await this._pm(client.clid, "You don't have permission to close this ticket.");
      }
      return;
    }

    if (text === '/resolve' && isStaff) {
      await this._handleResolveTicket(client, ticket);
      return;
    }

    if (text === '/claim' && isStaff) {
      await this._handleClaimTicket(client, ticket);
      return;
    }

    if (text.startsWith('/transfer ') && isStaff) {
      const targetName = text.slice(10).trim();
      await this._handleTransferTicket(client, ticket, targetName);
      return;
    }

    if (text.startsWith('/note ') && isStaff) {
      const note = text.slice(6).trim();
      if (note) {
        this.db.addMessage(ticket.id, client.cldbid, client.client_unique_identifier, client.client_nickname, `[NOTE] ${note}`, true);
        await this._pm(client.clid, `Note added to ticket #${ticket.id}.`);
      }
      return;
    }

    if (text === '/alert' && isStaff) {
      const lastMsg = this.db.db.prepare(`
        SELECT timestamp FROM ticket_messages WHERE ticket_id = ? AND user_id != ? ORDER BY timestamp DESC LIMIT 1
      `).get(ticket.id, ticket.claimed_by || 0);

      if (lastMsg) {
        await this._pm(client.clid, `User last active ${Math.floor((Date.now()/1000 - lastMsg.timestamp)/60)} min ago.`);
      }
      return;
    }

    if (text === '/log' && isStaff) {
      await this._sendTranscript(client.clid, ticket);
      return;
    }

    if (text.startsWith('/block ') && isStaff) {
      const [_, targetName, ...reasonParts] = text.split(' ');
      const reason = reasonParts.join(' ') || 'No reason';
      await this._handleBlockUser(client, targetName, reason);
      return;
    }

    if (text === '/idle' && isStaff) {
      const lastMsg = this.db.db.prepare(`
        SELECT timestamp FROM ticket_messages WHERE ticket_id = ? ORDER BY timestamp DESC LIMIT 1
      `).get(ticket.id);
      if (lastMsg) {
        const mins = Math.floor((Date.now() / 1000 - lastMsg.timestamp) / 60);
        await this._pm(client.clid, `Last activity: ${mins} min ago.`);
      }
      return;
    }

    if (isCreator && !text.startsWith('/') && text.length > 0) {
      this.db.addMessage(ticket.id, client.cldbid, client.client_unique_identifier, client.client_nickname, text, false);
      await this._notifyStaffNewMessage(ticket, client);
      return;
    }

    if (isStaff && ticket.status !== 'closed' && ticket.status !== 'resolved' && !text.startsWith('/') && text.length > 0) {
      this.db.addMessage(ticket.id, client.cldbid, client.client_unique_identifier, client.client_nickname, text, false);
      await this._pm(client.clid, 'Message sent in ticket.');
      return;
    }
  }

  async _handleNewTicket(client, text) {
    const isBlocked = this.db.isBlocked(client.cldbid);
    if (isBlocked) {
      return this._pm(client.clid, 'You are blocked from creating tickets. Contact an admin directly.');
    }

    const hasOpen = this.db.userHasOpenTicket(client.cldbid);
    if (hasOpen) {
      return this._pm(client.clid, 'You already have an open ticket. Close it first with /close in your ticket channel.');
    }

    const subject = text.length > 5 ? text.slice(4).trim().substring(0, 200) : 'No subject';

    const channels = await this.ts3.getChannels();
    const ticketCategory = channels.find(c => c.channel_name === CONFIG.ticketCategoryName && c.pid == 0);
    if (!ticketCategory) {
      return this._pm(client.clid, 'Ticket system not configured. Contact an admin.');
    }

    const ticketsInCat = channels.filter(c => c.pid === ticketCategory.cid);
    const ticketNum = ticketsInCat.length + 1;

    const chName = `🎫 ${client.client_nickname}`.substring(0, 40);
    try {
      const newChannel = await this.ts3.createChannel(chName, ticketCategory.cid, {
        codec: 4,
        codecQuality: 10,
        maxClients: 0,
        topic: `${client.client_nickname}'s ticket — ${subject.substring(0, 80)}`,
        password: ''
      });

      await this.ts3.setChannelPerm(newChannel.cid, 'i_channel_needed_join_power', 50);

      const members = await this.ts3.getClients();
      const staffMembers = [];
      for (const m of members) {
        if (await this._isStaff(m)) {
          staffMembers.push(m);
        }
      }

      for (const staff of staffMembers) {
        try {
          await this.ts3.setClientChannelPerm(staff.cldbid, newChannel.cid, 'i_channel_needed_join_power', 50);
        } catch {}
      }

      await this.ts3.setClientChannelPerm(client.cldbid, newChannel.cid, 'i_channel_needed_join_power', 50);

      const ticketId = this.db.createTicket(newChannel.cid, client.cldbid, client.client_unique_identifier, client.client_nickname, subject);

      const greeting =
        `┌─────────────────────────────────────────────┐\n` +
        `│  🎫 Ticket #${ticketId} — ${client.client_nickname}            │\n` +
        `│  ─────────────────────                      │\n` +
        `│  Status: Open                               │\n` +
        `│  Subject: ${subject.substring(0, 50)}              │\n` +
        `│                                              │\n` +
        `│  A staff member will be with you shortly.   │\n` +
        `│  Please describe your issue in detail.      │\n` +
        `│                                              │\n` +
        `│  Commands:                                  │\n` +
        `│    /close   — Close this ticket            │\n` +
        `└─────────────────────────────────────────────┘`;

      await this.ts3.sendChannelMessage(newChannel.cid, greeting);

      const staffChat = channels.find(c => c.channel_name === CONFIG.staffChatChannelName);
      if (staffChat) {
        await this.ts3.sendChannelMessage(staffChat.cid,
          `@here New ticket #${ticketId} from ${client.client_nickname}: ${subject.substring(0, 100)}`
        );
      }

      console.log(`[SupportBot] Ticket #${ticketId} opened by ${client.client_nickname}`);
    } catch (err) {
      console.error('[SupportBot] Create ticket error:', err.message);
      await this._pm(client.clid, 'Failed to create ticket. Please try again.');
    }
  }

  async _handleClaimTicket(client, ticket) {
    if (ticket.status !== 'open') {
      return this._pm(client.clid, `Ticket #${ticket.id} is already claimed by ${ticket.claimed_by_name || 'someone'}.`);
    }
    this.db.claimTicket(ticket.id, client.cldbid, client.client_nickname);
    const channels = await this.ts3.getChannels();
    const ch = channels.find(c => c.cid == ticket.channel_id);
    if (ch) {
      await this.ts3.editChannel(ticket.channel_id, { channel_topic: `Claimed by ${client.client_nickname} · ${ticket.subject.substring(0, 80)}` });
    }
    await this.ts3.sendChannelMessage(ticket.channel_id, `🛠️ ${client.client_nickname} is handling this ticket.`);
    console.log(`[SupportBot] Ticket #${ticket.id} claimed by ${client.client_nickname}`);
  }

  async _handleCloseTicket(client, ticket, reason, isCreator) {
    if (ticket.status === 'closed' || ticket.status === 'resolved') {
      return this._pm(client.clid, 'Ticket already closed.');
    }

    this.db.closeTicket(ticket.id, client.cldbid, reason);
    await this._writeTranscript(ticket);

    const channels = await this.ts3.getChannels();
    const archivedCategory = channels.find(c => c.channel_name === CONFIG.archivedCategoryName && c.pid == 0);
    const ch = channels.find(c => c.cid == ticket.channel_id);

    if (archivedCategory && ch) {
      await this.ts3.editChannel(ticket.channel_id, {
        cpid: archivedCategory.cid,
        channel_name: `🔒 ${ticket.creator_name}`.substring(0, 40),
        channel_topic: `Closed by ${client.client_nickname} · ${reason || 'No reason'}`
      });
      await this.ts3.setChannelPerm(ticket.channel_id, 'i_channel_needed_join_power', 100);
    }

    const staffChat = channels.find(c => c.channel_name === CONFIG.staffChatChannelName);
    if (staffChat) {
      await this.ts3.sendChannelMessage(staffChat.cid,
        `Ticket #${ticket.id} (${ticket.creator_name}) closed by ${client.client_nickname}. ${reason ? 'Reason: ' + reason : ''}`
      );
    }

    if (!isCreator) {
      try {
        const clients = await this.ts3.getClients();
        const creator = clients.find(c => c.client_unique_identifier === ticket.creator_uid);
        if (creator) {
          await this._pm(creator.clid, `Your ticket #${ticket.id} has been closed. ${reason ? 'Reason: ' + reason : ''}`);
        }
      } catch {}
    }

    console.log(`[SupportBot] Ticket #${ticket.id} closed by ${client.client_nickname}`);
  }

  async _handleResolveTicket(client, ticket) {
    this.db.resolveTicket(ticket.id, client.cldbid);
    await this._handleCloseTicket(client, ticket, 'Resolved', false);
  }

  async _handleTransferTicket(client, ticket, targetName) {
    const clients = await this.ts3.getClients();
    const target = clients.find(c =>
      c.client_nickname.toLowerCase() === targetName.toLowerCase() &&
      c.clid !== client.clid
    );
    if (!target) return this._pm(client.clid, 'Staff member not found.');

    const isTargetStaff = await this._isStaff(target);
    if (!isTargetStaff) return this._pm(client.clid, 'Target user is not staff.');

    this.db.claimTicket(ticket.id, target.cldbid, target.client_nickname);
    await this.ts3.sendChannelMessage(ticket.channel_id, `🔄 Ticket reassigned to ${target.client_nickname}.`);
    await this._pm(target.clid, `Ticket #${ticket.id} assigned to you by ${client.client_nickname}.`);
    console.log(`[SupportBot] Ticket #${ticket.id} transferred to ${target.client_nickname}`);
  }

  async _handleBlockUser(client, targetName, reason) {
    const clients = await this.ts3.getClients();
    const target = clients.find(c =>
      c.client_nickname.toLowerCase() === targetName.toLowerCase()
    );
    if (!target) return this._pm(client.clid, 'User not found.');

    this.db.blockUser(target.cldbid, target.client_unique_identifier, reason, client.cldbid);
    const channels = await this.ts3.getChannels();
    const logsCh = channels.find(c => c.channel_name === CONFIG.staffLogsChannelName);
    if (logsCh) {
      await this.ts3.sendChannelMessage(logsCh.cid,
        `🔨 ${client.client_nickname} blocked ${target.client_nickname} from creating tickets. Reason: ${reason}`
      );
    }
    await this._pm(client.clid, `Blocked ${target.client_nickname} from creating tickets.`);
  }

  async _autoCloseTicket(ticket, reason) {
    this.db.closeTicket(ticket.id, 0, reason);
    await this._writeTranscript(ticket);

    const channels = await this.ts3.getChannels();
    const archivedCategory = channels.find(c => c.channel_name === CONFIG.archivedCategoryName && c.pid == 0);
    const ch = channels.find(c => c.cid == ticket.channel_id);

    if (archivedCategory && ch) {
      await this.ts3.editChannel(ticket.channel_id, {
        cpid: archivedCategory.cid,
        channel_name: `🔒 ${ticket.creator_name}`.substring(0, 40),
        channel_topic: `Auto-closed · ${reason}`
      });
      await this.ts3.setChannelPerm(ticket.channel_id, 'i_channel_needed_join_power', 100);
    }

    console.log(`[SupportBot] Ticket #${ticket.id} auto-closed: ${reason}`);
  }

  async _notifyStaffUnclaimed(ticket) {
    if (this._unclaimedNotified.has(ticket.id)) return;
    this._unclaimedNotified.add(ticket.id);
    const channels = await this.ts3.getChannels();
    const staffChat = channels.find(c => c.channel_name === CONFIG.staffChatChannelName);
    if (staffChat) {
      await this.ts3.sendChannelMessage(staffChat.cid,
        `⚠️ Ticket #${ticket.id} (${ticket.creator_name}) unclaimed for ${CONFIG.slaWarningMinutes} min. Please claim.`
      );
    }
    setTimeout(() => this._unclaimedNotified.delete(ticket.id), 3600000);
  }

  async _notifyStaffNewMessage(ticket, client) {
    const channels = await this.ts3.getChannels();
    const staffChat = channels.find(c => c.channel_name === CONFIG.staffChatChannelName);
    if (staffChat) {
      const ticketCh = channels.find(c => c.cid == ticket.channel_id);
      const chName = ticketCh ? ticketCh.channel_name : `#${ticket.id}`;
      await this.ts3.sendChannelMessage(staffChat.cid,
        `💬 New message from ${client.client_nickname} in ${chName}`
      );
    }
  }

  async _writeTranscript(ticket) {
    try {
      const messages = this.db.getMessages(ticket.id);
      let transcript =
        `═══════════════════════════════════════\n` +
        `  Ticket #${ticket.id}\n` +
        `  User: ${ticket.creator_name}\n` +
        `  Subject: ${ticket.subject}\n` +
        `  Created: ${new Date(ticket.created_at * 1000).toISOString()}\n` +
        `  Closed: ${ticket.closed_at ? new Date(ticket.closed_at * 1000).toISOString() : 'N/A'}\n` +
        `  Handled by: ${ticket.claimed_by_name || 'N/A'}\n` +
        `  Status: ${ticket.status}\n` +
        `═══════════════════════════════════════\n\n`;

      for (const msg of messages) {
        const label = msg.is_staff_note ? '[STAFF NOTE]' : msg.user_name;
        transcript += `[${new Date(msg.timestamp * 1000).toISOString()}] ${label}: ${msg.message}\n`;
      }

      const filePath = path.join(CONFIG.transcriptDir, `ticket-${ticket.id}.log`);
      fs.writeFileSync(filePath, transcript, 'utf8');
      this.db.setTranscriptPath(ticket.id, filePath);
    } catch (err) {
      console.error('[SupportBot] Transcript write error:', err.message);
    }
  }

  async _sendTranscript(clientId, ticket) {
    const filePath = path.join(CONFIG.transcriptDir, `ticket-${ticket.id}.log`);
    if (fs.existsSync(filePath)) {
      const content = fs.readFileSync(filePath, 'utf8');
      await this._pm(clientId, content.substring(0, 1500));
    } else {
      await this._pm(clientId, 'No transcript available.');
    }
  }

  async _isStaff(client) {
    if (!CONFIG.supportGroupCheck) return true;
    try {
      const clients = await this.ts3.getClients();
      const fullClient = clients.find(c => c.clid == client.clid);
      if (!fullClient) return false;
      const serverGroups = await this.ts3.getServerGroups();
      const clientGroups = Array.isArray(serverGroups) ? serverGroups.filter(g => g.cldbid == client.cldbid) : [];
      return CONFIG.supportRoleNames.some(roleName =>
        clientGroups.some(g => g.name.toLowerCase().includes(roleName.toLowerCase()))
      );
    } catch { return false; }
  }

  async _pm(clientId, message) {
    try { await this.ts3.sendPrivateMessage(clientId, message); } catch {}
  }

  getTicketDB() {
    return this.db;
  }
}

if (require.main === module) {
  const bot = new SupportBot();
  bot.start().catch(err => {
    console.error('[SupportBot] Fatal:', err);
    process.exit(1);
  });
  process.on('SIGINT', () => { bot.stop(); process.exit(0); });
  process.on('SIGTERM', () => { bot.stop(); process.exit(0); });
}

module.exports = { SupportBot };
