-- Letters website: run this once in Supabase > SQL Editor > New query > Run.
-- At the end it shows your secret code. Keep it: it's the key to your letters.

create table if not exists public.site (
  id int primary key default 1 check (id = 1),
  code text not null default replace(gen_random_uuid()::text, '-', ''),
  folder text not null default replace(gen_random_uuid()::text, '-', '')
);
insert into public.site (id) values (1) on conflict do nothing;

create table if not exists public.docs (
  path text primary key check (length(path) <= 120),
  data jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.replies (
  id bigint generated always as identity primary key,
  letter text not null check (length(letter) <= 64),
  author text not null default '' check (length(author) <= 60),
  body text not null check (length(body) between 1 and 5000),
  created_at timestamptz not null default now()
);

-- Nobody can touch the tables directly. Everything goes through the functions below, which check the secret code.
alter table public.site enable row level security;
alter table public.docs enable row level security;
alter table public.replies enable row level security;
revoke all on public.site, public.docs, public.replies from anon, authenticated;

create or replace function public.code_ok(k text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site s where s.id = 1 and s.code = k)
$$;

create or replace function public.open_site(k text) returns text
language sql stable security definer set search_path = public as $$
  select s.folder from public.site s where s.id = 1 and s.code = k
$$;

create or replace function public.docs_all(k text) returns table (path text, data jsonb)
language sql stable security definer set search_path = public as $$
  select d.path, d.data from public.docs d where public.code_ok(k)
$$;

create or replace function public.doc_set(k text, p text, d jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.code_ok(k) then return false; end if;
  if (select count(*) from public.docs) >= 2000 and not exists (select 1 from public.docs x where x.path = p) then return false; end if;
  insert into public.docs (path, data, updated_at) values (p, d, now())
    on conflict (path) do update set data = excluded.data, updated_at = now();
  return true;
end $$;

create or replace function public.doc_del(k text, p text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.code_ok(k) then return false; end if;
  delete from public.docs x where x.path = p;
  return true;
end $$;

create or replace function public.reply_add(k text, l text, a text, b text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.code_ok(k) then return false; end if;
  if (select count(*) from public.replies r where r.created_at > now() - interval '1 day') >= 300 then return false; end if;
  insert into public.replies (letter, author, body) values (left(l, 64), left(coalesce(a, ''), 60), left(b, 5000));
  return true;
end $$;

create or replace function public.replies_get(k text, l text) returns table (id bigint, letter text, author text, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.id, r.letter, r.author, r.body, r.created_at from public.replies r
  where public.code_ok(k) and (l is null or r.letter = l) order by r.created_at
$$;

create or replace function public.reply_del(k text, i bigint) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.code_ok(k) then return false; end if;
  delete from public.replies r where r.id = i;
  return true;
end $$;

-- Pictures can only be added into the secret folder, which only people with the code are told.
create or replace function public.folder_ok(f text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site s where s.id = 1 and s.folder = f)
$$;

grant execute on function public.open_site(text), public.docs_all(text), public.doc_set(text, text, jsonb), public.doc_del(text, text),
  public.reply_add(text, text, text, text), public.replies_get(text, text), public.reply_del(text, bigint), public.folder_ok(text) to anon, authenticated;
revoke execute on function public.code_ok(text) from public, anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit) values ('letters', 'letters', true, 15728640)
  on conflict (id) do update set public = true, file_size_limit = 15728640;
drop policy if exists "letters add pictures" on storage.objects;
create policy "letters add pictures" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'letters' and public.folder_ok((storage.foldername(name))[1]));

select code as "your secret code (copy it)" from public.site;
