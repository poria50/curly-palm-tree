-- Types
create type public.member_role as enum ('owner','admin','editor','viewer');
create type public.scenario_visibility as enum ('private','team','official');

-- Tables
create table public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text not null default '',
  created_at timestamptz not null default now()
);

create table public.projects(
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 200),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.project_members(
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.member_role not null default 'editor',
  created_at timestamptz not null default now(),
  primary key(project_id,user_id)
);
create index project_members_user_idx on public.project_members(user_id);

create table public.project_invites(
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  email text not null,
  role public.member_role not null default 'editor',
  invited_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique(project_id,email)
);

create table public.scenarios(
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 200),
  notes text not null default '',
  owner_id uuid not null default auth.uid() references public.profiles(id),
  visibility public.scenario_visibility not null default 'private',
  model jsonb not null,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);
create index scenarios_project_idx on public.scenarios(project_id);
create unique index scenarios_one_official on public.scenarios(project_id) where visibility='official';

create table public.scenario_versions(
  id uuid primary key default gen_random_uuid(),
  scenario_id uuid not null references public.scenarios(id) on delete cascade,
  version_no int not null,
  note text not null default '',
  model jsonb not null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique(scenario_id,version_no)
);

create table public.activity_log(
  id bigint generated always as identity primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  scenario_id uuid references public.scenarios(id) on delete set null,
  user_id uuid not null default auth.uid() references public.profiles(id),
  action text not null check (action in ('edit','src','create','version','restore','add','remove','delete','member')),
  path text,
  old_value jsonb,
  new_value jsonb,
  detail text,
  created_at timestamptz not null default now()
);
create index activity_project_idx on public.activity_log(project_id, created_at desc);
create index activity_scenario_idx on public.activity_log(scenario_id);
create index activity_user_idx on public.activity_log(user_id);
create index versions_creator_idx on public.scenario_versions(created_by);
create index scenarios_owner_idx on public.scenarios(owner_id);
create index scenarios_updated_by_idx on public.scenarios(updated_by);
create index projects_created_by_idx on public.projects(created_by);
create index invites_invited_by_idx on public.project_invites(invited_by);

-- Helper functions (security definer, fixed search_path)
create function public.project_role(p uuid) returns public.member_role
language sql stable security definer set search_path='' as $$
  select role from public.project_members where project_id=p and user_id=(select auth.uid())
$$;

create function public.is_member(p uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.project_members where project_id=p and user_id=(select auth.uid()))
$$;

create function public.shares_project(other uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.project_members a join public.project_members b on a.project_id=b.project_id
                where a.user_id=(select auth.uid()) and b.user_id=other)
$$;

create function public.can_view_scenario(s uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.scenarios sc join public.project_members m
                on m.project_id=sc.project_id and m.user_id=(select auth.uid())
                where sc.id=s and (sc.visibility<>'private' or sc.owner_id=(select auth.uid())))
$$;

create function public.can_edit_scenario(s uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.scenarios sc join public.project_members m
                on m.project_id=sc.project_id and m.user_id=(select auth.uid())
                where sc.id=s and m.role<>'viewer'
                  and (sc.owner_id=(select auth.uid()) or (sc.visibility='official' and m.role in ('owner','admin'))))
$$;

-- Triggers
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  insert into public.profiles(id,email,display_name)
  values (new.id, new.email, coalesce(nullif(new.raw_user_meta_data->>'display_name',''), split_part(new.email,'@',1)));
  insert into public.project_members(project_id,user_id,role)
    select project_id, new.id, role from public.project_invites where lower(email)=lower(new.email)
    on conflict do nothing;
  delete from public.project_invites where lower(email)=lower(new.email);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create function public.touch_scenario() returns trigger
language plpgsql set search_path='' as $$
begin
  new.updated_at := now();
  new.updated_by := (select auth.uid());
  if new.owner_id is distinct from old.owner_id then
    raise exception 'owner cannot be changed';
  end if;
  return new;
end $$;
create trigger scenarios_touch before update on public.scenarios for each row execute function public.touch_scenario();

-- RPCs
create function public.create_project(p_name text) returns uuid
language plpgsql security definer set search_path='' as $$
declare pid uuid; uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'not authenticated'; end if;
  insert into public.projects(name,created_by) values (p_name, uid) returning id into pid;
  insert into public.project_members(project_id,user_id,role) values (pid, uid, 'owner');
  return pid;
end $$;

create function public.add_member(p_project uuid, p_email text, p_role public.member_role) returns text
language plpgsql security definer set search_path='' as $$
declare caller public.member_role := public.project_role(p_project); target uuid;
begin
  if caller is null or caller not in ('owner','admin') then raise exception 'only owners and admins can add members'; end if;
  if p_role='owner' and caller<>'owner' then raise exception 'only owners can add owners'; end if;
  select id into target from auth.users where lower(email)=lower(trim(p_email));
  if target is not null then
    insert into public.project_members(project_id,user_id,role) values (p_project,target,p_role)
      on conflict (project_id,user_id) do update set role=excluded.role;
    insert into public.activity_log(project_id,user_id,action,detail) values (p_project,(select auth.uid()),'member',lower(trim(p_email))||':'||p_role);
    return 'added';
  else
    insert into public.project_invites(project_id,email,role,invited_by) values (p_project,lower(trim(p_email)),p_role,(select auth.uid()))
      on conflict (project_id,email) do update set role=excluded.role;
    insert into public.activity_log(project_id,user_id,action,detail) values (p_project,(select auth.uid()),'member',lower(trim(p_email))||':'||p_role||':invited');
    return 'invited';
  end if;
end $$;

create function public.save_scenario_version(p_scenario uuid, p_note text default '') returns int
language plpgsql security definer set search_path='' as $$
declare s public.scenarios; n int;
begin
  if not public.can_edit_scenario(p_scenario) then raise exception 'not allowed'; end if;
  select * into s from public.scenarios where id=p_scenario for update;
  select coalesce(max(version_no),0)+1 into n from public.scenario_versions where scenario_id=p_scenario;
  insert into public.scenario_versions(scenario_id,version_no,note,model,created_by)
    values (p_scenario,n,coalesce(p_note,''),s.model,(select auth.uid()));
  insert into public.activity_log(project_id,scenario_id,user_id,action,new_value,detail)
    values (s.project_id,p_scenario,(select auth.uid()),'version',to_jsonb(n),p_note);
  return n;
end $$;

create function public.restore_scenario_version(p_scenario uuid, p_version int) returns void
language plpgsql security definer set search_path='' as $$
declare v public.scenario_versions; pid uuid;
begin
  if not public.can_edit_scenario(p_scenario) then raise exception 'not allowed'; end if;
  select * into v from public.scenario_versions where scenario_id=p_scenario and version_no=p_version;
  if v.id is null then raise exception 'version not found'; end if;
  update public.scenarios set model=v.model where id=p_scenario returning project_id into pid;
  insert into public.activity_log(project_id,scenario_id,user_id,action,new_value)
    values (pid,p_scenario,(select auth.uid()),'restore',to_jsonb(p_version));
end $$;

-- RLS
alter table public.profiles enable row level security;
alter table public.projects enable row level security;
alter table public.project_members enable row level security;
alter table public.project_invites enable row level security;
alter table public.scenarios enable row level security;
alter table public.scenario_versions enable row level security;
alter table public.activity_log enable row level security;

create policy profiles_select on public.profiles for select to authenticated
  using (id=(select auth.uid()) or public.shares_project(id));
create policy profiles_update on public.profiles for update to authenticated
  using (id=(select auth.uid())) with check (id=(select auth.uid()));

create policy projects_select on public.projects for select to authenticated using (public.is_member(id));
create policy projects_update on public.projects for update to authenticated
  using (public.project_role(id) in ('owner','admin')) with check (public.project_role(id) in ('owner','admin'));
create policy projects_delete on public.projects for delete to authenticated using (public.project_role(id)='owner');

create policy members_select on public.project_members for select to authenticated using (public.is_member(project_id));
create policy members_update on public.project_members for update to authenticated
  using (public.project_role(project_id)='owner' or (public.project_role(project_id)='admin' and role<>'owner'))
  with check (role<>'owner' or public.project_role(project_id)='owner');
create policy members_delete on public.project_members for delete to authenticated
  using (user_id<>(select auth.uid()) and (public.project_role(project_id)='owner' or (public.project_role(project_id)='admin' and role<>'owner')));

create policy invites_select on public.project_invites for select to authenticated using (public.project_role(project_id) in ('owner','admin'));
create policy invites_delete on public.project_invites for delete to authenticated using (public.project_role(project_id) in ('owner','admin'));

create policy scenarios_select on public.scenarios for select to authenticated
  using (public.is_member(project_id) and (visibility<>'private' or owner_id=(select auth.uid())));
create policy scenarios_insert on public.scenarios for insert to authenticated
  with check (owner_id=(select auth.uid()) and public.project_role(project_id) in ('owner','admin','editor')
              and (visibility<>'official' or public.project_role(project_id) in ('owner','admin')));
create policy scenarios_update on public.scenarios for update to authenticated
  using (public.project_role(project_id)<>'viewer' and (owner_id=(select auth.uid()) or (visibility='official' and public.project_role(project_id) in ('owner','admin'))))
  with check (public.project_role(project_id)<>'viewer' and (visibility<>'official' or public.project_role(project_id) in ('owner','admin')));
create policy scenarios_delete on public.scenarios for delete to authenticated
  using (owner_id=(select auth.uid()) and visibility<>'official' and public.project_role(project_id)<>'viewer');

create policy versions_select on public.scenario_versions for select to authenticated using (public.can_view_scenario(scenario_id));

create policy activity_select on public.activity_log for select to authenticated
  using (public.is_member(project_id) and (scenario_id is null or public.can_view_scenario(scenario_id)));
create policy activity_insert on public.activity_log for insert to authenticated
  with check (user_id=(select auth.uid()) and public.project_role(project_id)<>'viewer');

-- Privileges: nothing for anon
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon, public;
grant execute on function public.project_role(uuid), public.is_member(uuid), public.shares_project(uuid),
  public.can_view_scenario(uuid), public.can_edit_scenario(uuid), public.create_project(text),
  public.add_member(uuid,text,public.member_role), public.save_scenario_version(uuid,text),
  public.restore_scenario_version(uuid,int) to authenticated;
revoke execute on function public.handle_new_user() from authenticated;

-- Realtime
alter publication supabase_realtime add table public.scenarios, public.activity_log, public.project_members;
