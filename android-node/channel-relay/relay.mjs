import { execFile } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const HOME = os.homedir();
const ENABLED = process.env.PHONE_RELAY_ENABLED === '1';
const CODEX_ENABLED = process.env.PHONE_CODEX_ENABLED === '1';
const SSH = process.env.SSH_BIN || 'ssh';
const SSH_HOST = process.env.PHONE_SSH_HOST || '127.0.0.1';
const SSH_PORT = process.env.PHONE_SSH_PORT || '8022';
const SSH_USER = process.env.PHONE_SSH_USER || '';
const SSH_KEY = process.env.PHONE_SSH_KEY || `${HOME}/.openclaw/secrets/phone_ssh_ed25519`;
const CODEX_MODEL = process.env.PHONE_CODEX_MODEL || 'gpt-5.6-sol';
const REMOTE_RUNNER = '$HOME/.local/bin/openclaw-phone-codex-run';
const STATE_DIR = process.env.PHONE_RELAY_STATE_DIR || `${HOME}/.openclaw/phone-bridge`;
const STATE_FILE = path.join(STATE_DIR, 'relay-state.json');
const POLICY_FILE = process.env.PHONE_RELAY_POLICY_FILE || path.join(STATE_DIR, 'relay-policy.txt');
const SESSION_RE = new RegExp(
  process.env.PHONE_RELAY_SESSION_REGEX || '(telegram.*direct|direct.*telegram)',
  'i',
);
const ALLOW_COMMANDS = process.env.PHONE_RELAY_ALLOW_COMMANDS === '1';
const MAX_INPUT = Number(process.env.PHONE_RELAY_MAX_INPUT || '12000');
const MAX_OUTPUT = Number(process.env.PHONE_RELAY_MAX_OUTPUT || '20000');
const TIMEOUT_MS = Number(process.env.PHONE_CODEX_TIMEOUT_MS || '240000');

function log(event, fields = {}) {
  process.stderr.write(`${JSON.stringify({ ts: new Date().toISOString(), event, ...fields })}\n`);
}

function sha(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

async function loadState() {
  try {
    const parsed = JSON.parse(await fs.readFile(STATE_FILE, 'utf8'));
    return { cursor: parsed.cursor ?? 0, processed: Array.isArray(parsed.processed) ? parsed.processed : [] };
  } catch {
    return { cursor: 0, processed: [] };
  }
}

async function saveState(state) {
  await fs.mkdir(STATE_DIR, { recursive: true, mode: 0o700 });
  const tmp = `${STATE_FILE}.${process.pid}.tmp`;
  await fs.writeFile(tmp, `${JSON.stringify({ cursor: state.cursor, processed: state.processed.slice(-500) }, null, 2)}\n`, { mode: 0o600 });
  await fs.rename(tmp, STATE_FILE);
  await fs.chmod(STATE_FILE, 0o600);
}

async function policyText() {
  try {
    return (await fs.readFile(POLICY_FILE, 'utf8')).slice(0, 12000);
  } catch {
    return [
      'Reply in the user language.',
      'Be concise, action-first, and honest about uncertainty.',
      'Never expose API keys, OAuth tokens, passwords, or private configuration.',
      'Do not claim that a device or external action was completed unless the supplied evidence proves it.',
      'This relay produces text replies only. Do not pretend to execute phone or OpenClaw tools.',
    ].join('\n');
  }
}

function sshArgs(remoteCommand) {
  if (!SSH_USER) throw new Error('PHONE_SSH_USER is required');
  return [
    '-p', String(SSH_PORT),
    '-i', SSH_KEY,
    '-o', 'BatchMode=yes',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ConnectTimeout=10',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=2',
    `${SSH_USER}@${SSH_HOST}`,
    remoteCommand,
  ];
}

async function runPhone(prompt) {
  const envelope = `${JSON.stringify({ version: 1, model: CODEX_MODEL, prompt })}\n`;
  const { stdout, stderr } = await new Promise((resolve, reject) => {
    const child = execFile(
      SSH,
      sshArgs(REMOTE_RUNNER),
      { timeout: TIMEOUT_MS, maxBuffer: 12 * 1024 * 1024, encoding: 'utf8', windowsHide: true },
      (error, out, err) => {
        if (error) {
          reject(new Error(String(err || out || error.message).trim().slice(0, 2000)));
          return;
        }
        resolve({ stdout: String(out || ''), stderr: String(err || '') });
      },
    );
    child.stdin.end(envelope);
  });

  let answer = '';
  let fatal = '';
  for (const raw of stdout.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    try {
      const event = JSON.parse(line);
      const type = String(event.type || '');
      if (type === 'error' || type === 'turn.failed') {
        fatal = event.message || event.error?.message || JSON.stringify(event);
      }
      const item = event.item || event.data?.item;
      if (item?.type === 'agent_message' && typeof item.text === 'string') answer = item.text;
      if (type === 'turn.completed' && typeof event.final_output === 'string') answer = event.final_output;
    } catch {
      // Older Codex versions may emit only the final answer.
    }
  }
  if (fatal) throw new Error(`phone Codex failed: ${fatal}`);
  if (!answer) answer = stdout.trim();
  if (!answer) throw new Error(`phone Codex returned no text${stderr.trim() ? `: ${stderr.trim().slice(0, 1000)}` : ''}`);
  return answer.slice(0, MAX_OUTPUT);
}

function textFromContent(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    return value
      .map((part) => {
        if (typeof part === 'string') return part;
        if (part?.type === 'text' && typeof part.text === 'string') return part.text;
        return '';
      })
      .filter(Boolean)
      .join('\n');
  }
  if (value && typeof value === 'object') {
    if (typeof value.text === 'string') return value.text;
    if (typeof value.content === 'string') return value.content;
  }
  return '';
}

function parseToolResult(result) {
  const texts = (result?.content || [])
    .filter((item) => item?.type === 'text' && typeof item.text === 'string')
    .map((item) => item.text);
  if (texts.length === 0) return result?.structuredContent ?? {};
  const joined = texts.join('\n');
  try {
    return JSON.parse(joined);
  } catch {
    return { text: joined };
  }
}

function schemaProperties(tool) {
  return tool?.inputSchema?.properties || {};
}

function chooseKey(props, candidates, fallback) {
  return candidates.find((name) => Object.prototype.hasOwnProperty.call(props, name)) || fallback;
}

function normalizeEvents(payload) {
  if (Array.isArray(payload)) return payload;
  if (Array.isArray(payload?.events)) return payload.events;
  if (Array.isArray(payload?.items)) return payload.items;
  if (payload?.event) return [payload.event];
  if (payload && (payload.type || payload.message)) return [payload];
  return [];
}

function extractInbound(event) {
  const root = event?.event && typeof event.event === 'object' ? event.event : event;
  const message = root?.message && typeof root.message === 'object' ? root.message : root;
  const type = String(root?.type || message?.type || '').toLowerCase();
  if (type && type !== 'message' && !type.includes('message')) return null;
  const role = String(message?.role || root?.role || message?.sender?.role || '').toLowerCase();
  if (role && !['user', 'human', 'inbound'].includes(role)) return null;
  const sessionKey = String(
    root?.session_key || root?.sessionKey || root?.conversation?.session_key || root?.conversation?.sessionKey || message?.session_key || message?.sessionKey || '',
  );
  const channel = String(root?.channel || root?.route?.channel || message?.channel || '').toLowerCase();
  if (!SESSION_RE.test(sessionKey) && channel !== 'telegram') return null;
  if (/group|supergroup/i.test(sessionKey) && process.env.PHONE_RELAY_ALLOW_GROUPS !== '1') return null;
  const text = textFromContent(message?.content ?? message?.text ?? root?.content ?? root?.text).trim();
  if (!text || text.length > MAX_INPUT) return null;
  if (text.startsWith('/') && !ALLOW_COMMANDS) return null;
  const messageId = String(message?.id || root?.message_id || root?.messageId || root?.id || '');
  const createdAt = String(message?.created_at || message?.createdAt || root?.created_at || root?.createdAt || '');
  return { sessionKey, text, messageId, createdAt };
}

async function relaySession(client, toolMap, inbound, state) {
  const dedup = sha(`${inbound.sessionKey}\n${inbound.messageId}\n${inbound.createdAt}\n${inbound.text}`);
  if (state.processed.includes(dedup)) return;

  const policy = await policyText();
  const prompt = [
    'SYSTEM OPERATING CONTRACT:',
    policy,
    '',
    'LATEST TELEGRAM MESSAGE:',
    inbound.text,
  ].join('\n');

  log('phone_codex_start', { session: sha(inbound.sessionKey).slice(0, 12), message: dedup.slice(0, 12) });
  const answer = await runPhone(prompt);

  const sendTool = toolMap.get('messages_send');
  if (!sendTool) throw new Error('OpenClaw MCP tool messages_send is unavailable');
  const props = schemaProperties(sendTool);
  const args = {};
  args[chooseKey(props, ['session_key', 'sessionKey', 'conversation_id', 'conversationId'], 'session_key')] = inbound.sessionKey;
  args[chooseKey(props, ['text', 'message', 'content'], 'text')] = answer;
  const result = await client.callTool({ name: 'messages_send', arguments: args });
  if (result?.isError) throw new Error(`messages_send failed: ${JSON.stringify(parseToolResult(result)).slice(0, 1500)}`);

  state.processed.push(dedup);
  await saveState(state);
  log('reply_sent', { session: sha(inbound.sessionKey).slice(0, 12), message: dedup.slice(0, 12), chars: answer.length });
}

async function runBridge() {
  if (!ENABLED) throw new Error('PHONE_RELAY_ENABLED is not 1');
  if (!CODEX_ENABLED) throw new Error('PHONE_CODEX_ENABLED is not 1');
  const transport = new StdioClientTransport({
    command: 'openclaw',
    args: ['mcp', 'serve', '--claude-channel-mode', 'off'],
    stderr: 'inherit',
  });
  const client = new Client({ name: 'phone-codex-channel-relay', version: '1.0.0' });
  await client.connect(transport);
  const listed = await client.listTools();
  const toolMap = new Map((listed.tools || []).map((tool) => [tool.name, tool]));
  const waitName = toolMap.has('events_wait') ? 'events_wait' : toolMap.has('events_poll') ? 'events_poll' : '';
  if (!waitName || !toolMap.has('messages_send')) throw new Error('Required OpenClaw channel MCP tools are unavailable');

  const state = await loadState();
  log('relay_connected', { waitTool: waitName, processed: state.processed.length });

  while (true) {
    const waitTool = toolMap.get(waitName);
    const props = schemaProperties(waitTool);
    const args = {};
    if (Object.prototype.hasOwnProperty.call(props, 'cursor')) args.cursor = state.cursor;
    const timeoutKey = chooseKey(props, ['timeout', 'timeoutSeconds', 'timeout_seconds'], 'timeout');
    if (Object.prototype.hasOwnProperty.call(props, timeoutKey)) args[timeoutKey] = waitName === 'events_wait' ? 25 : 1;
    if (Object.prototype.hasOwnProperty.call(props, 'limit')) args.limit = 100;

    const result = await client.callTool({ name: waitName, arguments: args });
    if (result?.isError) throw new Error(`${waitName} failed: ${JSON.stringify(parseToolResult(result)).slice(0, 1500)}`);
    const payload = parseToolResult(result);
    const nextCursor = payload?.next_cursor ?? payload?.nextCursor ?? payload?.cursor;
    if (nextCursor !== undefined && nextCursor !== null) state.cursor = nextCursor;

    for (const event of normalizeEvents(payload)) {
      const inbound = extractInbound(event);
      if (!inbound?.sessionKey) continue;
      try {
        await relaySession(client, toolMap, inbound, state);
      } catch (error) {
        log('relay_message_error', { error: String(error?.message || error).slice(0, 1800) });
      }
    }
    await saveState(state);
    if (waitName === 'events_poll') await new Promise((resolve) => setTimeout(resolve, 1500));
  }
}

let stopping = false;
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    if (stopping) return;
    stopping = true;
    log('relay_stopping', { signal });
    process.exit(0);
  });
}

let backoff = 2000;
while (!stopping) {
  try {
    await runBridge();
    backoff = 2000;
  } catch (error) {
    log('relay_bridge_error', { error: String(error?.message || error).slice(0, 1800), retryMs: backoff });
    await new Promise((resolve) => setTimeout(resolve, backoff));
    backoff = Math.min(backoff * 2, 60000);
  }
}
