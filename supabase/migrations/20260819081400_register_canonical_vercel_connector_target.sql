insert into public.bridge_route_registry(
  route_key,integration,route_type,endpoint_alias,endpoint_url,mode,
  priority,enabled,health_status,last_checked_at,notes
) values (
  'vercel.connector_management',
  'vercel_connector',
  'connector',
  'mnwersdfppap-5454s-projects',
  null,
  'read_only',
  90,
  true,
  'degraded',
  now(),
  'Canonical Vercel management team: team_sa2sEffAlVXK6b9lsweDm6QL. Connector authentication is selected; no deployment target project is validated, so vercel_deployments remains OFF.'
)
on conflict(route_key) do update set
  integration=excluded.integration,
  route_type=excluded.route_type,
  endpoint_alias=excluded.endpoint_alias,
  mode='read_only',
  priority=excluded.priority,
  enabled=true,
  health_status='degraded',
  last_checked_at=now(),
  notes=excluded.notes,
  updated_at=now();

update public.bridge_capability_registry
set available=true,
    validated=false,
    default_enabled=false,
    credential_export_allowed=false,
    notes='Connected Vercel management session selected for team team_sa2sEffAlVXK6b9lsweDm6QL / mnwersdfppap-5454s-projects. Deployment remains blocked until a target project is visible and explicitly validated.',
    updated_at=now()
where capability_key='vercel.connector';

update public.bridge_controls
set enabled=false,
    fail_closed=true,
    reason='Canonical connector team selected; deployment target project is not validated.',
    updated_by='migration',
    updated_at=now()
where control_key='vercel_deployments';
