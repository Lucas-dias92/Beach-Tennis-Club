-- Administrador que também joga (role = 'jogador') aparece no ranking como qualquer jogador.
-- Também converte os pontos dele para a escala nova, caso ainda não tenha sido convertido.
create or replace function public.take_rank_snapshot() returns int language plpgsql security definer set search_path = public as $$
declare m text; n int := 0;
begin
  delete from public.rank_snapshots where snap_date = current_date;
  insert into public.rank_snapshots(snap_date, modality, player, pos, points)
    select current_date, 'individual', p.id, row_number() over (order by p.rank desc, p.elo desc, p.name), p.rank
      from public.profiles p where p.role = 'jogador';
  get diagnostics n = row_count;
  for m in select distinct modality from public.ratings loop
    insert into public.rank_snapshots(snap_date, modality, player, pos, points)
      select current_date, m, r.player, row_number() over (order by r.points desc, r.elo desc, p.name), r.points
        from public.ratings r join public.profiles p on p.id = r.player where r.modality = m;
  end loop;
  update public.profiles p set best_pos = least(coalesce(p.best_pos, 9999), s.pos)
    from public.rank_snapshots s where s.snap_date = current_date and s.modality = 'individual' and s.player = p.id;
  return n;
end $$;
revoke execute on function public.take_rank_snapshot() from public, anon, authenticated;

create or replace function public.ranking_board(p_mod text default 'individual', p_cat text default null, p_city text default null, p_days int default null, p_limit int default 100) returns json
language plpgsql stable security definer set search_path = public as $$
declare snap date;
begin
  if auth.uid() is null then raise exception 'Entre para ver o ranking.'; end if;
  select max(snap_date) into snap from public.rank_snapshots where snap_date < current_date and modality = p_mod;
  return (select coalesce(json_agg(t order by t.pos), '[]'::json) from (
    select row_number() over (order by x.pts desc, x.elo desc, x.wins desc, x.name) as pos, x.*, s.pos as prev_pos
      from (
        select p.id, p.name, p.photo_url, p.city, p.category, p.level,
               case when p_mod = 'individual' then p.rank else coalesce(r.points, 0) end as total_points,
               case when p_days is null then (case when p_mod = 'individual' then p.rank else coalesce(r.points, 0) end)
                    else coalesce((select sum(l.delta) from public.rating_log l where l.player = p.id and l.modality = p_mod and not l.reverted and l.created_at >= now() - make_interval(days => p_days)), 0)::int end as pts,
               case when p_mod = 'individual' then p.elo else coalesce(r.elo, 1000) end as elo,
               (select count(*) from public.games g where g.done and not g.cancelled and g.winner is not null and
                  ((p.id in (g.a, g.a2) and g.winner = g.a) or (p.id in (g.b, g.b2) and g.winner = g.b)))::int as wins,
               (select count(*) from public.games g where g.done and not g.cancelled and g.winner is not null and
                  ((p.id in (g.a, g.a2) and g.winner = g.b) or (p.id in (g.b, g.b2) and g.winner = g.a)))::int as losses,
               (select max(g.day) from public.games g where g.done and not g.cancelled and p.id in (g.a, g.b, g.a2, g.b2)) as last_game
          from public.profiles p
          left join public.ratings r on r.player = p.id and r.modality = p_mod
         where p.role = 'jogador'
           and (p_mod = 'individual' or r.player is not null)
           and (p_cat is null or p.category = p_cat)
           and (p_city is null or lower(split_part(coalesce(p.city, ''), '/', 1)) = lower(split_part(p_city, '/', 1)))
      ) x
      left join public.rank_snapshots s on s.snap_date = snap and s.modality = p_mod and s.player = x.id
     order by pos limit greatest(1, least(p_limit, 500))) t);
end $$;
revoke execute on function public.ranking_board(text, text, text, int, int) from public, anon;
grant execute on function public.ranking_board(text, text, text, int, int) to authenticated;

do $$
begin
  perform set_config('app.engine', 'on', true);
  update public.profiles p
     set elo = 1000 + greatest(0, coalesce(p.rank, 0) - public._base_rating(p.level)),
         rank = greatest(0, coalesce(p.rank, 0) - public._base_rating(p.level)),
         category = coalesce(p.category, p.level)
   where p.role = 'jogador' and coalesce(p.is_admin, false) and p.elo = 1000
     and not exists (select 1 from public.rating_log l where l.player = p.id);
  perform set_config('app.engine', 'off', true);
end $$;
