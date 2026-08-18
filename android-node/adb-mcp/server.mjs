import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const execFileAsync = promisify(execFile);
const ADB = process.env.ADB_BIN || 'adb';
const SERIAL = process.env.ANDROID_SERIAL || '';
const WRITE_ENABLED = process.env.PHONE_WRITE_ENABLED === '1';

// Production actions are task-specific. Telegram, browsers, arbitrary URLs,
// coordinates and free-form text input are intentionally not exposed.
const BRIDGE_APPS = Object.freeze({
  openclaw: 'ai.openclaw.app',
  termux: 'com.termux',
});

const READ_ONLY = Object.freeze({
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
});
const BOUNDED_WRITE = Object.freeze({
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false,
});

function adbArgs(args) {
  return SERIAL ? ['-s', SERIAL, ...args] : args;
}

async function runAdb(args, options = {}) {
  const { stdout, stderr } = await execFileAsync(ADB, adbArgs(args), {
    timeout: options.timeout ?? 15000,
    maxBuffer: options.maxBuffer ?? 1024 * 1024,
    encoding: 'utf8',
    windowsHide: true,
  });
  return { stdout: stdout ?? '', stderr: stderr ?? '' };
}

async function runAdbBuffer(args, options = {}) {
  return await new Promise((resolve, reject) => {
    const child = execFile(
      ADB,
      adbArgs(args),
      {
        timeout: options.timeout ?? 15000,
        maxBuffer: options.maxBuffer ?? 8 * 1024 * 1024,
        encoding: 'buffer',
        windowsHide: true,
      },
      (error, stdout, stderr) => {
        if (error) {
          const detail = Buffer.isBuffer(stderr) ? stderr.toString('utf8') : String(stderr ?? '');
          reject(new Error(detail.trim() || error.message));
          return;
        }
        resolve(Buffer.isBuffer(stdout) ? stdout : Buffer.from(stdout ?? ''));
      },
    );
    child.on('error', reject);
  });
}

async function requireDevice() {
  const { stdout } = await runAdb(['get-state'], { timeout: 5000 });
  if (stdout.trim() !== 'device') {
    throw new Error(`Android device is not ready: ${stdout.trim() || 'unknown state'}`);
  }
}

function textResult(value, isError = false) {
  return {
    content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }],
    ...(isError ? { isError: true } : {}),
  };
}

function guarded(handler) {
  return async (args) => {
    try {
      await requireDevice();
      return await handler(args ?? {});
    } catch (error) {
      return textResult(`PHONE_BRIDGE_ERROR: ${error instanceof Error ? error.message : String(error)}`, true);
    }
  };
}

function requireWrite() {
  if (!WRITE_ENABLED) {
    throw new Error('Write actions are disabled for this MCP registration.');
  }
}

const server = new McpServer({
  name: 'openclaw-android-adb-safe',
  version: '1.2.0',
});

server.registerTool(
  'phone_status',
  {
    title: 'Android phone status',
    description: 'Read connection, model, Android version, battery, display and current activity. No side effects.',
    inputSchema: {},
    annotations: READ_ONLY,
  },
  guarded(async () => {
    const [model, version, battery, size, activity] = await Promise.all([
      runAdb(['shell', 'getprop', 'ro.product.model']),
      runAdb(['shell', 'getprop', 'ro.build.version.release']),
      runAdb(['shell', 'dumpsys', 'battery']),
      runAdb(['shell', 'wm', 'size']),
      runAdb(['shell', 'dumpsys', 'activity', 'activities'], { maxBuffer: 4 * 1024 * 1024 }),
    ]);
    const resumed = activity.stdout
      .split('\n')
      .find((line) => line.includes('mResumedActivity') || line.includes('topResumedActivity'))
      ?.trim();
    return textResult({
      serial: SERIAL || 'auto',
      model: model.stdout.trim(),
      android: version.stdout.trim(),
      display: size.stdout.trim(),
      battery: battery.stdout.trim(),
      resumedActivity: resumed || null,
      writeEnabled: WRITE_ENABLED,
      productionActions: ['phone_open_bridge_app', 'phone_key'],
    });
  }),
);

server.registerTool(
  'phone_screenshot',
  {
    title: 'Android screenshot',
    description: 'Capture the current Android screen as PNG. Read-only but may contain private on-screen information.',
    inputSchema: {},
    annotations: READ_ONLY,
  },
  guarded(async () => {
    const png = await runAdbBuffer(['exec-out', 'screencap', '-p'], { timeout: 20000 });
    if (png.length < 100 || png.length > 8 * 1024 * 1024) {
      throw new Error(`Unexpected screenshot size: ${png.length}`);
    }
    return { content: [{ type: 'image', data: png.toString('base64'), mimeType: 'image/png' }] };
  }),
);

server.registerTool(
  'phone_ui_dump',
  {
    title: 'Android UI hierarchy',
    description: 'Read the current UIAutomator XML hierarchy. Read-only but may contain private on-screen text.',
    inputSchema: {},
    annotations: READ_ONLY,
  },
  guarded(async () => {
    await runAdb(['shell', 'uiautomator', 'dump', '/sdcard/window.xml'], { timeout: 20000 });
    const { stdout } = await runAdb(['exec-out', 'cat', '/sdcard/window.xml'], {
      timeout: 10000,
      maxBuffer: 2 * 1024 * 1024,
    });
    await runAdb(['shell', 'rm', '-f', '/sdcard/window.xml']).catch(() => {});
    return textResult(stdout.slice(0, 200000));
  }),
);

server.registerTool(
  'phone_open_bridge_app',
  {
    title: 'Open an approved bridge app',
    description: 'Launch only the official OpenClaw app or Termux. Telegram, browser, settings and arbitrary packages are denied.',
    inputSchema: { app: z.enum(['openclaw', 'termux']) },
    annotations: BOUNDED_WRITE,
  },
  guarded(async ({ app }) => {
    requireWrite();
    const packageName = BRIDGE_APPS[app];
    if (!packageName) throw new Error(`Unsupported bridge app: ${app}`);
    const { stdout, stderr } = await runAdb([
      'shell',
      'monkey',
      '-p',
      packageName,
      '-c',
      'android.intent.category.LAUNCHER',
      '1',
    ]);
    return textResult({ app, packageName, stdout: stdout.trim(), stderr: stderr.trim() });
  }),
);

server.registerTool(
  'phone_key',
  {
    title: 'Send a bounded Android navigation key',
    description: 'Send only HOME, BACK, WAKEUP or SLEEP. All other key events are denied.',
    inputSchema: { key: z.enum(['HOME', 'BACK', 'WAKEUP', 'SLEEP']) },
    annotations: BOUNDED_WRITE,
  },
  guarded(async ({ key }) => {
    requireWrite();
    await runAdb(['shell', 'input', 'keyevent', `KEYCODE_${key}`]);
    return textResult({ ok: true, key });
  }),
);

const transport = new StdioServerTransport();
await server.connect(transport);
