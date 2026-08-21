update public.bridge_credentials
set validation_status = 'unverified',
    validation_detail = 'Exact Supabase Edge alias is classified as a Tailscale node auth key. Actual expiry, revocation and enrollment usability remain unverified until tailscale up succeeds on the Raspberry Pi.',
    updated_at = now()
where integration = 'tailscale';

update public.bridge_route_registry
set health_status = 'not_tested',
    notes = 'Node auth-key class confirmed; actual key validity and Pi enrollment require a physical tailscale up receipt.',
    updated_at = now()
where route_key = 'tailscale.node_enrollment';
