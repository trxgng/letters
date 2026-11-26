-- Fix 2: only the host's home background is used, for everyone. And the letter "To Giang" goes back to the friend who wrote it.
-- Run in Supabase > SQL Editor > New query > Run.

create or replace function public.docs_all(k text) returns table (path text, data jsonb)
language plpgsql stable security definer set search_path = public as $$
declare me public.people;
begin
  me := public.who(k); if me.id is null then return; end if;
  return query
    select d.path, d.data || jsonb_build_object('by', d.owner_id::text, 'toIds', to_jsonb(d.readers::text[])) from public.docs d
      where d.path like 'letters/%' and (d.owner_id = me.id or me.id = any(d.readers))
    union all
    -- your own settings; font and envelope drawing come from the host unless you set your own; the background is always the host's
    select 'settings/main', coalesce(
        (select jsonb_strip_nulls(jsonb_build_object('bg', o.data->'bg', 'font', o.data->'font', 'fontName', o.data->'fontName', 'motif', o.data->'motif'))
           from public.docs o join public.people op on o.path = 'settings/' || op.id::text and op.is_owner), '{}'::jsonb)
      || coalesce((select jsonb_object_agg(e.key, e.value) from public.docs d, jsonb_each(d.data) e
           where d.path = 'settings/' || me.id::text and e.key <> 'bg' and not (e.key in ('font','fontName','motif') and e.value in ('""'::jsonb, 'null'::jsonb))), '{}'::jsonb)
      -- the home background is the host's, for everyone
      || jsonb_build_object('bg', coalesce((select o.data->'bg' from public.docs o join public.people op on o.path = 'settings/' || op.id::text and op.is_owner), '""'::jsonb));
end $$;

do $$
declare host uuid; fr uuid; n int;
begin
  select id into host from public.people where is_owner;
  select count(*) into n from public.people where not is_owner;
  if n <> 1 then raise exception 'There are % friends in the list, so tell Claude which one wrote the letter.', n; end if;
  select id into fr from public.people where not is_owner;
  update public.docs set owner_id = fr, readers = array[host]
    where path like 'letters/%' and owner_id = host and lower(data->>'to') like '%giang%';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'No letter "To Giang" found. Nothing was changed.'; end if;
end $$;

select d.data->>'to' as "to", w.name as "belongs to",
  (select string_agg(p.name, ', ') from public.people p where p.id = any(d.readers)) as "can open it"
from public.docs d left join public.people w on w.id = d.owner_id
where d.path like 'letters/%' order by d.updated_at desc;
