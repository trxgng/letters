-- Puts the sun and moon picture on the front cover of the letters your friends wrote to you.
-- Run once in Supabase > SQL Editor > New query > Run. It lists the letters it changed.
update public.docs d
   set data = d.data || '{"cover2": "covers/sunmoon.jpg"}'::jsonb, updated_at = now()
  from public.people o
 where o.is_owner
   and d.path like 'letters/%'
   and d.owner_id <> o.id
   and o.id = any(d.readers)
returning d.data->>'to' as "to", d.data->>'from' as "from";
