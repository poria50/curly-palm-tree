create unique index scenarios_unique_name on public.scenarios(project_id, lower(btrim(name)));
