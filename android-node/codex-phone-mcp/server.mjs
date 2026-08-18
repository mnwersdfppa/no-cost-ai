import { execFile } from 'node:child_process';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const SSH = process.env.SSH_BIN || 'ssh';
const SSH_HOST = process.env.PHONE_SSH_HOST || '127.0.0.1';
const SSH_PORT = process.env.PHONE_SSH_PORT || '8022';
const SSH_USER = process.env.PHONE_SSH_USER || '';
const SSH_KEY = process.env.PHONE_SSH_KEY || `${process.env.HOME}/.openclaw/secrets/phone_ssh_ed25519`;
const CODEX_MODEL = process.env.PHONE_CODEX_MODEL || 'gpt-5.6-sol';
const ENABLED = process.env.PHONE_CODEX_ENABLED === '1';
const MAX_PROMPT = Number(process.env.PHONE_CODEX_MAX_PROMPT || '12000');
const TIMEOUT_MS = Number(process.env.PHONE_CODEX_TIMEOUT_MS || '240000');
const REMOTE_RUNNER = '$HOME/.local/bin/openclaw-phone-codex-run';

function result(value, isError = false) {
  return {
    content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }],
    ...(isError ? { isError: true } : {}),
  };
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

async function runSsh(remoteCommand, stdin = '', timeout = TIMEOUT_MS) {
  return await new Promise((resolve, reject) => {
    const child = execFile(
      SSH,
      sshArgs(remoteCommand),
      {
        timeout,
        maxBuffer: 8 * 1024 * 1024,
        encoding: 'utf8',
        windowsHide: true,
      },
      (error, stdout, stderr) => {
        if (error) {
          const detail = String(stderr || stdout || error.message).trim();
          reject(new Error(detail || error.message));
          return;
        }
        resolve({ stdout: String(stdout || ''), stderr: String(stderr || '') });
      },
    );
    child.stdin.end(stdin);
  });
}

function parseCodexOutput(stdout, stderr) {
  const lines = stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const events = [];
  let finalText = '';
  let fatal = '';

  for (const line of lines) {
    try {
      const event = JSON.parse(line);
      events.push(event);
      const type = String(event.type || '');
      if (type === 'error' || type === 'turn.failed') {
        fatal = event.message || event.error?.message || JSON.stringify(event);
      }
      const item = event.item || event.data?.item;
      if (item?.type === 'agent_message' && typeof item.text === 'string') {
        finalText = item.text;
      }
      if (type === 'turn.completed' && typeof event.final_output === 'string') {
        finalText = event.final_output;
      }
    } catch {
      // Older Codex versions may print only the final answer on stdout.
    }
  }

  if (fatal) throw new Error(`Codex reported failure: ${fatal}`);
  if (!finalText) finalText = stdout.trim();
  if (!finalText) {
    throw new Error(`Codex returned no final text${stderr.trim() ? `: ${stderr.trim().slice(0, 1200)}` : ''}`);
  }
  return { text: finalText, eventCount: events.length };
}

async function guarded(handler) {
  try {
    return await handler();
  } catch (error) {
    return result(`PHONE_CODEX_ERROR: ${error instanceof Error ? error.message : String(error)}`, true);
  }
}

const server = new McpServer({ name: 'openclaw-phone-codex-safe', version: '1.0.0' });

server.registerTool(
  'phone_codex_status',
  {
    title: 'Phone Codex status',
    description: 'Verify the USB/SSH bridge and the already-installed Codex CLI. Does not expose authentication material.',
    inputSchema: {},
  },
  async () => guarded(async () => {
    const { stdout } = await runSsh(
      `printf "user=%s\\n" "$(id -un)"; command -v codex || true; codex --version 2>/dev/null || true; test -x ${REMOTE_RUNNER} && echo runner=ready || echo runner=missing`,
      '',
      30000,
    );
    return result({ enabled: ENABLED, host: SSH_HOST, port: SSH_PORT, model: CODEX_MODEL, remote: stdout.trim() });
  }),
);

server.registerTool(
  'phone_codex_ask',
  {
    title: 'Ask phone Codex in read-only mode',
    description: 'Run one ephemeral, non-interactive, read-only Codex turn through the phone subscription session. No arbitrary remote command is accepted.',
    inputSchema: { prompt: z.string().min(1).max(MAX_PROMPT) },
  },
  async ({ prompt }) => guarded(async () => {
    if (!ENABLED) {
      throw new Error('Phone Codex route is disabled. Set PHONE_CODEX_ENABLED=1 only after the status probe and operator approval pass.');
    }
    const envelope = JSON.stringify({ version: 1, model: CODEX_MODEL, prompt });
    const { stdout, stderr } = await runSsh(REMOTE_RUNNER, `${envelope}\n`, TIMEOUT_MS);
    const parsed = parseCodexOutput(stdout, stderr);
    return result({ provider: 'phone-codex-oauth', model: CODEX_MODEL, answer: parsed.text, eventCount: parsed.eventCount });
  }),
);

const transport = new StdioServerTransport();
await server.connect(transport);
