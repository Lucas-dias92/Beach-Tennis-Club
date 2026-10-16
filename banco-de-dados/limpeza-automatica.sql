-- Beach Tennis Club: limpeza automática de convites, jogos e torneios que já passaram
-- Cole no SQL Editor do projeto "Beach Tennis" e clique em Run. Pode rodar mais de uma vez.
--
-- Regras (horário de Brasília):
--   convites     : somem 2 horas depois do horário combinado
--   jogos        : jogos marcados e SEM resultado somem 24 horas depois do horário
--                  (jogos com resultado informado ficam: contam para o ranking)
--   torneios     : torneios que não foram encerrados somem 1 dia depois da data
--                  (torneios encerrados, com pódio, ficam no histórico)

create or replace function public.cleanup_expired() returns json
language plpgsql security definer set search_path = public as $$
declare
  v_now timestamp := (now() at time zone 'America/Sao_Paulo');
  n_inv int := 0; n_g int := 0; n_t int := 0;
begin
  delete from public.invites i
   where i.time ~ '^[0-9]{2}:[0-9]{2}'
     and (i.day + left(i.time, 5)::time) < v_now - interval '2 hours';
  get diagnostics n_inv = row_count;

  delete from public.games g
   where g.done = false and g.winner is null
     and g.time ~ '^[0-9]{2}:[0-9]{2}'
     and (g.day + left(g.time, 5)::time) < v_now - interval '24 hours';
  get diagnostics n_g = row_count;

  delete from public.tournaments t
   where t.status <> 'encerrado' and t.day < v_now::date - 1;
  get diagnostics n_t = row_count;

  return json_build_object('convites', n_inv, 'jogos', n_g, 'torneios', n_t);
end $$;
revoke execute on function public.cleanup_expired() from public, anon;
grant execute on function public.cleanup_expired() to authenticated;

-- roda sozinho de hora em hora
select cron.unschedule('cleanup-expired') where exists (select 1 from cron.job where jobname = 'cleanup-expired');
select cron.schedule('cleanup-expired', '10 * * * *', 'select public.cleanup_expired()');
