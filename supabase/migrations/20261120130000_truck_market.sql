-- Truck market: candidates, votes, comments (see Supabase project for the applied version)
create table public.truck_candidates(
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  title text not null check (char_length(title) between 2 and 120),
  model text not null default '', year int check (year is null or year between 1980 and 2100),
  km numeric check (km is null or km >= 0), price numeric not null default 0 check (price >= 0),
  currency text not null default 'EUR' check (currency in ('OMR','EUR','USD','NOK')),
  trailer_price numeric not null default 0 check (trailer_price >= 0), ship numeric not null default 0 check (ship >= 0),
  duty numeric not null default 5 check (duty >= 0 and duty <= 100), reg numeric not null default 0 check (reg >= 0),
  country text not null default '', seller text not null default '', url text check (url is null or url ~* '^https?://'),
  axle text not null default '', euro text not null default '', gearbox text not null default '', hp int check (hp is null or hp between 50 and 1000),
  status text not null default 'interesting' check (status in ('interesting','contacted','inspected','rejected','bought')),
  notes text not null default '', checklist jsonb not null default '{}'::jsonb,
  created_by uuid not null default auth.uid() references public.profiles(id), created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(), updated_by uuid references public.profiles(id)
);
create index truck_candidates_project_idx on public.truck_candidates(project_id, created_at desc);
create index truck_candidates_creator_idx on public.truck_candidates(created_by);
create index truck_candidates_updater_idx on public.truck_candidates(updated_by);
create function public.touch_candidate() returns trigger language plpgsql set search_path='' as $$
begin new.updated_at := now(); new.updated_by := (select auth.uid()); new.created_by := old.created_by; new.project_id := old.project_id; return new; end $$;
create trigger truck_candidates_touch before update on public.truck_candidates for each row execute function public.touch_candidate();
create table public.candidate_votes(candidate_id uuid not null references public.truck_candidates(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade, vote smallint not null check (vote in (-1,1)),
  created_at timestamptz not null default now(), primary key(candidate_id,user_id));
create index candidate_votes_user_idx on public.candidate_votes(user_id);
create table public.candidate_comments(id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.truck_candidates(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000), created_at timestamptz not null default now());
create index candidate_comments_cand_idx on public.candidate_comments(candidate_id, created_at);
create index candidate_comments_user_idx on public.candidate_comments(user_id);
create function public.candidate_project(c uuid) returns uuid language sql stable security definer set search_path='' as $$ select project_id from public.truck_candidates where id=c $$;
revoke execute on function public.candidate_project(uuid) from anon, public;
grant execute on function public.candidate_project(uuid) to authenticated;
alter table public.truck_candidates enable row level security;
alter table public.candidate_votes enable row level security;
alter table public.candidate_comments enable row level security;
create policy cand_select on public.truck_candidates for select to authenticated using (public.is_member(project_id));
create policy cand_insert on public.truck_candidates for insert to authenticated with check (created_by=(select auth.uid()) and public.project_role(project_id) in ('owner','admin','editor'));
create policy cand_update on public.truck_candidates for update to authenticated using (public.project_role(project_id) in ('owner','admin','editor')) with check (public.project_role(project_id) in ('owner','admin','editor'));
create policy cand_delete on public.truck_candidates for delete to authenticated using ((created_by=(select auth.uid()) and public.project_role(project_id)<>'viewer') or public.project_role(project_id) in ('owner','admin'));
create policy votes_select on public.candidate_votes for select to authenticated using (public.is_member(public.candidate_project(candidate_id)));
create policy votes_insert on public.candidate_votes for insert to authenticated with check (user_id=(select auth.uid()) and public.is_member(public.candidate_project(candidate_id)));
create policy votes_update on public.candidate_votes for update to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
create policy votes_delete on public.candidate_votes for delete to authenticated using (user_id=(select auth.uid()));
create policy comments_select on public.candidate_comments for select to authenticated using (public.is_member(public.candidate_project(candidate_id)));
create policy comments_insert on public.candidate_comments for insert to authenticated with check (user_id=(select auth.uid()) and public.is_member(public.candidate_project(candidate_id)));
create policy comments_delete on public.candidate_comments for delete to authenticated using (user_id=(select auth.uid()) or public.project_role(public.candidate_project(candidate_id)) in ('owner','admin'));
revoke all on public.truck_candidates, public.candidate_votes, public.candidate_comments from anon;
alter publication supabase_realtime add table public.truck_candidates, public.candidate_votes, public.candidate_comments;
