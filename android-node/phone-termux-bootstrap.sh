#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

STATE="$HOME/.openclaw-phone"
BIN="$HOME/.local/bin"
PUB_CANDIDATE_1="$HOME/storage/downloads/openclaw_pi.pub"
PUB_CANDIDATE_2="/sdcard/Download/openclaw_pi.pub"
INSTALL_CODEX="${INSTALL_CODEX:-1}"

mkdir -p "$STATE/codex-home" "$STATE/work" "$BIN" "$HOME/.ssh" "$HOME/.termux/boot"
chmod 700 "$STATE" "$STATE/codex-home" "$STATE/work" "$BIN" "$HOME/.ssh" "$HOME/.termux/boot"

if command -v pkg >/dev/null 2>&1; then
  pkg update -y || true
  pkg install -y openssh python nodejs-lts coreutils || pkg install -y openssh python nodejs coreutils
fi

if [[ ! -e "$HOME/storage/downloads" ]] && command -v termux-setup-storage >/dev/null 2>&1; then
  termux-setup-storage || true
  sleep 2
fi

cat > "$BIN/openclaw-phone-codex-run" <<'PY'
#!/data/data/com.termux/files/usr/bin/python
import json
import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

MAX_PROMPT = int(os.environ.get("PHONE_CODEX_MAX_PROMPT", "12000"))
TIMEOUT = int(os.environ.get("PHONE_CODEX_TIMEOUT_SECONDS", "220"))
ALLOWED_MODELS = {"gpt-5.6-sol", "gpt-5.6"}

raw = sys.stdin.readline(MAX_PROMPT * 2 + 4096)
try:
    request = json.loads(raw)
except Exception as exc:
    print(json.dumps({"type": "error", "message": f"invalid request: {exc}"}))
    sys.exit(2)

prompt = request.get("prompt")
model = request.get("model", "gpt-5.6-sol")
if not isinstance(prompt, str) or not (1 <= len(prompt) <= MAX_PROMPT):
    print(json.dumps({"type": "error", "message": "prompt length denied"}))
    sys.exit(2)
if model not in ALLOWED_MODELS:
    print(json.dumps({"type": "error", "message": "model denied"}))
    sys.exit(2)

codex = shutil.which("codex")
if not codex:
    print(json.dumps({"type": "error", "message": "codex CLI not installed"}))
    sys.exit(127)

state = Path.home() / ".openclaw-phone"
codex_home = state / "codex-home"
workdir = state / "work"
codex_home.mkdir(parents=True, exist_ok=True)
workdir.mkdir(parents=True, exist_ok=True)
os.chmod(codex_home, 0o700)
os.chmod(workdir, 0o500)

source_auth = Path.home() / ".codex" / "auth.json"
target_auth = codex_home / "auth.json"
if source_auth.exists() and not target_auth.exists():
    try:
        target_auth.symlink_to(source_auth)
    except FileExistsError:
        pass

safe_config = codex_home / "config.toml"
safe_config.write_text('model = "gpt-5.6-sol"\n', encoding="utf-8")
os.chmod(safe_config, 0o600)

def help_text(args):
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=15)
        return (proc.stdout or "") + (proc.stderr or "")
    except Exception:
        return ""

help_out = help_text([codex, "exec", "--help"])
args = [codex, "exec", "--skip-git-repo-check", "--color", "never", "-C", str(workdir), "-m", model]
if "--ephemeral" in help_out:
    args.append("--ephemeral")
if "--json" in help_out:
    args.append("--json")
if "--sandbox" in help_out:
    args += ["--sandbox", "read-only"]
if "--ask-for-approval" in help_out:
    args += ["--ask-for-approval", "never"]
if "--ignore-rules" in help_out:
    args.append("--ignore-rules")
if "--ignore-user-config" in help_out:
    args.append("--ignore-user-config")
args.append("-")

instruction = (
    "You are answering a general user question through a constrained phone bridge. "
    "Do not run shell commands, do not modify files, do not use MCP tools, and do not request secrets. "
    "Return only the useful final answer.\n\nUSER REQUEST:\n" + prompt
)
env = os.environ.copy()
for name in ("OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID"):
    env.pop(name, None)
env["CODEX_HOME"] = str(codex_home)

proc = subprocess.Popen(
    args,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=env,
    start_new_session=True,
)
try:
    stdout, stderr = proc.communicate(instruction, timeout=TIMEOUT)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    stdout, stderr = proc.communicate()
    print(json.dumps({"type": "error", "message": "codex timeout"}))
    sys.exit(124)

if stdout:
    sys.stdout.write(stdout)
if stderr:
    sys.stderr.write(stderr)
if proc.returncode != 0:
    sys.exit(proc.returncode)

fatal = False
for line in stdout.splitlines():
    try:
        event = json.loads(line)
    except Exception:
        continue
    if event.get("type") in {"error", "turn.failed"}:
        fatal = True
if fatal:
    sys.exit(70)
PY
chmod 700 "$BIN/openclaw-phone-codex-run"

cat > "$BIN/openclaw-phone-ssh-dispatch" <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
case "${SSH_ORIGINAL_COMMAND:-}" in
  phone-status)
    printf 'user=%s\n' "$(id -un)"
    command -v codex || true
    codex --version 2>/dev/null || true
    codex login status 2>/dev/null || true
    [[ -x "$HOME/.local/bin/openclaw-phone-codex-run" ]] && echo runner=ready || echo runner=missing
    ;;
  phone-codex-run)
    exec "$HOME/.local/bin/openclaw-phone-codex-run"
    ;;
  *)
    echo "DENIED=COMMAND_NOT_ALLOWLISTED" >&2
    exit 126
    ;;
esac
SH
chmod 700 "$BIN/openclaw-phone-ssh-dispatch"

PUB=""
for candidate in "$PUB_CANDIDATE_1" "$PUB_CANDIDATE_2"; do
  if [[ -r "$candidate" ]]; then
    PUB="$candidate"
    break
  fi
done

if [[ -n "$PUB" ]]; then
  touch "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
  key_line="$(tr -d '\r\n' < "$PUB")"
  if [[ "$key_line" != ssh-ed25519\ * ]]; then
    echo "BLOCKED=INVALID_PI_PUBLIC_KEY"
    exit 3
  fi
  tmp="$HOME/.ssh/authorized_keys.tmp"
  grep -v 'openclaw-pi-phone-bridge' "$HOME/.ssh/authorized_keys" > "$tmp" || true
  printf 'restrict,command="$HOME/.local/bin/openclaw-phone-ssh-dispatch" %s\n' "$key_line" >> "$tmp"
  mv "$tmp" "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
else
  echo "BLOCKED=PI_PUBLIC_KEY_NOT_FOUND"
  echo "EXPECTED=$PUB_CANDIDATE_1"
fi

if [[ "$INSTALL_CODEX" == "1" ]] && ! command -v codex >/dev/null 2>&1; then
  echo "INSTALLING=OFFICIAL_CODEX_CLI"
  npm install -g @openai/codex || true
fi

cat > "$HOME/.termux/boot/openclaw-phone-bridge" <<'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock 2>/dev/null || true
if ! pgrep -x sshd >/dev/null 2>&1; then
  sshd -p 8022
fi
BOOT
chmod 700 "$HOME/.termux/boot/openclaw-phone-bridge"

termux-wake-lock 2>/dev/null || true
if ! pgrep -x sshd >/dev/null 2>&1; then
  sshd -p 8022
fi

printf 'TERMUX_USER=%s\n' "$(id -un)"
printf 'SSHD_PORT=8022\n'
printf 'SSH_POLICY=FORCED_COMMAND_ALLOWLIST\n'
if command -v codex >/dev/null 2>&1; then
  codex --version || true
  codex login status || true
  echo "NEXT_IF_NOT_LOGGED_IN=codex login --device-auth"
else
  echo "BLOCKED=OFFICIAL_CODEX_CLI_NOT_EXECUTABLE_ON_THIS_ANDROID"
  echo "POLICY=NO_THIRD_PARTY_CODEX_BINARY_AUTO_INSTALL"
fi

echo "RESULT=PHONE_BOOTSTRAP_READY"
