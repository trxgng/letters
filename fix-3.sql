-- Fix 3: friends can choose their own background (otherwise they see yours), with the new background options.
-- Run in Supabase > SQL Editor > New query > Run.

create or replace function public.docs_all(k text) returns table (path text, data jsonb)
language plpgsql stable security definer set search_path = public as $$
declare me public.people; host jsonb; own jsonb; bgk text[] := array['bg','bgFit','bgPos','bgSize','bgHaze','bgBlur','bgColor','bgRot','bgZoom','wordColor']; st jsonb;
begin
  me := public.who(k); if me.id is null then return; end if;
  select o.data into host from public.docs o join public.people op on o.path = 'settings/' || op.id::text and op.is_owner;
  select d.data into own from public.docs d where d.path = 'settings/' || me.id::text;
  host := coalesce(host, '{}'::jsonb); own := coalesce(own, '{}'::jsonb);
  -- font and envelope drawing: yours if you set them, otherwise the host's
  st := jsonb_strip_nulls(jsonb_build_object('font', host->'font', 'fontName', host->'fontName', 'motif', host->'motif'))
     || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(own) e
          where not (e.key = any(bgk)) and not (e.key in ('font','fontName','motif') and e.value in ('""'::jsonb, 'null'::jsonb))), '{}'::jsonb);
  -- background: yours if you chose your own, otherwise the host's
  st := st || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(case when own->>'bgOwn' = 'true' or me.is_owner then own else host end) e where e.key = any(bgk)), '{}'::jsonb);
  return query
    select d.path, d.data || jsonb_build_object('by', d.owner_id::text, 'toIds', to_jsonb(d.readers::text[])) from public.docs d
      where d.path like 'letters/%' and (d.owner_id = me.id or me.id = any(d.readers))
    union all
    select 'settings/main'::text, st;
end $$;

select 'Done' as result;
