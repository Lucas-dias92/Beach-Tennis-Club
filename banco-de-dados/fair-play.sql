-- =====================================================================
-- Tênis de Campo Club: avaliação do adversário depois do jogo (fair play)
--  * Depois de um jogo encerrado, cada jogador marca: "Tudo certo" ou "Não compareceu"
--  * O perfil mostra quantos jogos foram avaliados e quantas faltas a pessoa teve
-- Cole no SQL Editor e clique em Run. Pode rodar mais de uma vez.
-- =====================================================================

create table if not exists public.game_feedback (
  game uuid not null references public.games(id) on delete cascade,
  rater uuid not null references public.profiles(id) on delete cascade,
  rated uuid not null references public.profiles(id) on delete cascade,
  showed boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (game, rater)
);
alter table public.game_feedback enable row level security;
drop policy if exists "fb_own_read" on public.game_feedback;
create policy "fb_own_read" on public.game_feedback for select to authenticated using (rater = auth.uid());
grant select on public.game_feedback to authenticated;

create or replace function public.rate_game(g uuid, p_showed boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r public.games; other uuid;
begin
  select * into r from public.games where id = g and done = true;
  if not found then raise exception 'Jogo não encontrado ou ainda não encerrado'; end if;
  if auth.uid() not in (r.a, r.b) then raise exception 'Você não participou deste jogo'; end if;
  other := case when auth.uid() = r.a then r.b else r.a end;
  insert into public.game_feedback(game, rater, rated, showed) values (g, auth.uid(), other, coalesce(p_showed, true))
  on conflict (game, rater) do update set showed = excluded.showed;
end $$;
revoke execute on function public.rate_game(uuid, boolean) from public, anon;
grant execute on function public.rate_game(uuid, boolean) to authenticated;

create or replace function public.player_stats(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r record;
  w int := 0; l int := 0; total int := 0;
  streak int := 0; counting boolean := true;
  last jsonb := '[]'::jsonb; n int := 0;
  hw int := 0; hl int := 0;
  votes int := 0; noshows int := 0;
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
  select count(*), count(*) filter (where not showed) into votes, noshows
    from public.game_feedback where rated = p_id;
  return json_build_object('games', total, 'wins', w, 'losses', l, 'streak', streak,
                           'last', last, 'h2h_wins', hw, 'h2h_losses', hl,
                           'votes', votes, 'noshows', noshows);
end $$;
revoke execute on function public.player_stats(uuid) from public, anon;
grant execute on function public.player_stats(uuid) to authenticated;
