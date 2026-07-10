#!/usr/bin/env node
// TimyabSpeak — Initialize TS3 server groups and channels via ServerQuery
const { TS3Client } = require('../shared/ts3-query');
const fs = require('fs');
const path = require('path');

const ENV_FILE = process.argv[2] || path.join(__dirname, '..', '.env');
const CONFIG_DIR = path.join(__dirname, '..', 'config');

function loadEnv() {
  const env = {};
  try {
    const data = fs.readFileSync(ENV_FILE, 'utf8');
    data.split('\n').forEach(line => {
      const m = line.match(/^([A-Z_]+)=(.*)$/);
      if (m) env[m[1]] = m[2];
    });
  } catch (e) {}
  return env;
}

const env = loadEnv();
const queryHost = env.TS3_QUERY_HOST || '127.0.0.1';
const queryPort = parseInt(env.TS3_QUERY_PORT || '10011');
const queryPass = env.TS3_QUERY_PASSWORD || '';

if (!queryPass) {
  console.log('[init-ts3-config] No query password found, skipping server configuration');
  process.exit(0);
}

const ts3 = new TS3Client({ host: queryHost, port: queryPort, password: queryPass });

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function waitForTS3(maxRetries) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      ts3.disconnect();
      const ok = await ts3.health();
      if (ok) return true;
    } catch (e) {
      console.log(`[init-ts3-config] TS3 not ready: ${e.message}`);
    }
    console.log(`[init-ts3-config] Waiting for TS3... (${i + 1}/${maxRetries})`);
    await sleep(2000);
  }
  return false;
}

let createdGroups = 0;
let skippedGroups = 0;
let failedGroups = 0;

async function createServerGroups() {
  const rolesFile = path.join(CONFIG_DIR, 'roles.json');
  if (!fs.existsSync(rolesFile)) {
    console.log('[init-ts3-config] roles.json not found, skipping groups');
    return;
  }

  const roles = JSON.parse(fs.readFileSync(rolesFile, 'utf8'));
  let existing;
  try {
    existing = await ts3.getServerGroups();
  } catch (e) {
    console.log(`[init-ts3-config] Failed to fetch existing groups: ${e.message}`);
    failedGroups = roles.length;
    return;
  }

  for (const role of roles) {
    const exists = existing.find(g =>
      g.name && g.name.toLowerCase() === role.name.toLowerCase()
    );
    if (exists) {
      console.log(`[init-ts3-config] Group exists: ${role.name}`);
      skippedGroups++;
      continue;
    }

    if (role.name === 'Guest') {
      console.log('[init-ts3-config] Skipping Guest (TS3 default)');
      skippedGroups++;
      continue;
    }

    try {
      await ts3.createServerGroup(role.name, { type: 1 });
      console.log(`[init-ts3-config] Created group: ${role.name}`);
      createdGroups++;
      await sleep(500);
    } catch (e) {
      console.log(`[init-ts3-config] Failed to create group ${role.name}: ${e.message}`);
      failedGroups++;
    }
  }
}

let createdChannels = 0;
let failedChannels = 0;

async function createChannels() {
  const channelsFile = path.join(CONFIG_DIR, 'channels.json');
  if (!fs.existsSync(channelsFile)) {
    console.log('[init-ts3-config] channels.json not found, skipping channels');
    return;
  }

  const config = JSON.parse(fs.readFileSync(channelsFile, 'utf8'));
  let existing;
  try {
    existing = await ts3.getChannels();
  } catch (e) {
    console.log(`[init-ts3-config] Failed to fetch existing channels: ${e.message}`);
    return;
  }

  if (existing.length > 1) {
    console.log(`[init-ts3-config] ${existing.length} channels exist, skipping creation`);
    return;
  }

  const categories = config.categories || [];
  for (const cat of categories) {
    try {
      const parent = await ts3.createChannel(cat.name, 0, {
        codec: 4, codecQuality: 10, maxClients: 0, permanent: true
      });
      console.log(`[init-ts3-config] Category: ${cat.name}`);
      createdChannels++;
      await sleep(300);

      if (cat.channels) {
        for (const ch of cat.channels) {
          try {
            await ts3.createChannel(ch.name, parent.cid, {
              codec: ch.type === 'voice' ? 4 : 5,
              codecQuality: 10,
              maxClients: ch.maxClients || 0,
              topic: ch.description || '',
              description: ch.description || '',
              permanent: true
            });
            console.log(`[init-ts3-config]   Channel: ${ch.name}`);
            createdChannels++;
            await sleep(200);
          } catch (e) {
            console.log(`[init-ts3-config]   Failed channel ${ch.name}: ${e.message}`);
            failedChannels++;
          }
        }
      }
    } catch (e) {
      console.log(`[init-ts3-config] Failed category ${cat.name}: ${e.message}`);
      failedChannels++;
    }
  }
}

async function main() {
  console.log('[init-ts3-config] Starting TS3 configuration...');

  const ready = await waitForTS3(15);
  if (!ready) {
    console.log('[init-ts3-config] TS3 not responding, skipping configuration');
    process.exit(1);
  }

  console.log('[init-ts3-config] TS3 is ready, creating server groups and channels...');
  await createServerGroups();
  await createChannels();

  console.log(`[init-ts3-config] Groups: ${createdGroups} created, ${skippedGroups} skipped, ${failedGroups} failed`);
  console.log(`[init-ts3-config] Channels: ${createdChannels} created, ${failedChannels} failed`);

  if (failedGroups > 0 || failedChannels > 0) {
    console.log('[init-ts3-config] Server configuration completed with errors');
    process.exit(1);
  }

  console.log('[init-ts3-config] Server configuration complete');
}

main().catch(e => {
  console.error('[init-ts3-config] Error:', e.message);
  process.exit(1);
});
