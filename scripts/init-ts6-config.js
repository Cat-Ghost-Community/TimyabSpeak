#!/usr/bin/env node
// TimyabSpeak — Initialize TS6 server groups and channels via REST API
const { TS6Client } = require('../shared/ts6-rest');
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
const apiKey = env.TS6_API_KEY || '';
const baseUrl = env.TS6_BASE_URL || 'http://127.0.0.1:10080';
const queryPass = env.TS6_QUERY_PASSWORD || '';

if (!apiKey) {
  console.log('[init-ts6-config] No API key found, skipping server configuration');
  process.exit(0);
}

const ts6 = new TS6Client({ baseUrl, apiKey, sshPassword: queryPass });

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function waitForTS6(maxRetries) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      const ok = await ts6.health();
      if (ok) return true;
    } catch (e) {}
    console.log(`[init-ts6-config] Waiting for TS6... (${i + 1}/${maxRetries})`);
    await sleep(2000);
  }
  return false;
}

async function createServerGroups() {
  const rolesFile = path.join(CONFIG_DIR, 'roles.json');
  if (!fs.existsSync(rolesFile)) {
    console.log('[init-ts6-config] roles.json not found, skipping groups');
    return [];
  }

  const roles = JSON.parse(fs.readFileSync(rolesFile, 'utf8'));
  const existing = await ts6.getServerGroups().catch(() => []);
  const created = [];

  for (const role of roles) {
    const exists = existing.find(g =>
      g.name && g.name.toLowerCase() === role.name.toLowerCase()
    );
    if (exists) {
      console.log(`[init-ts6-config] Group exists: ${role.name}`);
      created.push(exists);
      continue;
    }

    try {
      const group = await ts6.createServerGroup(role.name, {
        type: 1,
        sortOrder: role.sort_order || 0
      });
      console.log(`[init-ts6-config] Created group: ${role.name} (sgid=${group.sgid || '?'}) `);
      created.push(group);
      await sleep(500);
    } catch (e) {
      console.log(`[init-ts6-config] Failed to create group ${role.name}: ${e.message}`);
    }
  }

  return created;
}

async function createChannels() {
  const channelsFile = path.join(CONFIG_DIR, 'channels.json');
  if (!fs.existsSync(channelsFile)) {
    console.log('[init-ts6-config] channels.json not found, skipping channels');
    return;
  }

  const config = JSON.parse(fs.readFileSync(channelsFile, 'utf8'));
  const existing = await ts6.getChannels().catch(() => []);

  // Check if channels already created (more than default channel exists)
  if (existing.length > 1) {
    console.log(`[init-ts6-config] ${existing.length} channels exist, skipping creation`);
    return;
  }

  const categories = config.categories || [];
  for (const cat of categories) {
    try {
      const parent = await ts6.createChannel(cat.name, 0, {
        codec: 4,
        codecQuality: 10,
        maxClients: 0
      });
      console.log(`[init-ts6-config] Created category: ${cat.name} (cid=${parent.cid || '?'}) `);
      await sleep(500);

      if (cat.channels) {
        for (const ch of cat.channels) {
          try {
            await ts6.createChannel(ch.name, parent.cid, {
              codec: ch.type === 'voice' ? 4 : 5,
              codecQuality: 10,
              maxClients: ch.maxClients || 0,
              topic: ch.description || '',
              description: ch.description || ''
            });
            console.log(`[init-ts6-config]   Channel: ${ch.name}`);
            await sleep(300);
          } catch (e) {
            console.log(`[init-ts6-config]   Failed: ${ch.name}: ${e.message}`);
          }
        }
      }
    } catch (e) {
      console.log(`[init-ts6-config] Failed category ${cat.name}: ${e.message}`);
    }
  }
}

async function main() {
  console.log('[init-ts6-config] Starting TS6 configuration...');

  const ready = await waitForTS6(15);
  if (!ready) {
    console.log('[init-ts6-config] TS6 not responding, skipping configuration');
    process.exit(1);
  }

  console.log('[init-ts6-config] TS6 is ready');

  // First create groups (needed before channels for permission assignments)
  await createServerGroups();

  // Then create channel structure
  await createChannels();

  console.log('[init-ts6-config] Server configuration complete');
}

main().catch(e => {
  console.error('[init-ts6-config] Error:', e.message);
  process.exit(1);
});
