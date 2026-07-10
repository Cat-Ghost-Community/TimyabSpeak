const net = require('net');

class TS3Client {
  constructor(opts) {
    this.host = opts.host || '127.0.0.1';
    this.port = opts.port || 10011;
    this.password = opts.password || '';
    this.autoConnect = opts.autoConnect !== false;
    this._socket = null;
    this._buffer = '';
    this._connected = false;
    this._ready = false;
    this._pending = null;
    this._queue = [];
    this._nextId = 1;
    this._connectPromise = null;
  }

  async connect() {
    if (this._ready) return;
    if (this._connectPromise) return this._connectPromise;

    this._connectPromise = this._doConnect();
    try {
      await this._connectPromise;
    } finally {
      this._connectPromise = null;
    }
  }

  async _doConnect() {
    return new Promise((resolve, reject) => {
      this._socket = new net.Socket();
      this._socket.setEncoding('utf8');
      this._socket.setNoDelay(true);

      const onData = (data) => {
        this._buffer += data;
        if (this._connected && this._pending) {
          this._tryResolvePending();
        }
      };

      this._socket.on('data', onData);

      this._socket.on('connect', () => {
        this._connected = true;
        // Wait for TS3 welcome banner, then login
        this._waitForBanner().then(() => this._login()).then(() => {
          this._ready = true;
          resolve();
        }).catch(reject);
      });

      this._socket.on('error', (err) => {
        this._connected = false;
        this._ready = false;
        reject(err);
      });

      this._socket.on('close', () => {
        this._connected = false;
        this._ready = false;
      });

      this._socket.connect({ host: this.host, port: this.port });
    });
  }

  async _waitForBanner() {
    return new Promise((resolve, reject) => {
      let attempts = 0;
      const maxAttempts = 100; // 10 seconds
      const check = () => {
        if (++attempts > maxAttempts) {
          reject(new Error('TS3 banner timeout'));
          return;
        }
        if (this._buffer.includes('TS3') && this._buffer.includes('\n')) {
          const lines = this._buffer.split('\n');
          if (lines.length >= 2) {
            this._buffer = '';
            resolve();
            return;
          }
        }
        setTimeout(check, 100);
      };
      check();
    });
  }

  async _login() {
    const resp = await this._sendRaw(`login serveradmin ${this.password}`);
    if (!resp || resp.errorId !== 0) {
      throw new Error(`TS3 login failed: ${resp ? resp.msg : 'no response'}`);
    }
    const useResp = await this._sendRaw('use 1');
    if (!useResp || useResp.errorId !== 0) {
      // Server may not have virtual server 1, try use port=9987
      const use2 = await this._sendRaw('use port=9987');
      if (!use2 || use2.errorId !== 0) {
        this._ready = true; // Mark ready anyway, queries may still work
      }
    }
  }

  _sendRaw(cmd) {
    return new Promise((resolve, reject) => {
      const item = { cmd, resolve, reject };
      if (this._pending) {
        this._queue.push(item);
      } else {
        this._pending = item;
        this._doSend(cmd);
      }
    });
  }

  _doSend(cmd) {
    if (!this._connected) {
      this._pending.reject(new Error('Not connected'));
      this._pending = null;
      this._processQueue();
      return;
    }
    try {
      this._socket.write(cmd + '\n');
    } catch (e) {
      this._pending.reject(e);
      this._pending = null;
      this._processQueue();
    }
  }

  _tryResolvePending() {
    if (!this._pending) return;
    const resp = this._extractResponse();
    if (resp !== null) {
      const p = this._pending;
      this._pending = null;
      p.resolve(resp);
      this._processQueue();
    }
  }

  _extractResponse() {
    const errorMatch = this._buffer.match(/\n(error id=(\d+) msg=([^\r\n]*))\r?\n/);
    if (!errorMatch) return null;

    const errorLine = errorMatch[1];
    const errorId = parseInt(errorMatch[2], 10);
    const msg = this._unescape(errorMatch[3]);

    const errorPos = this._buffer.indexOf('\n' + errorLine + '\n');
    const before = this._buffer.substring(0, errorPos + 1);
    const lines = before.split('\n').filter(l => l && !l.startsWith('error '));

    // Parse remaining data after the error line
    const after = this._buffer.substring(errorPos + errorLine.length + 2);
    this._buffer = after;

    // Parse key=value pairs from response lines
    const data = {};
    const list = [];
    for (const line of lines) {
      if (line.includes('=')) {
        const parts = {};
        let current = line;
        while (current.length > 0) {
          const eqIdx = current.indexOf('=');
          if (eqIdx === -1) break;
          const key = current.substring(0, eqIdx).trim();
          current = current.substring(eqIdx + 1);
          const spaceIdx = current.indexOf(' ');
          let value;
          if (spaceIdx === -1) {
            value = current;
            current = '';
          } else {
            // Handle quoted/escaped values
            value = current.substring(0, spaceIdx);
            current = current.substring(spaceIdx + 1);
          }
          parts[key] = this._unescape(value);
        }
        list.push(parts);
      }
    }

    return { errorId, msg, data, list: list.length > 0 ? list : (Object.keys(data).length > 0 ? [data] : []) };
  }

  _unescape(str) {
    if (!str) return str;
    return str
      .replace(/\\\\/g, '\x00').replace(/\\\//g, '/').replace(/\\s/g, ' ')
      .replace(/\\p/g, '|').replace(/\\a/g, '\x07').replace(/\\b/g, '\b')
      .replace(/\\f/g, '\f').replace(/\\n/g, '\n').replace(/\\r/g, '\r')
      .replace(/\\t/g, '\t').replace(/\\v/g, '\v')
      .replace(/\x00/g, '\\');
  }

  _escape(str) {
    if (!str) return '';
    return String(str)
      .replace(/\\/g, '\\\\').replace(/\//g, '\\/').replace(/ /g, '\\s')
      .replace(/\|/g, '\\p').replace(/\x07/g, '\\a').replace(/\b/g, '\\b')
      .replace(/\f/g, '\\f').replace(/\n/g, '\\n').replace(/\r/g, '\\r')
      .replace(/\t/g, '\\t').replace(/\v/g, '\\v');
  }

  _processQueue() {
    if (this._queue.length === 0) return;
    const next = this._queue.shift();
    this._pending = { cmd: next.cmd, resolve: next.resolve, reject: next.reject };
    this._doSend(next.cmd);
  }

  async _send(cmd) {
    await this.connect();
    const resp = await this._sendRaw(cmd);
    if (resp.errorId !== 0) {
      throw new Error(`TS3 ${cmd.split(' ')[0]} error id=${resp.errorId} msg=${resp.msg}`);
    }
    return resp;
  }

  disconnect() {
    if (this._socket) {
      try { this._socket.write('quit\n'); } catch (e) {}
      this._socket.destroy();
    }
    this._connected = false;
    this._ready = false;
    this._buffer = '';
  }

  // ─── PUBLIC API (matching TS6Client surface) ───

  async health() {
    try {
      await this._send('version');
      return true;
    } catch (e) {
      return false;
    }
  }

  async getClients() {
    const resp = await this._send('clientlist -uid -ip');
    return resp.list || [];
  }

  async getClientByUid(uid) {
    const resp = await this._send(`clientfind pattern=${this._escape(uid)}`);
    const list = resp.list || [];
    return list[0] || null;
  }

  async getChannels() {
    const resp = await this._send('channellist');
    return resp.list || [];
  }

  async getChannel(channelId) {
    const resp = await this._send(`channelinfo cid=${channelId}`);
    return (resp.list && resp.list[0]) || null;
  }

  async createChannel(name, parentId, opts = {}) {
    let cmd = `channelcreate channel_name=${this._escape(name)}`;
    if (parentId) cmd += ` cpid=${parentId}`;
    if (opts.codec) cmd += ` channel_codec=${opts.codec}`;
    if (opts.codecQuality) cmd += ` channel_codec_quality=${opts.codecQuality}`;
    if (opts.maxClients !== undefined) cmd += ` channel_maxclients=${opts.maxClients}`;
    if (opts.topic) cmd += ` channel_topic=${this._escape(opts.topic)}`;
    if (opts.description) cmd += ` channel_description=${this._escape(opts.description)}`;
    if (opts.password) cmd += ` channel_password=${this._escape(opts.password)}`;
    if (opts.permanent) cmd += ` channel_flag_permanent=1`;
    if (opts.semiPermanent) cmd += ` channel_flag_semi_permanent=1`;
    if (opts.defaultChannel) cmd += ` channel_flag_default=1`;
    const resp = await this._send(cmd);
    return (resp.list && resp.list[0]) || { cid: resp.data && resp.data.cid };
  }

  async deleteChannel(channelId) {
    return this._send(`channeldelete cid=${channelId} force=1`);
  }

  async editChannel(channelId, props) {
    let cmd = `channeledit cid=${channelId}`;
    for (const [key, val] of Object.entries(props)) {
      if (key.startsWith('channel_') || key === 'cid') continue;
      const ts3Key = key.includes('_') ? key : `channel_${key}`;
      cmd += ` ${ts3Key}=${this._escape(String(val))}`;
    }
    // Direct pass-through for raw TS3 channel keys
    if (props.channel_name) cmd += ` channel_name=${this._escape(props.channel_name)}`;
    if (props.channel_topic) cmd += ` channel_topic=${this._escape(props.channel_topic)}`;
    if (props.channel_description) cmd += ` channel_description=${this._escape(props.channel_description)}`;
    if (props.channel_password) cmd += ` channel_password=${this._escape(props.channel_password)}`;
    if (props.channel_maxclients !== undefined) cmd += ` channel_maxclients=${props.channel_maxclients}`;
    if (props.channel_codec) cmd += ` channel_codec=${props.channel_codec}`;
    if (props.channel_codec_quality) cmd += ` channel_codec_quality=${props.channel_codec_quality}`;
    return this._send(cmd);
  }

  async setChannelPerm(channelId, permName, permValue) {
    const resp = await this._send(`channeladdperm cid=${channelId} permsid=${permName} permvalue=${permValue}`);
    return resp;
  }

  async deleteChannelPerm(channelId, permName) {
    return this._send(`channeldelperm cid=${channelId} permsid=${permName}`);
  }

  async getServerGroups() {
    const resp = await this._send('servergrouplist');
    return resp.list || [];
  }

  async getServerGroupById(groupId) {
    const groups = await this.getServerGroups();
    return groups.find(g => Number(g.sgid) === Number(groupId)) || null;
  }

  async createServerGroup(name, opts = {}) {
    let cmd = `servergroupadd name=${this._escape(name)}`;
    if (opts.type !== undefined) cmd += ` type=${opts.type}`;
    const resp = await this._send(cmd);
    return (resp.list && resp.list[0]) || { sgid: resp.data && resp.data.sgid };
  }

  async deleteServerGroup(groupId) {
    return this._send(`servergroupdel sgid=${groupId} force=1`);
  }

  async addServerGroupPerm(groupId, permName, permValue, skipNegate) {
    let cmd = `servergroupaddperm sgid=${groupId} permsid=${permName} permvalue=${permValue}`;
    if (skipNegate) cmd += ` permskipnegate=1`;
    return this._send(cmd);
  }

  async addClientToServerGroup(groupId, clientDbId) {
    return this._send(`servergroupaddclient sgid=${groupId} cldbid=${clientDbId}`);
  }

  async removeClientFromServerGroup(groupId, clientDbId) {
    return this._send(`servergroupdelclient sgid=${groupId} cldbid=${clientDbId}`);
  }

  async getChannelGroups() {
    const resp = await this._send('channelgrouplist');
    return resp.list || [];
  }

  async createChannelGroup(name, opts = {}) {
    let cmd = `channelgroupadd name=${this._escape(name)}`;
    if (opts.type !== undefined) cmd += ` type=${opts.type}`;
    const resp = await this._send(cmd);
    return (resp.list && resp.list[0]) || { cgid: resp.data && resp.data.cgid };
  }

  async addChannelGroupPerm(groupId, permName, permValue) {
    return this._send(`channelgroupaddperm cgid=${groupId} permsid=${permName} permvalue=${permValue}`);
  }

  async setClientChannelGroup(clientDbId, channelId, groupId) {
    return this._send(`setclientchannelgroup cid=${channelId} cldbid=${clientDbId} cgid=${groupId}`);
  }

  async sendTextMessage(target, message, targetMode) {
    return this._send(`sendtextmessage targetmode=${targetMode} target=${target} msg=${this._escape(message)}`);
  }

  async sendChannelMessage(channelId, message) {
    return this.sendTextMessage(channelId, message, 2);
  }

  async sendPrivateMessage(clientId, message) {
    return this.sendTextMessage(clientId, message, 1);
  }

  async getServerInfo() {
    const resp = await this._send('serverinfo');
    return (resp.list && resp.list[0]) || resp.data || {};
  }

  async getChannelClients(channelId) {
    const resp = await this._send(`channelclientlist cid=${channelId}`);
    return resp.list || [];
  }

  async moveClient(clientId, channelId) {
    return this._send(`clientmove clid=${clientId} cid=${channelId}`);
  }

  async kickClientFromChannel(clientId, reason) {
    const r = reason ? ` reasonid=5 reasonmsg=${this._escape(reason)}` : ' reasonid=5';
    return this._send(`clientkick clid=${clientId}${r}`);
  }

  async getClientDbIdByUid(uid) {
    const resp = await this._send(`clientgetdbidfromuid cluid=${uid}`);
    if (resp.list && resp.list[0]) return resp.list[0].cldbid;
    return null;
  }

  async getOnlineClientByUid(uid) {
    const clients = await this.getClients();
    return clients.find(c => c.client_unique_identifier === uid) || null;
  }

  async setClientChannelPerm(clientDbId, channelId, permName, permValue) {
    return this._send(`clientaddperm cldbid=${clientDbId} cid=${channelId} permsid=${permName} permvalue=${permValue}`);
  }

  async deleteClientChannelPerm(clientDbId, channelId, permName) {
    return this._send(`clientdelperm cldbid=${clientDbId} cid=${channelId} permsid=${permName}`);
  }
}

module.exports = { TS3Client };
