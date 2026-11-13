create table public.trip_logs(
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  started_at timestamptz not null,
  truck text not null check (char_length(truck) between 1 and 60),
  driver text not null default '',
  route_id text,
  route_name text,
  planned_km numeric,
  odo_start numeric not null check (odo_start >= 0),
  odo_end numeric not null,
  km numeric generated always as (odo_end - odo_start) stored,
  tons numeric check (tons is null or tons >= 0),
  price numeric not null default 0 check (price >= 0),
  fuel_l numeric check (fuel_l is null or fuel_l >= 0),
  note text not null default '',
  created_by uuid not null default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  check (odo_end > odo_start)
);
create index trip_logs_project_time_idx on public.trip_logs(project_id, started_at desc);
create index trip_logs_truck_idx on public.trip_logs(project_id, truck, started_at);
create index trip_logs_creator_idx on public.trip_logs(created_by);

alter table public.trip_logs enable row level security;
create policy trip_logs_select on public.trip_logs for select to authenticated using (public.is_member(project_id));
create policy trip_logs_insert on public.trip_logs for insert to authenticated
  with check (created_by = (select auth.uid()) and public.project_role(project_id) in ('owner','admin','editor'));
create policy trip_logs_update on public.trip_logs for update to authenticated
  using ((created_by = (select auth.uid()) and public.project_role(project_id) <> 'viewer') or public.project_role(project_id) in ('owner','admin'))
  with check (public.project_role(project_id) <> 'viewer');
create policy trip_logs_delete on public.trip_logs for delete to authenticated
  using ((created_by = (select auth.uid()) and public.project_role(project_id) <> 'viewer') or public.project_role(project_id) in ('owner','admin'));
revoke all on public.trip_logs from anon;
alter publication supabase_realtime add table public.trip_logs;
