# LangSmith OAuth handoff

The OpenClaw external runtime accepts either:

1. `LANGSMITH_API_KEY` for a PAT or service key; or
2. an official LangSmith CLI OAuth profile stored in Supabase Vault and delivered to GitHub Actions through exact-claim GitHub OIDC.

The OAuth route is used when an account API key has not been created. The only interactive provider step is:

```powershell
langsmith auth login --profile openclaw
```

After enrollment:

- `%USERPROFILE%\.langsmith\config.json` remains restricted to the Windows user;
- the refreshable profile is copied into Supabase Vault through a single-use capability;
- GitHub Actions receives it only through a short-lived OIDC identity bound to the exact repository and workflow;
- the runner writes it to an ephemeral `0600` file and deletes it with the hosted runner;
- no long-lived LangSmith credential is committed to GitHub or stored as an ordinary repository secret;
- the relay sends only bounded, secret-free OpenClaw control metadata to `openclaw-external-orchestrator`.

The generic `OAuth-key`, Google API keys, Cloud API keys, and Windows credentials cannot be substituted for a LangSmith credential. OAuth artifacts are bound to their issuer, client, audience, scopes, account, and expiry policy.

## Rollback

Disable `.github/workflows/external-langsmith-trace-relay.yml` and mark the `langsmith_oauth_profile` secret reference inactive. The Supabase structured fallback trace remains available independently.
