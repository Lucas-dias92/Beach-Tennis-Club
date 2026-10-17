-- Agenda da comunidade: partidas marcadas (próximas) e histórico de jogos realizados, visíveis para quem está logado.
create or replace function public.community_agenda(p_kind text default 'next', p_city text default null, p_limit int default 60) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Entre para ver a agenda.'; end if;
  return (select coalesce(json_agg(t), '[]'::json) from (
    select g.id, g.day, g.time, g.local, g.format, g.ranked, g.winner, g.score, g.done,
           g.a, g.b, g.a2, g.b2, g.a2_name, g.b2_name
      from public.games g
      join public.profiles pa on pa.id = g.a
     where not g.cancelled
       and ((p_kind = 'next' and not g.done and g.day >= current_date)
         or (p_kind <> 'next' and g.done and g.winner is not null))
       and (p_city is null or lower(split_part(coalesce(pa.city, ''), '/', 1)) = lower(split_part(p_city, '/', 1)))
     order by case when p_kind = 'next' then g.day end asc, case when p_kind = 'next' then g.time end asc,
              case when p_kind <> 'next' then g.day end desc, case when p_kind <> 'next' then g.time end desc
     limit greatest(1, least(p_limit, 200))) t);
end $$;
revoke execute on function public.community_agenda(text, text, int) from public, anon;
grant execute on function public.community_agenda(text, text, int) to authenticated;
