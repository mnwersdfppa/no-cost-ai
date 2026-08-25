import os from "node:os";
import path from "node:path";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import type { CliBackendPlugin } from "openclaw/plugin-sdk/cli-backend";

function buildPhoneCodexBackend(): CliBackendPlugin {
  const command =
    process.env.PHONE_CODEX_WRAPPER ||
    path.join(os.homedir(), ".openclaw", "bin", "phone-codex-cli-backend");

  return {
    id: "phone-codex-cli",
    liveTest: {
      defaultModelRef: "phone-codex-cli/gpt-5.6-sol",
      defaultImageProbe: false,
      defaultMcpProbe: false,
    },
    nativeToolMode: "none",
    sideQuestionToolMode: "disabled",
    config: {
      command,
      args: [],
      output: "text",
      input: "stdin",
      modelArg: "--model",
      modelAliases: {
        "gpt-5.6": "gpt-5.6",
        "gpt-5.6-sol": "gpt-5.6-sol",
      },
      sessionMode: "none",
      serialize: true,
      clearEnv: [
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "OPENAI_ORG_ID",
        "OPENAI_PROJECT_ID"
      ],
    },
  };
}

export default definePluginEntry({
  id: "phone-codex-cli",
  name: "Phone Codex CLI",
  description: "Route OpenClaw text inference through a constrained Codex CLI session on a USB-connected phone",
  register(api) {
    api.registerCliBackend(buildPhoneCodexBackend());
  },
});
