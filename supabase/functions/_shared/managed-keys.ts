export function managedAdminKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (typeof keys?.default === "string" && keys.default.startsWith("sb_secret_")) {
      return keys.default;
    }
  } catch {
    // Compatibility fallback below.
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

export function managedPublishableKey(): string | null {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}");
    return typeof keys?.default === "string" && keys.default.startsWith("sb_publishable_")
      ? keys.default
      : null;
  } catch {
    return null;
  }
}
