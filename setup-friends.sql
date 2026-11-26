-- Letters website, step 2: a personal link for each friend, and letters only for the people their writer picks.
-- Run once in Supabase > SQL Editor > New query > Run. Safe to run again. Your old secret code keeps working as YOUR personal code.

create table if not exists public.people (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 60),
  code text not null unique default replace(gen_random_uuid()::text, '-', ''),
  is_owner boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.people enable row level security;
revoke all on public.people from anon, authenticated;

-- You become the owner, using the secret code you already have.
insert into public.people (name, code, is_owner)
  select 'Me', s.code, true from public.site s
  where s.id = 1 and not exists (select 1 from public.people p where p.is_owner);

alter table public.docs add column if not exists owner_id uuid references public.people(id) on delete cascade;
alter table public.docs add column if not exists readers uuid[] not null default '{}';
update public.docs set owner_id = (select id from public.people where is_owner limit 1) where owner_id is null;
update public.docs set path = 'settings/' || owner_id::text where path = 'settings/main';
alter table public.replies add column if not exists author_id uuid references public.people(id) on delete set null;

-- who is this code?
create or replace function public.who(k text) returns public.people
language sql stable security definer set search_path = public as $$
  select p from public.people p where p.code = k and k is not null and length(k) >= 16
$$;
revoke execute on function public.who(text) from public, anon, authenticated;

create or replace function public.can_read(me uuid, p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.docs d where d.path = p and (d.owner_id = me or me = any(d.readers)))
$$;
revoke execute on function public.can_read(uuid, text) from public, anon, authenticated;

-- old functions from step 1 are replaced
drop function if exists public.open_site(text);
drop function if exists public.docs_all(text);
drop function if exists public.doc_set(text, text, jsonb);
drop function if exists public.doc_del(text, text);
drop function if exists public.reply_add(text, text, text, text);
drop function if exists public.replies_get(text, text);
drop function if exists public.reply_del(text, bigint);

create or replace function public.open_site(k text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me public.people;
begin
  me := public.who(k); if me.id is null then return null; end if;
  return jsonb_build_object('id', me.id, 'name', me.name, 'owner', me.is_owner, 'folder', (select folder from public.site where id = 1));
end $$;

create or replace function public.people_list(k text) returns table (id uuid, name text, is_owner boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.is_owner from public.people p where (public.who(k)).id is not null order by p.is_owner desc, p.created_at
$$;

-- Each person has their own settings (home background, sticker shelf, picture library, font). The page always asks for "settings/main".
create or replace function public.docs_all(k text) returns table (path text, data jsonb)
language plpgsql stable security definer set search_path = public as $$
declare me public.people;
begin
  me := public.who(k); if me.id is null then return; end if;
  return query
    select d.path, d.data || jsonb_build_object('by', d.owner_id::text, 'toIds', to_jsonb(d.readers::text[])) from public.docs d
      where d.path like 'letters/%' and (d.owner_id = me.id or me.id = any(d.readers))
    union all
    -- your own settings; anything you haven't set yourself (background, font, envelope drawing) comes from the site owner's
    select 'settings/main', coalesce(
        (select jsonb_strip_nulls(jsonb_build_object('bg', o.data->'bg', 'font', o.data->'font', 'fontName', o.data->'fontName', 'motif', o.data->'motif'))
           from public.docs o join public.people op on o.path = 'settings/' || op.id::text and op.is_owner), '{}'::jsonb)
      || coalesce((select jsonb_object_agg(e.key, e.value) from public.docs d, jsonb_each(d.data) e
           where d.path = 'settings/' || me.id::text and not (e.key in ('bg','font','fontName','motif') and e.value in ('""'::jsonb, 'null'::jsonb))), '{}'::jsonb);
end $$;

create or replace function public.doc_set(k text, p text, d jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare me public.people; cur public.docs; rs uuid[];
begin
  me := public.who(k); if me.id is null then return false; end if;
  if p = 'settings/main' then
    insert into public.docs (path, data, owner_id, updated_at) values ('settings/' || me.id::text, d, me.id, now())
      on conflict (path) do update set data = excluded.data, updated_at = now();
    return true;
  end if;
  if p !~ '^letters/[A-Za-z0-9_-]{1,64}$' then return false; end if;
  select * into cur from public.docs x where x.path = p;
  if cur.path is not null and cur.owner_id <> me.id then return false; end if;
  if cur.path is null and (select count(*) from public.docs) >= 5000 then return false; end if;
  select coalesce(array_agg(pp.id), '{}') into rs from public.people pp
    where pp.id <> me.id and pp.id::text in (select jsonb_array_elements_text(case when jsonb_typeof(d->'toIds') = 'array' then d->'toIds' else '[]'::jsonb end));
  d := d - 'by' - 'toIds';
  insert into public.docs (path, data, owner_id, readers, updated_at) values (p, d, me.id, rs, now())
    on conflict (path) do update set data = excluded.data, readers = excluded.readers, updated_at = now();
  return true;
end $$;

create or replace function public.doc_del(k text, p text) returns boolean
language plpgsql security definer set search_path = public as $$
declare me public.people;
begin
  me := public.who(k); if me.id is null then return false; end if;
  delete from public.docs x where x.path = p and x.path like 'letters/%' and x.owner_id = me.id;
  delete from public.replies r where 'letters/' || r.letter = p and not exists (select 1 from public.docs x where x.path = p);
  return true;
end $$;

create or replace function public.reply_add(k text, l text, b text) returns boolean
language plpgsql security definer set search_path = public as $$
declare me public.people;
begin
  me := public.who(k); if me.id is null then return false; end if;
  if not public.can_read(me.id, 'letters/' || l) then return false; end if;
  if (select count(*) from public.replies r where r.created_at > now() - interval '1 day') >= 1000 then return false; end if;
  insert into public.replies (letter, author, author_id, body) values (left(l, 64), me.name, me.id, left(b, 5000));
  return true;
end $$;

create or replace function public.replies_get(k text, l text) returns table (id bigint, letter text, author text, mine boolean, body text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me public.people;
begin
  me := public.who(k); if me.id is null then return; end if;
  return query select r.id, r.letter, coalesce(pp.name, r.author), r.author_id = me.id, r.body, r.created_at
    from public.replies r left join public.people pp on pp.id = r.author_id
    where (l is null or r.letter = l) and public.can_read(me.id, 'letters/' || r.letter) order by r.created_at;
end $$;

create or replace function public.reply_del(k text, i bigint) returns boolean
language plpgsql security definer set search_path = public as $$
declare me public.people;
begin
  me := public.who(k); if me.id is null then return false; end if;
  delete from public.replies r where r.id = i and r.author_id = me.id;
  return true;
end $$;

-- Only the owner manages the friends list.
create or replace function public.person_add(k text, n text) returns text
language plpgsql security definer set search_path = public as $$
declare me public.people; c text;
begin
  me := public.who(k); if me.id is null or not me.is_owner then return null; end if;
  if length(trim(n)) = 0 or (select count(*) from public.people) >= 200 then return null; end if;
  insert into public.people (name) values (left(trim(n), 60)) returning code into c;
  return c;
end $$;

create or replace function public.person_link(k text, i uuid) returns text
language sql stable security definer set search_path = public as $$
  select p.code from public.people p where p.id = i and coalesce((public.who(k)).is_owner, false)
$$;

create or replace function public.person_rename(k text, i uuid, n text) returns boolean
language plpgsql security definer set search_path = public as $$
declare me public.people;
begin
  me := public.who(k); if me.id is null or length(trim(n)) = 0 then return false; end if;
  if not me.is_owner and me.id <> i then return false; end if;
  update public.people set name = left(trim(n), 60) where id = i;
  return true;
end $$;

-- Removing a friend deletes their letters and makes their link stop working.
create or replace function public.person_remove(k text, i uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare me public.people;
begin
  me := public.who(k); if me.id is null or not me.is_owner or me.id = i then return false; end if;
  delete from public.people where id = i and not is_owner;
  update public.docs set readers = array_remove(readers, i);
  return true;
end $$;

-- A new link for someone whose link was shared by mistake.
create or replace function public.person_newcode(k text, i uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me public.people; c text;
begin
  me := public.who(k); if me.id is null or not me.is_owner then return null; end if;
  update public.people set code = replace(gen_random_uuid()::text, '-', '') where id = i returning code into c;
  return c;
end $$;

grant execute on function public.open_site(text), public.people_list(text), public.docs_all(text), public.doc_set(text, text, jsonb),
  public.doc_del(text, text), public.reply_add(text, text, text), public.replies_get(text, text), public.reply_del(text, bigint),
  public.person_add(text, text), public.person_link(text, uuid), public.person_rename(text, uuid, text), public.person_remove(text, uuid),
  public.person_newcode(text, uuid) to anon, authenticated;

select 'All set. Your old secret code is now your personal code.' as result;
