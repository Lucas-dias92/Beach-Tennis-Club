-- =====================================================================
-- Tênis de Campo Club: app redondo
--  * Excluir a própria conta e todos os dados (LGPD)
--  * Indicação de amigos (?ref=) e selo de embaixador
--  * Painel de números para o administrador
--  * Cópia dos dados (exportação) para o administrador
--  * Resumo semanal por aviso (segunda-feira, 9h de Brasília)
-- Cole no SQL Editor e clique em Run. Pode rodar mais de uma vez.
-- =====================================================================

-- ----- excluir a própria conta -----
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Entre para excluir a conta.'; end if;
  if coalesce((select is_admin from public.profiles where id = me), false) then
    raise exception 'Contas de administrador não podem ser excluídas por aqui.';
  end if;
  delete from public.profiles where id = me;  -- apaga o perfil e o conteúdo ligado a ele (cascata)
  delete from auth.users where id = me;       -- apaga o login
end $$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ----- indicação de amigos -----
alter table public.profiles add column if not exists referred_by uuid references public.profiles(id) on delete set null;

create or replace function public.set_referrer(p_ref uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_ref is null or p_ref = auth.uid() then return; end if;
  if not exists (select 1 from public.profiles where id = p_ref) then return; end if;
  update public.profiles set referred_by = p_ref where id = auth.uid() and referred_by is null;
end $$;
revoke execute on function public.set_referrer(uuid) from public, anon;
grant execute on function public.set_referrer(uuid) to authenticated;

create or replace function public.player_stats(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r record;
  w int := 0; l int := 0; total int := 0;
  streak int := 0; counting boolean := true;
  last jsonb := '[]'::jsonb; n int := 0;
  hw int := 0; hl int := 0;
  votes int := 0; noshows int := 0; refs int := 0;
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
  select count(*) into refs from public.profiles where referred_by = p_id;
  return json_build_object('games', total, 'wins', w, 'losses', l, 'streak', streak,
                           'last', last, 'h2h_wins', hw, 'h2h_losses', hl,
                           'votes', votes, 'noshows', noshows, 'referrals', refs);
end $$;
revoke execute on function public.player_stats(uuid) from public, anon;
grant execute on function public.player_stats(uuid) to authenticated;

-- ----- números para o administrador -----
create or replace function public.admin_metrics() returns json
language plpgsql security definer set search_path = public as $$
declare cities json;
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  select coalesce(json_agg(x), '[]'::json) into cities from (
    select coalesce(nullif(btrim(city), ''), 'Sem cidade') as city, count(*)::int as n
      from public.profiles where not is_admin group by 1 order by 2 desc limit 6) x;
  return json_build_object(
    'players',        (select count(*) from public.profiles where not is_admin and role = 'jogador'),
    'teachers',       (select count(*) from public.profiles where role = 'professor' and approval = 'aprovado'),
    'teachers_wait',  (select count(*) from public.profiles where role = 'professor' and approval = 'pendente'),
    'signups_7',      (select count(*) from public.profiles where not is_admin and created_at > now() - interval '7 days'),
    'signups_30',     (select count(*) from public.profiles where not is_admin and created_at > now() - interval '30 days'),
    'games_total',    (select count(*) from public.games where done),
    'games_30',       (select count(*) from public.games where done and created_at > now() - interval '30 days'),
    'invites_open',   (select count(*) from public.invites where status = 'open'),
    'tournaments_open', (select count(*) from public.tournaments where status = 'aberto'),
    'lessons_30',     (select count(*) from public.lessons where day >= current_date - 30 and day <= current_date),
    'referrals',      (select count(*) from public.profiles where referred_by is not null),
    'reports_open',   (select count(*) from public.player_reports where not resolved),
    'cities',         cities);
end $$;
revoke execute on function public.admin_metrics() from public, anon;
grant execute on function public.admin_metrics() to authenticated;

-- ----- cópia dos dados (exportação) -----
create or replace function public.admin_export() returns json
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  return json_build_object(
    'gerado_em', now(),
    'profiles',  (select coalesce(json_agg(p), '[]'::json) from public.profiles p),
    'games',     (select coalesce(json_agg(g), '[]'::json) from public.games g),
    'invites',   (select coalesce(json_agg(i), '[]'::json) from public.invites i),
    'tournaments', (select coalesce(json_agg(t), '[]'::json) from public.tournaments t),
    'tournament_entries', (select coalesce(json_agg(e), '[]'::json) from public.tournament_entries e),
    'lessons',   (select coalesce(json_agg(l), '[]'::json) from public.lessons l));
end $$;
revoke execute on function public.admin_export() from public, anon;
grant execute on function public.admin_export() to authenticated;

-- ----- resumo semanal -----
create or replace function public.weekly_digest() returns int
language plpgsql security definer set search_path = public as $$
declare u record; pos int; open_n int; sent int := 0;
begin
  for u in
    select p.id, p.city from public.profiles p
     where not p.is_admin and p.role = 'jogador'
       and exists (select 1 from public.push_subscriptions s where s.user_id = p.id)
  loop
    select count(*) + 1 into pos from public.profiles x
     where not x.is_admin and x.role = 'jogador' and x.rank > (select rank from public.profiles where id = u.id);
    select count(*) into open_n from public.invites i
      join public.profiles o on o.id = i.owner
     where i.status = 'open' and i.owner <> u.id
       and lower(split_part(coalesce(nullif(i.city, ''), o.city, ''), '/', 1)) = lower(split_part(coalesce(u.city, ''), '/', 1))
       and (i.day::text || ' ' || i.time)::timestamp >= (now() at time zone 'America/Sao_Paulo');
    if open_n > 0 then
      perform public.push_send(u.id, '🎾 Sua semana no clube',
        'Você está em #' || pos || ' no ranking e há ' || open_n || case when open_n = 1 then ' pessoa' else ' pessoas' end || ' procurando jogo na sua cidade.');
      sent := sent + 1;
    end if;
  end loop;
  return sent;
end $$;
revoke execute on function public.weekly_digest() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'weekly-digest') then perform cron.unschedule('weekly-digest'); end if;
exception when others then null; end $$;
select cron.schedule('weekly-digest', '0 12 * * 1', 'select public.weekly_digest()');
