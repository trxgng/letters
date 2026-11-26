-- Fix 1: friends see your home background (and font / envelope drawing) unless they pick their own.
-- Also lists every letter, so Claude can see why one is missing. Run in Supabase > SQL Editor > New query > Run,
-- then send Claude a screenshot of the table it shows.

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

select d.data->>'to' as "to", coalesce(nullif(d.data->>'from',''), w.name) as "from", w.name as "belongs to",
  (select string_agg(p.name, ', ') from public.people p where p.id = any(d.readers)) as "can open it",
  to_char(d.updated_at at time zone 'Asia/Ho_Chi_Minh', 'DD Mon HH24:MI') as "last saved"
from public.docs d left join public.people w on w.id = d.owner_id
where d.path like 'letters/%' order by d.updated_at desc;
