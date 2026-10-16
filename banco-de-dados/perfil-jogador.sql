-- Beach Tennis Club: estatisticas publicas do jogador (perfil, confronto direto, sequencia)
-- Cole no SQL Editor do projeto "Beach Tennis" e clique em Run.

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
    if n < 5 then
      last := last || jsonb_build_array(jsonb_build_object(
        'day', r.day, 'win', r.winner = p_id, 'opp', r.opp,
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
