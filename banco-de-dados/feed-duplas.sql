-- Feed da comunidade: mostra os dois lados de uma partida de duplas (com ids para abrir o perfil) e o placar.
drop function if exists public.community_feed(boolean, int);
create or replace function public.community_feed(p_following boolean default false, p_limit int default 30)
returns table (id uuid, a uuid, b uuid, winner uuid, day date, "time" text, ranked boolean, cheers int, cheered boolean,
               a2 uuid, b2 uuid, a2_name text, b2_name text, score text)
language sql security definer set search_path = public stable as $$
  select g.id, g.a, g.b, g.winner, g.day, g.time,
         coalesce((to_jsonb(g) ->> 'ranked')::boolean, true),
         (select count(*)::int from public.game_cheers c where c.game_id = g.id),
         exists (select 1 from public.game_cheers c where c.game_id = g.id and c.user_id = auth.uid()),
         g.a2, g.b2, g.a2_name, g.b2_name, g.score
    from public.games g
   where auth.uid() is not null and g.done and not g.cancelled and g.winner is not null
     and (not p_following
          or auth.uid() in (g.a, g.b, g.a2, g.b2)
          or exists (select 1 from public.follows f where f.follower = auth.uid() and f.followee in (g.a, g.b, g.a2, g.b2)))
   order by g.day desc, g.time desc
   limit least(greatest(p_limit, 1), 60);
$$;
revoke execute on function public.community_feed(boolean, int) from public, anon;
grant execute on function public.community_feed(boolean, int) to authenticated;
