-- =====================================================================
-- Tênis de Campo Club: ranking Elo
--  * Nível declarado define a pontuação inicial: Iniciante 1000, Intermediário 1200, Avançado 1400
--  * Só jogos confirmados que valem ranking mexem na pontuação (amistoso não conta)
--  * K = 40 enquanto alguém tem menos de 10 jogos de ranking, depois K = 32
--  * Mesmo adversário várias vezes em 7 dias vale menos (100% / 50% / 25%) para evitar "farm"
--  * Soma zero: o que o vencedor ganha o perdedor perde (pontuação nunca abaixo de 0)
--  * Pontos de pódio de torneio continuam como bônus
--  * games.delta_w / delta_l guardam a variação de cada jogo (usada no gráfico)
-- Cole no SQL Editor e clique em Run. Pode rodar mais de uma vez.
-- =====================================================================

alter table public.games add column if not exists delta_w int;
alter table public.games add column if not exists delta_l int;

create or replace function public._base_rating(lv text) returns int
language sql immutable as $$
  select case lv when 'Avançado' then 1400 when 'Intermediário' then 1200 else 1000 end
$$;

-- Quem ainda não tem jogo de ranking confirmado recebe a pontuação inicial do nível
create or replace function public.trg_profile_base_rating() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role = 'jogador' and not coalesce(new.is_admin, false) then
    if tg_op = 'INSERT' then
      if coalesce(new.rank, 0) = 0 then new.rank := public._base_rating(new.level); end if;
    elsif new.level is distinct from old.level
          and not exists (select 1 from public.games g
                           where g.done and g.ranked and g.winner is not null and (g.a = new.id or g.b = new.id)) then
      new.rank := public._base_rating(new.level);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists profiles_base_rating on public.profiles;
create trigger profiles_base_rating before insert or update of level on public.profiles
  for each row execute function public.trg_profile_base_rating();

-- Migração (roda uma vez): quem já tinha pontos mantém o que ganhou, somado à base do nível
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'elo_v1') then
    update public.profiles
       set rank = public._base_rating(level) + coalesce(rank, 0)
     where role = 'jogador' and not coalesce(is_admin, false);
    insert into public.app_settings(key, value) values ('elo_v1', now()::text);
  end if;
end $$;

create or replace function public._finish_game(g uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.games; l uuid;
  rw int; rl int; k int; e numeric; wgt numeric; n int; gw int; gl int; d int; applied int;
begin
  select * into r from public.games where id = g and done = false and winner is not null for update;
  if not found then return; end if;
  l := case when r.winner = r.a then r.b else r.a end;
  update public.games set done = true where id = g;
  if not r.ranked then return; end if;

  select coalesce(rank, 0) into rw from public.profiles where id = r.winner;
  select coalesce(rank, 0) into rl from public.profiles where id = l;

  select count(*) into gw from public.games x
   where x.done and x.ranked and x.winner is not null and x.id <> g and (x.a = r.winner or x.b = r.winner);
  select count(*) into gl from public.games x
   where x.done and x.ranked and x.winner is not null and x.id <> g and (x.a = l or x.b = l);
  k := case when least(gw, gl) < 10 then 40 else 32 end;

  select count(*) into n from public.games x
   where x.done and x.ranked and x.winner is not null and x.id <> g
     and ((x.a = r.a and x.b = r.b) or (x.a = r.b and x.b = r.a))
     and x.day >= r.day - 7;
  wgt := case when n < 2 then 1 when n < 4 then 0.5 else 0.25 end;

  e := 1 / (1 + power(10, (rl - rw) / 400.0));
  d := greatest(1, round(k * (1 - e) * wgt));
  applied := least(d, rl);

  update public.profiles set rank = rank + d where id = r.winner;
  update public.profiles set rank = rank - applied where id = l;
  update public.games set delta_w = d, delta_l = -applied where id = g;
end $$;
revoke execute on function public._finish_game(uuid) from public, anon, authenticated;
