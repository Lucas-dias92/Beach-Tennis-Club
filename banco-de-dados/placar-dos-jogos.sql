-- =====================================================================
-- Tênis de Campo Club: placar nos jogos (com tie-break) e histórico no perfil
--  * games.score: placar do ponto de vista do VENCEDOR, ex.: "6-3 4-6 7-6(5)" ou "6-4 [10-7]"
--  * report_result(g, w, p_score): quem informa o resultado também informa o placar (opcional)
--  * player_stats: devolve os últimos 10 jogos, com placar
-- Cole no SQL Editor e clique em Run. Pode rodar mais de uma vez.
-- =====================================================================

alter table public.games add column if not exists score text;

drop function if exists public.report_result(uuid, uuid);
create or replace function public.report_result(g uuid, w uuid, p_score text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.games; sc text;
begin
  select * into r from public.games where id = g and done = false;
  if not found then raise exception 'Jogo não encontrado ou já encerrado'; end if;
  if auth.uid() not in (r.a, r.b) then raise exception 'Você não participa deste jogo'; end if;
  if w not in (r.a, r.b) then raise exception 'Vencedor inválido'; end if;
  sc := nullif(left(btrim(coalesce(p_score, '')), 60), '');
  if sc is not null and sc !~ '^[0-9()\[\] -]+$' then raise exception 'Placar inválido'; end if;
  update public.games
     set winner = w, reported_by = auth.uid(), reported_at = now(), score = sc
   where id = g;
end $$;
revoke execute on function public.report_result(uuid, uuid, text) from public, anon;
grant execute on function public.report_result(uuid, uuid, text) to authenticated;

-- contestar o resultado também limpa o placar
create or replace function public.contest_result(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.games;
begin
  select * into r from public.games where id = g and done = false and winner is not null;
  if not found then raise exception 'Nenhum resultado para contestar'; end if;
  if auth.uid() not in (r.a, r.b) or auth.uid() = r.reported_by then raise exception 'Só o outro jogador pode contestar'; end if;
  if r.reported_at is not null and r.reported_at < now() - interval '48 hours' then raise exception 'O prazo para contestar acabou.'; end if;
  update public.games set winner = null, reported_by = null, reported_at = null, score = null where id = g;
end $$;
revoke execute on function public.contest_result(uuid) from public, anon;
grant execute on function public.contest_result(uuid) to authenticated;

create or replace function public.player_stats(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r record;
  w int := 0; l int := 0; total int := 0;
  streak int := 0; counting boolean := true;
  last jsonb := '[]'::jsonb; n int := 0;
  hw int := 0; hl int := 0;
begin
  if me is null then raise exception 'Entre para ver perfis.'; end if;
  for r in
    select g.*, case when g.a = p_id then g.b else g.a end as opp
      from public.games g
     where g.done and g.winner is not null and (g.a = p_id or g.b = p_id)
     order by g.day desc, g.time desc
  loop
    total := total + 1;
    if r.winner = p_id then w := w + 1; else l := l + 1; end if;
    if counting then
      if r.winner = p_id then streak := streak + 1; else counting := false; end if;
    end if;
    if n < 10 then
      last := last || jsonb_build_array(jsonb_build_object(
        'day', r.day, 'win', r.winner = p_id, 'opp', r.opp, 'score', r.score,
        'ranked', coalesce((to_jsonb(r) ->> 'ranked')::boolean, true)));
      n := n + 1;
    end if;
    if me <> p_id and (r.a = me or r.b = me) then
      if r.winner = p_id then hw := hw + 1; else hl := hl + 1; end if;
    end if;
  end loop;
  return json_build_object('games', total, 'wins', w, 'losses', l, 'streak', streak,
                           'last', last, 'h2h_wins', hw, 'h2h_losses', hl);
end $$;
revoke execute on function public.player_stats(uuid) from public, anon;
grant execute on function public.player_stats(uuid) to authenticated;
