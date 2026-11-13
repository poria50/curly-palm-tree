alter table public.profiles add column username text unique;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  insert into public.profiles(id,email,display_name,username)
  values (new.id, new.email,
          coalesce(nullif(new.raw_user_meta_data->>'display_name',''), split_part(new.email,'@',1)),
          case when new.email like '%@fleet.local' then split_part(new.email,'@',1) end);
  insert into public.project_members(project_id,user_id,role)
    select project_id, new.id, role from public.project_invites where lower(email)=lower(new.email)
    on conflict do nothing;
  delete from public.project_invites where lower(email)=lower(new.email);
  -- Simple mode: anyone who registers joins the first project as editor
  if not exists(select 1 from public.project_members where user_id=new.id) then
    insert into public.project_members(project_id,user_id,role)
      select id, new.id, 'editor' from public.projects order by created_at limit 1;
  end if;
  return new;
end $$;

create function public.register_user(p_username text, p_password text, p_display text default '')
returns void language plpgsql security definer set search_path='' as $$
declare u text := lower(trim(p_username)); uid uuid := gen_random_uuid(); em text;
begin
  if u is null or u !~ '^[a-z0-9._-]{2,30}$' then raise exception 'invalid_username'; end if;
  if coalesce(length(p_password),0) < 1 then raise exception 'invalid_password'; end if;
  em := u || '@fleet.local';
  if exists(select 1 from auth.users where lower(email)=em) then raise exception 'username_taken'; end if;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
     raw_app_meta_data,raw_user_meta_data,created_at,updated_at,
     confirmation_token,recovery_token,email_change_token_new,email_change,phone_change,phone_change_token,email_change_token_current,reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated',em,
     extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     jsonb_build_object('display_name', coalesce(nullif(trim(p_display),''), u)),
     now(), now(), '', '', '', '', '', '', '', '');
  insert into auth.identities(user_id,provider_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
  values (uid, uid::text, jsonb_build_object('sub',uid::text,'email',em,'email_verified',true), 'email', now(), now(), now());
end $$;
revoke all on function public.register_user(text,text,text) from public;
grant execute on function public.register_user(text,text,text) to anon, authenticated;
