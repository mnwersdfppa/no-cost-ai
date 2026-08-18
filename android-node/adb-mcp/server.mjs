import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const execFileAsync = promisify(execFile);
const ADB = process.env.ADB_BIN || 'adb';
const SERIAL = process.env.ANDROID_SERIAL || '';
const WRITE_ENABLED = process.env.PHONE_WRITE_ENABLED === '1';
const MAX_TEXT = 500;
const allowedPackages = new Set(
  (process.env.PHONE_ALLOWED_PACKAGES || 'ai.openclaw.app,com.termux,org.telegram.messenger,com.android.chrome')
    .split(',')
    .map((v) => v.trim())
    .filter(Boolean),
);

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
    throw new Error('Write actions are disabled. Set PHONE_WRITE_ENABLED=1 only after operator approval.');
  }
}

function assertCoordinate(value, name) {
  if (!Number.isInteger(value) || value < 0 || value > 10000) {
    throw new Error(`${name} must be an integer between 0 and 10000`);
  }
}

const server = new McpServer({
  name: 'openclaw-android-adb-safe',
  version: '1.0.0',
});

server.registerTool(
  'phone_status',
  {
    title: 'Android phone status',
    description: 'Read connection, model, Android version, battery, display and current activity. No side effects.',
    inputSchema: {},
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
      allowedPackages: [...allowedPackages],
    });
  }),
);

server.registerTool(
  'phone_screenshot',
  {
    title: 'Android screenshot',
    description: 'Capture the current Android screen as PNG. No side effects.',
    inputSchema: {},
  },
  guarded(async () => {
    const png = await runAdbBuffer(['exec-out', 'screencap', '-p'], { timeout: 20000 });
    if (png.length < 100 || png.length > 8 * 1024 * 1024) {
      throw new Error(`Unexpected screenshot size: ${png.length}`);
    }
    return {
      content: [{ type: 'image', data: png.toString('base64'), mimeType: 'image/png' }],
    };
  }),
);

server.registerTool(
  'phone_ui_dump',
  {
    title: 'Android UI hierarchy',
    description: 'Read the current UIAutomator XML hierarchy. No side effects.',
    inputSchema: {},
  },
  guarded(async () => {
    await runAdb(['shell', 'uiautomator', 'dump', '/sdcard/window.xml'], { timeout: 20000 });
    const { stdout } = await runAdb(['exec-out', 'cat', '/sdcard/window.xml'], {
      timeout: 10000,
      maxBuffer: 2 * 1024 * 1024,
    });
    return textResult(stdout.slice(0, 200000));
  }),
);

server.registerTool(
  'phone_open_app',
  {
    title: 'Open allowlisted Android app',
    description: 'Launch an allowlisted package. Does not install, uninstall, send, purchase or change settings.',
    inputSchema: { packageName: z.string().min(3).max(200) },
  },
  guarded(async ({ packageName }) => {
    requireWrite();
    if (!allowedPackages.has(packageName)) {
      throw new Error(`Package is not allowlisted: ${packageName}`);
    }
    const { stdout, stderr } = await runAdb([
      'shell',
      'monkey',
      '-p',
      packageName,
      '-c',
      'android.intent.category.LAUNCHER',
      '1',
    ]);
    return textResult({ packageName, stdout: stdout.trim(), stderr: stderr.trim() });
  }),
);

server.registerTool(
  'phone_launch_url',
  {
    title: 'Open HTTPS URL on Android',
    description: 'Open an HTTPS URL in the phone browser. Non-HTTPS schemes are denied.',
    inputSchema: { url: z.string().url().max(2000) },
  },
  guarded(async ({ url }) => {
    requireWrite();
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:') {
      throw new Error('Only https:// URLs are allowed');
    }
    const { stdout } = await runAdb([
      'shell',
      'am',
      'start',
      '-W',
      '-a',
      'android.intent.action.VIEW',
      '-d',
      url,
    ]);
    return textResult(stdout.trim());
  }),
);

server.registerTool(
  'phone_key',
  {
    title: 'Send safe Android key',
    description: 'Send HOME, BACK, WAKEUP or SLEEP. Other keys are denied.',
    inputSchema: { key: z.enum(['HOME', 'BACK', 'WAKEUP', 'SLEEP']) },
  },
  guarded(async ({ key }) => {
    requireWrite();
    await runAdb(['shell', 'input', 'keyevent', `KEYCODE_${key}`]);
    return textResult({ ok: true, key });
  }),
);

server.registerTool(
  'phone_tap',
  {
    title: 'Tap Android screen',
    description: 'Tap one coordinate. Disabled unless PHONE_WRITE_ENABLED=1.',
    inputSchema: { x: z.number().int(), y: z.number().int() },
  },
  guarded(async ({ x, y }) => {
    requireWrite();
    assertCoordinate(x, 'x');
    assertCoordinate(y, 'y');
    await runAdb(['shell', 'input', 'tap', String(x), String(y)]);
    return textResult({ ok: true, x, y });
  }),
);

server.registerTool(
  'phone_swipe',
  {
    title: 'Swipe Android screen',
    description: 'Swipe between two coordinates. Disabled unless PHONE_WRITE_ENABLED=1.',
    inputSchema: {
      x1: z.number().int(),
      y1: z.number().int(),
      x2: z.number().int(),
      y2: z.number().int(),
      durationMs: z.number().int().min(50).max(3000).default(300),
    },
  },
  guarded(async ({ x1, y1, x2, y2, durationMs }) => {
    requireWrite();
    for (const [name, value] of Object.entries({ x1, y1, x2, y2 })) assertCoordinate(value, name);
    await runAdb([
      'shell',
      'input',
      'swipe',
      String(x1),
      String(y1),
      String(x2),
      String(y2),
      String(durationMs),
    ]);
    return textResult({ ok: true, x1, y1, x2, y2, durationMs });
  }),
);

server.registerTool(
  'phone_type_text',
  {
    title: 'Type restricted ASCII text on Android',
    description: 'Type short ASCII text into the focused field. Newlines, shell metacharacters and Unicode are denied.',
    inputSchema: { text: z.string().min(1).max(MAX_TEXT) },
  },
  guarded(async ({ text }) => {
    requireWrite();
    if (!/^[A-Za-z0-9 .,!?_@:/+\-=()]+$/.test(text)) {
      throw new Error('Text contains unsupported characters; only restricted ASCII is allowed');
    }
    const encoded = text.replaceAll('%', '%25').replaceAll(' ', '%s');
    await runAdb(['shell', 'input', 'text', encoded]);
    return textResult({ ok: true, length: text.length });
  }),
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
