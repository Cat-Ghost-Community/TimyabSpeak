const https = require('https');
const http = require('http');

class TS6Client {
  constructor(opts) {
    this.baseUrl = opts.baseUrl || 'http://127.0.0.1:10080';
    this.apiKey = opts.apiKey || '';
    this.sshHost = opts.sshHost || '127.0.0.1';
    this.sshPort = opts.sshPort || 10022;
    this.sshPassword = opts.sshPassword || '';
    this.connected = false;
    this._serverGroupCache = null;
    this._channelGroupCache = null;
  }

  _request(method, path, body) {
    return new Promise((resolve, reject) => {
      const url = new URL(path, this.baseUrl);
      const lib = url.protocol === 'https:' ? https : http;
      const opts = {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname + url.search,
        method,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-API-Key': this.apiKey
        },
        timeout: 10000
      };
      const req = lib.request(opts, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try { resolve(JSON.parse(data)); }
            catch { resolve(data); }
          } else {
            reject(new Error(`TS6 API ${res.statusCode}: ${data}`));
          }
        });
      });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error('Request timeout')); });
      if (body) req.write(JSON.stringify(body));
      req.end();
    });
  }

  async health() {
    try {
      // TS6 may not have /health, try /server or /clients instead
      await this._request('GET', '/clients');
      return true;
    } catch {
      try {
        await this._request('GET', '/server');
        return true;
      } catch { return false; }
    }
  }

  async getClients() {
    const res = await this._request('GET', '/clients');
    // Handle both array and { body: [...] } response formats
    if (Array.isArray(res)) return res;
    if (res && Array.isArray(res.body)) return res.body;
    if (res && Array.isArray(res.clients)) return res.clients;
    return [];
  }

  async getClientByUid(uid) {
    return this._request('GET', `/clients?uid=${uid}`);
  }

  async getChannels() {
    const res = await this._request('GET', '/channels');
    if (Array.isArray(res)) return res;
    if (res && Array.isArray(res.body)) return res.body;
    if (res && Array.isArray(res.channels)) return res.channels;
    return [];
  }

  async getChannel(channelId) {
    return this._request('GET', `/channels/${channelId}`);
  }

  async createChannel(name, parentId, opts = {}) {
    return this._request('POST', '/channels', {
      channel_name: name,
      cpid: parentId,
      channel_flag_permanent: 0,
      channel_flag_semi_permanent: 0,
      channel_codec: opts.codec || 4,
      channel_codec_quality: opts.codecQuality || 10,
      channel_maxclients: opts.maxClients || 0,
      channel_maxfamilyclients: opts.maxFamily || 0,
      channel_password: opts.password || '',
      channel_topic: opts.topic || '',
      channel_description: opts.description || ''
    });
  }

  async deleteChannel(channelId) {
    return this._request('DELETE', `/channels/${channelId}`);
  }

  async editChannel(channelId, props) {
    return this._request('PUT', `/channels/${channelId}`, props);
  }

  async moveClient(clientId, channelId) {
    return this._request('PUT', `/clients/${clientId}/move`, { cid: channelId });
  }

  async kickClientFromChannel(clientId, reason) {
    return this._request('PUT', `/clients/${clientId}/kick`, { reason: reason || '' });
  }

  async getServerGroups() {
    if (this._serverGroupCache) return this._serverGroupCache;
    const res = await this._request('GET', '/servergroups');
    let groups = [];
    if (Array.isArray(res)) groups = res;
    else if (res && Array.isArray(res.body)) groups = res.body;
    else if (res && Array.isArray(res.servergroups)) groups = res.servergroups;
    this._serverGroupCache = groups;
    return groups;
  }

  async getServerGroupById(groupId) {
    const groups = await this.getServerGroups();
    return groups.find(g => g.sgid == groupId);
  }

  async createServerGroup(name, opts = {}) {
    this._serverGroupCache = null;
    return this._request('POST', '/servergroups', {
      name,
      type: opts.type || 0,
      iconid: opts.iconId || 0,
      sortid: opts.sortOrder || 0
    });
  }

  async addServerGroupPerm(groupId, permName, permValue, skipNegate) {
    return this._request('PUT', `/servergroups/${groupId}/permissions`, {
      permsid: permName,
      permvalue: permValue,
      skipnegate: skipNegate ? 1 : 0
    });
  }

  async addClientToServerGroup(groupId, clientDbId) {
    return this._request('PUT', `/servergroups/${groupId}/clients`, { cldbid: clientDbId });
  }

  async removeClientFromServerGroup(groupId, clientDbId) {
    return this._request('DELETE', `/servergroups/${groupId}/clients/${clientDbId}`);
  }

  async getChannelGroups() {
    if (this._channelGroupCache) return this._channelGroupCache;
    const res = await this._request('GET', '/channelgroups');
    let groups = [];
    if (Array.isArray(res)) groups = res;
    else if (res && Array.isArray(res.body)) groups = res.body;
    else if (res && Array.isArray(res.channelgroups)) groups = res.channelgroups;
    this._channelGroupCache = groups;
    return groups;
  }

  async createChannelGroup(name, opts = {}) {
    this._channelGroupCache = null;
    return this._request('POST', '/channelgroups', {
      name,
      iconid: opts.iconId || 0,
      sortid: opts.sortOrder || 0
    });
  }

  async addChannelGroupPerm(groupId, permName, permValue) {
    return this._request('PUT', `/channelgroups/${groupId}/permissions`, {
      permsid: permName,
      permvalue: permValue
    });
  }

  async setClientChannelGroup(clientDbId, channelId, groupId) {
    return this._request('PUT', `/clients/${clientDbId}/channelgroup`, {
      cid: channelId,
      cgid: groupId
    });
  }

  async setChannelPerm(channelId, permName, permValue) {
    return this._request('PUT', `/channels/${channelId}/permissions`, {
      permsid: permName,
      permvalue: permValue
    });
  }

  async deleteChannelPerm(channelId, permName) {
    return this._request('DELETE', `/channels/${channelId}/permissions/${permName}`);
  }

  async setClientChannelPerm(clientDbId, channelId, permName, permValue) {
    return this._request('PUT', `/clients/${clientDbId}/channelpermissions`, {
      cid: channelId,
      permsid: permName,
      permvalue: permValue
    });
  }

  async deleteClientChannelPerm(clientDbId, channelId, permName) {
    return this._request('DELETE', `/channels/${channelId}/clientpermissions/${clientDbId}/${permName}`);
  }

  async getClientDbIdByUid(uid) {
    const client = await this._request('GET', `/clients?uid=${uid}`);
    return client && client.cldbid ? client.cldbid : null;
  }

  async sendTextMessage(target, message, targetMode) {
    return this._request('POST', '/textmessage', {
      targetmode: targetMode || 1,
      target: target,
      msg: message
    });
  }

  async sendChannelMessage(channelId, message) {
    return this.sendTextMessage(channelId, message, 2);
  }

  async sendPrivateMessage(clientId, message) {
    return this.sendTextMessage(clientId, message, 1);
  }

  async getServerInfo() {
    return this._request('GET', '/server');
  }

  async getClientChannelId(clientId) {
    const clients = await this.getClients();
    const client = clients.find(c => c.clid == clientId || c.client_unique_identifier == clientId);
    return client ? client.cid : null;
  }

  async getOnlineClientByUid(uid) {
    const clients = await this.getClients();
    return clients.find(c => c.client_unique_identifier === uid) || null;
  }

  async getChannelClients(channelId) {
    const clients = await this.getClients();
    return clients.filter(c => c.cid == channelId);
  }
}

module.exports = { TS6Client };
