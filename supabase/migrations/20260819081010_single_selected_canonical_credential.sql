-- Prevent ambiguous credential selection while retaining compatibility rows.

create unique index if not exists bridge_canonical_credentials_one_selected_uidx
  on public.bridge_canonical_credentials (canonical_integration)
  where selected = true;

comment on index public.bridge_canonical_credentials_one_selected_uidx is
  'At most one selected credential alias per canonical integration.';
