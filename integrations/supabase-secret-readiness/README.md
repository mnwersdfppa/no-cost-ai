# Supabase secret readiness probe — staged only

This Edge Function is intentionally **not deployed by this PR**. It is a read-only readiness probe for a later reviewed deployment with `verify_jwt=true`.

It accepts only a Supabase user JWT whose `app_metadata.role` is `pi-gateway-client` and returns booleans for a fixed allowlist of secret names. It never returns values, prefixes, hashes, lengths or authorization headers.

Expected deployment setting:

```toml
[functions.secret-readiness]
verify_jwt = true
```

This probe does not make Supabase secrets available to Raspberry Pi processes. It only confirms hosted Edge Function readiness. Maton on the Pi still requires a Pi-local SecretRef or a separately reviewed server-side proxy.

Activation remains blocked until an operator approves a specific deployment commit and verifies that the function URL is not public without JWT enforcement.
