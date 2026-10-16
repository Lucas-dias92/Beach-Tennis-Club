-- Beach Tennis Club: avisos com o emoji de praia (🏖) no lugar da bola de tênis (🎾). Só para o banco do Beach.
do $$
declare f text; d text;
begin
  for f in select unnest(array['trg_request_push', 'trg_games_partner_push', 'weekly_digest']) loop
    select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = f;
    if d is not null and position('🎾' in d) > 0 then execute replace(d, '🎾', '🏖'); end if;
  end loop;
end $$;
