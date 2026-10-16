-- =====================================================================
-- RANKING v2: pontuação, modalidades, duplas fixas, auditoria e contestação
--
-- REGRAS PRÓPRIAS DO CLUBE (não são regras oficiais da ITF):
--  * Todo jogador começa com 0 pontos públicos e um valor interno de habilidade (Elo) igual para todos: 1000.
--  * Pontos públicos = soma das variações das partidas confirmadas (nunca abaixo de 0).
--    O Elo interno pode ficar abaixo de 1000: assim a força real continua sendo medida mesmo com 0 pontos.
--  * Variação por jogador: K × (resultado − chance de vitória) × peso   (resultado: 1 vitória, 0 derrota)
--      chance de vitória = 1 / (1 + 10^((Elo adversário − Elo próprio) / 400))
--      K = 40 nas 10 primeiras partidas da modalidade, depois 32
--      peso = repetição × desfecho   (repetição: 1ª-2ª partida contra a mesma pessoa em 7 dias = 1,
--             3ª-4ª = 0,5, a partir da 5ª = 0,25; desfecho: normal 1, desistência 0,75, W.O. 0,5, anulada 0)
--    Arredondamento: pontos públicos arredondados para inteiro, com no mínimo 1 ponto de variação.
--  * Em duplas, cada jogador é comparado com a MÉDIA do Elo da dupla adversária.
--  * Desempate no ranking: pontos, depois Elo interno, depois vitórias, depois nome.
--  * Só resultados CONFIRMADOS mexem no ranking. Amistosos nunca mexem.
--  * Inatividade: pontos NÃO expiram. Quem está 90 dias sem jogar aparece como "inativo".
--  * Categorias (Iniciante, Intermediário, Avançado...) são configuradas pelo administrador por faixa de pontos.
--    O nível do cadastro é provisório: depois de 5 partidas confirmadas a categoria passa a seguir os pontos,
--    e só muda depois de 2 partidas seguidas na nova faixa. O jogador não altera o nível depois do 1º jogo.
--
-- Pré-requisitos já aplicados: nome-unico.sql, duplas.sql e ranking-elo.sql.
-- Pode rodar mais de uma vez.
-- =====================================================================

-- ===================== COLUNAS =====================
alter table public.profiles add column if not exists elo numeric not null default 1000;
alter table public.profiles add column if not exists gender text;
alter table public.profiles add column if not exists category text;
alter table public.profiles add column if not exists cat_pending text;
alter table public.profiles add column if not exists cat_streak int not null default 0;
alter table public.profiles add column if not exists best_pos int;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_gender_chk') then
    alter table public.profiles add constraint profiles_gender_chk check (gender is null or gender in ('M', 'F'));
  end if;
end $$;
grant update (gender) on public.profiles to authenticated;

alter table public.games add column if not exists match_format text not null default 'melhor_de_3';
alter table public.games add column if not exists outcome text not null default 'normal';
alter table public.games add column if not exists disputed boolean not null default false;
alter table public.games add column if not exists dispute_note text;
alter table public.games add column if not exists disputed_by uuid;
alter table public.games add column if not exists suspicious boolean not null default false;
alter table public.games add column if not exists cancelled boolean not null default false;
alter table public.games add column if not exists modality text;
alter table public.games add column if not exists a2_gender text;
alter table public.games add column if not exists b2_gender text;

-- ===================== CONFIGURAÇÃO =====================
create table if not exists public.match_formats (
  id text primary key, name text not null, sets_to_win int not null, games_per_set int not null,
  super_final boolean not null default false, sort int not null default 0, active boolean not null default true
);
insert into public.match_formats (id, name, sets_to_win, games_per_set, super_final, sort) values
  ('melhor_de_3',       'Melhor de 3 sets (tie-break em 6-6)',                 2, 6, false, 1),
  ('melhor_de_3_super', 'Melhor de 3 sets, 3º set em super tie-break de 10',  2, 6, true,  2),
  ('set_unico',         'Set único até 6 games (tie-break em 6-6)',           1, 6, false, 3),
  ('set_curto',         'Set curto até 4 games (tie-break em 4-4)',           1, 4, false, 4),
  ('match_tb_10',       'Match tie-break de 10 pontos',                       1, 0, false, 5)
on conflict (id) do nothing;

create table if not exists public.categories (
  id serial primary key, name text not null unique, min_points int not null default 0,
  sort int not null default 0, active boolean not null default true
);
insert into public.categories (name, min_points, sort) values
  ('Iniciante', 0, 1), ('Intermediário', 200, 2), ('Avançado', 500, 3)
on conflict (name) do nothing;

alter table public.match_formats enable row level security;
alter table public.categories enable row level security;
drop policy if exists "mf_read" on public.match_formats;
create policy "mf_read" on public.match_formats for select using (true);
drop policy if exists "cat_read" on public.categories;
create policy "cat_read" on public.categories for select using (true);
grant select on public.match_formats, public.categories to anon, authenticated;

-- ===================== REGISTROS =====================
create table if not exists public.ratings (
  player uuid not null references public.profiles(id) on delete cascade,
  modality text not null,
  elo numeric not null default 1000, points int not null default 0,
  games int not null default 0, wins int not null default 0, losses int not null default 0,
  best_pos int, updated_at timestamptz not null default now(),
  primary key (player, modality)
);
create table if not exists public.pairs (
  a uuid not null references public.profiles(id) on delete cascade,
  b uuid not null references public.profiles(id) on delete cascade,
  elo numeric not null default 1000, points int not null default 0,
  games int not null default 0, wins int not null default 0, losses int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (a, b), check (a < b)
);
create table if not exists public.rating_log (
  id uuid primary key default gen_random_uuid(),
  game uuid not null references public.games(id) on delete cascade,
  player uuid not null references public.profiles(id) on delete cascade,
  modality text not null,
  elo_before numeric, elo_after numeric, points_before int, points_after int,
  delta int, expected numeric, k int, weight numeric, won boolean, reason text,
  reverted boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists rating_log_player_idx on public.rating_log (player, modality, created_at desc);
create index if not exists rating_log_game_idx on public.rating_log (game);
create table if not exists public.pair_log (
  id uuid primary key default gen_random_uuid(),
  game uuid not null references public.games(id) on delete cascade,
  a uuid not null, b uuid not null,
  elo_before numeric, elo_after numeric, points_before int, points_after int, won boolean,
  reverted boolean not null default false, created_at timestamptz not null default now()
);
create table if not exists public.rank_snapshots (
  snap_date date not null, modality text not null, player uuid not null,
  pos int not null, points int not null,
  primary key (snap_date, modality, player)
);
create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  at timestamptz not null default now(), actor uuid, action text not null,
  entity text, entity_id uuid, detail jsonb
);
create index if not exists audit_log_idx on public.audit_log (entity, entity_id, at desc);

alter table public.ratings enable row level security;
alter table public.pairs enable row level security;
alter table public.rating_log enable row level security;
alter table public.pair_log enable row level security;
alter table public.rank_snapshots enable row level security;
alter table public.audit_log enable row level security;
drop policy if exists "audit_admin" on public.audit_log;
create policy "audit_admin" on public.audit_log for select to authenticated using (public.is_admin());
drop policy if exists "log_own" on public.rating_log;
create policy "log_own" on public.rating_log for select to authenticated using (player = auth.uid() or public.is_admin());
grant select on public.audit_log, public.rating_log to authenticated;

create or replace function public._audit(p_action text, p_entity text, p_id uuid, p_detail jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_log(actor, action, entity, entity_id, detail) values (auth.uid(), p_action, p_entity, p_id, p_detail)
$$;
revoke execute on function public._audit(text, text, uuid, jsonb) from public, anon, authenticated;

-- ===================== NÍVEL, CATEGORIA E GÊNERO =====================
create or replace function public._guest_elo(lv text) returns numeric language sql immutable as $$
  select 1000 + case lv when 'Avançado' then 100 when 'Iniciante' then -100 else 0 end
$$;

-- novo jogador: 0 pontos, Elo 1000, categoria provisória = nível informado
create or replace function public.trg_profile_new() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role = 'jogador' and not coalesce(new.is_admin, false) then
    new.rank := 0; new.elo := 1000;
  end if;
  new.category := coalesce(nullif(new.category, ''), new.level);
  return new;
end $$;
drop trigger if exists profiles_base_rating on public.profiles;
drop trigger if exists profiles_new on public.profiles;
create trigger profiles_new before insert on public.profiles for each row execute function public.trg_profile_new();

-- ninguém muda o nível depois do 1º jogo (só o administrador ou o próprio ranking)
create or replace function public.trg_level_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.level is distinct from old.level and coalesce(current_setting('app.engine', true), '') <> 'on' and not coalesce(public.is_admin(), false) then
    if exists (select 1 from public.games g where g.done and not g.cancelled and (g.a = new.id or g.b = new.id or g.a2 = new.id or g.b2 = new.id)) then
      raise exception 'O nível agora é definido pelo ranking. Fale com o administrador se precisar corrigir.';
    end if;
    new.category := new.level;
  end if;
  return new;
end $$;
drop trigger if exists profiles_level_guard on public.profiles;
create trigger profiles_level_guard before update of level on public.profiles for each row execute function public.trg_level_guard();

-- pontos alterados fora do motor (bônus de torneio, base fictícia, administrador) acompanham o Elo interno
create or replace function public.trg_rank_sync() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.rank is distinct from old.rank and coalesce(current_setting('app.engine', true), '') <> 'on' then
    new.elo := old.elo + (new.rank - old.rank);
  end if;
  return new;
end $$;
drop trigger if exists profiles_rank_sync on public.profiles;
create trigger profiles_rank_sync before update of rank on public.profiles for each row execute function public.trg_rank_sync();

-- ninguém altera a própria pontuação pelo app
revoke update (rank, elo, category, cat_pending, cat_streak, best_pos) on public.profiles from authenticated, anon;

-- categoria acompanha os pontos (5 partidas confirmadas; mudança só após 2 partidas seguidas na nova faixa)
create or replace function public._update_category(p_uid uuid) returns void language plpgsql security definer set search_path = public as $$
declare pr public.profiles; target text; n int;
begin
  select * into pr from public.profiles where id = p_uid;
  if not found or pr.role <> 'jogador' then return; end if;
  select count(*) into n from public.rating_log where player = p_uid and modality = 'individual' and not reverted;
  if n < 5 then return; end if;
  select name into target from public.categories where active and min_points <= pr.rank order by min_points desc limit 1;
  if target is null or target = coalesce(pr.category, pr.level) then
    update public.profiles set cat_pending = null, cat_streak = 0 where id = p_uid and (cat_pending is not null or cat_streak <> 0);
    return;
  end if;
  if pr.cat_pending = target then
    if pr.cat_streak + 1 >= 2 then
      perform set_config('app.engine', 'on', true);
      update public.profiles set category = target, level = target, cat_pending = null, cat_streak = 0 where id = p_uid;
      perform set_config('app.engine', 'off', true);
      perform public._audit('categoria_alterada', 'profile', p_uid, jsonb_build_object('de', pr.category, 'para', target, 'pontos', pr.rank));
    else
      update public.profiles set cat_streak = pr.cat_streak + 1 where id = p_uid;
    end if;
  else
    update public.profiles set cat_pending = target, cat_streak = 1 where id = p_uid;
  end if;
end $$;
revoke execute on function public._update_category(uuid) from public, anon, authenticated;

-- ===================== VALIDAÇÃO DO PLACAR =====================
-- placar escrito do ponto de vista do VENCEDOR: "6-3 4-6 7-6(5)" ou super tie-break "[10-7]"
create or replace function public.check_score(p_fmt text, p_score text) returns text
language plpgsql stable set search_path = public as $$
declare f public.match_formats; toks text[]; t text; i int := 0; a int; b int; sw int := 0; sl int := 0; g int; m text[]; n int;
begin
  if nullif(btrim(coalesce(p_score, '')), '') is null then return null; end if;
  select * into f from public.match_formats where id = coalesce(p_fmt, 'melhor_de_3');
  if not found then return 'Formato de partida desconhecido.'; end if;
  toks := regexp_split_to_array(btrim(p_score), '\s+');
  n := array_length(toks, 1);
  g := f.games_per_set;
  foreach t in array toks loop
    i := i + 1;
    if sw >= f.sets_to_win or sl >= f.sets_to_win then return 'O placar tem sets depois de a partida já estar decidida.'; end if;
    m := regexp_match(t, '^\[(\d+)-(\d+)\]$');
    if m is not null then
      a := m[1]::int; b := m[2]::int;
      if not (f.games_per_set = 0 or (f.super_final and sw = f.sets_to_win - 1 and sl = f.sets_to_win - 1)) then
        return 'Super tie-break só vale como set decisivo neste formato.';
      end if;
      if greatest(a, b) < 10 or abs(a - b) < 2 or (greatest(a, b) > 10 and abs(a - b) <> 2) then return 'Super tie-break inválido: precisa chegar a 10 pontos com 2 de diferença.'; end if;
      if a > b then sw := sw + 1; else sl := sl + 1; end if;
      continue;
    end if;
    if f.games_per_set = 0 then return 'Este formato usa só o match tie-break de 10 pontos, ex.: [10-7].'; end if;
    m := regexp_match(t, '^(\d+)-(\d+)(?:\((\d+)\))?$');
    if m is null then return 'Placar inválido: use o formato 6-3 4-6 7-6(5) ou [10-7].'; end if;
    a := m[1]::int; b := m[2]::int;
    if not ((greatest(a, b) = g and least(a, b) <= g - 2)
         or (greatest(a, b) = g + 1 and least(a, b) in (g - 1, g))) then
      return 'Set ' || i || ' impossível neste formato (' || t || ').';
    end if;
    if a > b then sw := sw + 1; else sl := sl + 1; end if;
  end loop;
  if sw < f.sets_to_win then return 'O placar não mostra a vitória de quem ganhou (faltam sets).'; end if;
  if sl >= f.sets_to_win then return 'O placar está inconsistente com o vencedor.'; end if;
  return null;
end $$;
grant execute on function public.check_score(text, text) to authenticated;

-- ===================== MOTOR DE PONTUAÇÃO =====================
create or replace function public._apply_rating(p_game uuid, p_mod text, p_uid uuid, p_own numeric, p_opp numeric, p_won boolean, p_w numeric) returns int
language plpgsql security definer set search_path = public as $$
declare k int; e numeric; raw numeric; dpts int; cnt int; pr_rank int; pr_elo numeric; new_pts int; why text;
begin
  select count(*) into cnt from public.rating_log where player = p_uid and modality = p_mod and not reverted;
  k := case when cnt < 10 then 40 else 32 end;
  e := 1 / (1 + power(10, (p_opp - p_own) / 400.0));
  raw := k * ((case when p_won then 1 else 0 end) - e) * p_w;
  dpts := case when raw >= 0 then greatest(1, round(raw)::int) else least(-1, round(raw)::int) end;
  if p_mod = 'individual' then
    select rank, elo into pr_rank, pr_elo from public.profiles where id = p_uid for update;
    new_pts := greatest(0, coalesce(pr_rank, 0) + dpts);
    perform set_config('app.engine', 'on', true);
    update public.profiles set rank = new_pts, elo = round(pr_elo + raw, 2) where id = p_uid;
    perform set_config('app.engine', 'off', true);
  else
    insert into public.ratings(player, modality) values (p_uid, p_mod) on conflict do nothing;
    select points, elo into pr_rank, pr_elo from public.ratings where player = p_uid and modality = p_mod for update;
    new_pts := greatest(0, pr_rank + dpts);
    update public.ratings set points = new_pts, elo = round(pr_elo + raw, 2), games = games + 1,
           wins = wins + (case when p_won then 1 else 0 end), losses = losses + (case when p_won then 0 else 1 end), updated_at = now()
     where player = p_uid and modality = p_mod;
  end if;
  why := case when p_won then 'Vitória' else 'Derrota' end || ' contra ' ||
         case when e < 0.4 then 'adversários mais fortes' when e > 0.6 then 'adversários mais fracos' else 'adversários de nível parecido' end ||
         ' (chance de vitória ' || round(e * 100) || '%)' ||
         case when p_w < 1 then ' · peso reduzido (' || round(p_w * 100) || '%) por jogos repetidos ou desfecho' else '' end;
  insert into public.rating_log(game, player, modality, elo_before, elo_after, points_before, points_after, delta, expected, k, weight, won, reason)
  values (p_game, p_uid, p_mod, pr_elo, round(pr_elo + raw, 2), pr_rank, new_pts, new_pts - pr_rank, round(e, 4), k, p_w, p_won, why);
  return new_pts - pr_rank;
end $$;
revoke execute on function public._apply_rating(uuid, text, uuid, numeric, numeric, boolean, numeric) from public, anon, authenticated;

create or replace function public._apply_pair(p_game uuid, p_x uuid, p_y uuid, p_opp numeric, p_won boolean, p_w numeric) returns void
language plpgsql security definer set search_path = public as $$
declare pa uuid := least(p_x, p_y); pb uuid := greatest(p_x, p_y); pr public.pairs; k int; e numeric; raw numeric; dpts int; new_pts int;
begin
  insert into public.pairs(a, b) values (pa, pb) on conflict do nothing;
  select * into pr from public.pairs where a = pa and b = pb for update;
  k := case when pr.games < 10 then 40 else 32 end;
  e := 1 / (1 + power(10, (p_opp - pr.elo) / 400.0));
  raw := k * ((case when p_won then 1 else 0 end) - e) * p_w;
  dpts := case when raw >= 0 then greatest(1, round(raw)::int) else least(-1, round(raw)::int) end;
  new_pts := greatest(0, pr.points + dpts);
  update public.pairs set elo = round(pr.elo + raw, 2), points = new_pts, games = games + 1,
         wins = wins + (case when p_won then 1 else 0 end), losses = losses + (case when p_won then 0 else 1 end), updated_at = now()
   where a = pa and b = pb;
  insert into public.pair_log(game, a, b, elo_before, elo_after, points_before, points_after, won)
  values (p_game, pa, pb, pr.elo, round(pr.elo + raw, 2), pr.points, new_pts, p_won);
end $$;
revoke execute on function public._apply_pair(uuid, uuid, uuid, numeric, boolean, numeric) from public, anon, authenticated;

create or replace function public._pelo(p_uid uuid, p_name text, p_level text, p_mod text) returns numeric
language sql stable security definer set search_path = public as $$
  select case
    when p_uid is null then public._guest_elo(p_level)
    when p_mod = 'individual' then coalesce((select elo from public.profiles where id = p_uid), 1000)
    else coalesce((select elo from public.ratings where player = p_uid and modality = p_mod), 1000) end
$$;
revoke execute on function public._pelo(uuid, text, text, text) from public, anon, authenticated;

create or replace function public._finish_game(g uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.games; l uuid; n int; n30 int; wgt numeric; ow numeric; win_a boolean;
  ga text; ga2 text; gb text; gb2 text; mods text[]; m text; ds jsonb := '{}'::jsonb; d int;
  ea numeric; ea2 numeric; eb numeric; eb2 numeric; avga numeric; avgb numeric; is_d boolean; pa1 numeric; pb1 numeric; po numeric;
begin
  select * into r from public.games where id = g and done = false and winner is not null and not cancelled and not disputed for update;
  if not found then return; end if;
  l := case when r.winner = r.a then r.b else r.a end;
  update public.games set done = true where id = g;
  if not r.ranked or r.outcome = 'void' then return; end if;
  ow := case r.outcome when 'desistencia' then 0.75 when 'wo' then 0.5 else 1 end;

  select count(*) into n from public.games x
   where x.done and x.ranked and not x.cancelled and x.winner is not null and x.id <> g
     and ((x.a = r.a and x.b = r.b) or (x.a = r.b and x.b = r.a)) and x.day >= r.day - 7;
  select count(*) into n30 from public.games x
   where x.done and x.ranked and not x.cancelled and x.winner is not null and x.id <> g
     and ((x.a = r.a and x.b = r.b) or (x.a = r.b and x.b = r.a)) and x.day >= r.day - 30;
  wgt := (case when n < 2 then 1 when n < 4 then 0.5 else 0.25 end) * ow;
  if n >= 4 or n30 >= 8 then update public.games set suspicious = true where id = g; end if;
  win_a := (r.winner = r.a);
  is_d := coalesce(r.format, '') in ('duplas', 'quarteto') and (r.a2 is not null or r.b2 is not null or r.a2_name is not null or r.b2_name is not null);

  if not is_d then
    po := public._pelo(l, null, null, 'individual');
    pa1 := public._pelo(r.winner, null, null, 'individual');
    d := public._apply_rating(g, 'individual', r.winner, pa1, po, true, wgt);
    ds := ds || jsonb_build_object(r.winner::text, d);
    d := public._apply_rating(g, 'individual', l, po, pa1, false, wgt);
    ds := ds || jsonb_build_object(l::text, d);
    update public.games set modality = 'individual', deltas = ds,
           delta_w = (ds ->> r.winner::text)::int, delta_l = (ds ->> l::text)::int where id = g;
  else
    -- modalidade pelo gênero dos 4 jogadores (só quando todos são conhecidos)
    select gender into ga from public.profiles where id = r.a;
    select gender into gb from public.profiles where id = r.b;
    ga2 := case when r.a2 is not null then (select gender from public.profiles where id = r.a2) else r.a2_gender end;
    gb2 := case when r.b2 is not null then (select gender from public.profiles where id = r.b2) else r.b2_gender end;
    mods := array['individual', 'duplas'];
    if ga is not null and gb is not null and ga2 is not null and gb2 is not null then
      if ga = 'M' and gb = 'M' and ga2 = 'M' and gb2 = 'M' then mods := mods || 'duplas_masc'::text;
      elsif ga = 'F' and gb = 'F' and ga2 = 'F' and gb2 = 'F' then mods := mods || 'duplas_fem'::text;
      elsif ga <> ga2 and gb <> gb2 then mods := mods || 'duplas_mista'::text;
      end if;
    end if;
    foreach m in array mods loop
      ea  := public._pelo(r.a, null, null, m);
      eb  := public._pelo(r.b, null, null, m);
      ea2 := public._pelo(r.a2, r.a2_name, r.a2_level, m);
      eb2 := public._pelo(r.b2, r.b2_name, r.b2_level, m);
      avga := (ea + ea2) / 2; avgb := (eb + eb2) / 2;
      d := public._apply_rating(g, m, r.a,  ea,  avgb, win_a, wgt);
      if m = 'individual' then ds := ds || jsonb_build_object(r.a::text, d); end if;
      d := public._apply_rating(g, m, r.b,  eb,  avga, not win_a, wgt);
      if m = 'individual' then ds := ds || jsonb_build_object(r.b::text, d); end if;
      if r.a2 is not null then
        d := public._apply_rating(g, m, r.a2, ea2, avgb, win_a, wgt);
        if m = 'individual' then ds := ds || jsonb_build_object(r.a2::text, d); end if;
      end if;
      if r.b2 is not null then
        d := public._apply_rating(g, m, r.b2, eb2, avga, not win_a, wgt);
        if m = 'individual' then ds := ds || jsonb_build_object(r.b2::text, d); end if;
      end if;
    end loop;
    -- duplas fixas (só quando os dois da dupla têm cadastro)
    if r.a2 is not null and r.b2 is not null then
      pa1 := coalesce((select elo from public.pairs where a = least(r.a, r.a2) and b = greatest(r.a, r.a2)), 1000);
      pb1 := coalesce((select elo from public.pairs where a = least(r.b, r.b2) and b = greatest(r.b, r.b2)), 1000);
      perform public._apply_pair(g, r.a, r.a2, pb1, win_a, wgt);
      perform public._apply_pair(g, r.b, r.b2, pa1, not win_a, wgt);
    elsif r.a2 is not null or r.b2 is not null then
      null; -- dupla fixa exige os dois jogadores cadastrados
    end if;
    update public.games set modality = mods[array_length(mods, 1)], deltas = ds,
           delta_w = (ds ->> r.winner::text)::int, delta_l = (ds ->> l::text)::int where id = g;
  end if;

  perform public._update_category(r.a); perform public._update_category(r.b);
  if r.a2 is not null then perform public._update_category(r.a2); end if;
  if r.b2 is not null then perform public._update_category(r.b2); end if;
  perform public._audit('ranking_aplicado', 'game', g, jsonb_build_object('peso', wgt, 'deltas', ds, 'suspeita', n >= 4 or n30 >= 8));
end $$;
revoke execute on function public._finish_game(uuid) from public, anon, authenticated;

-- desfaz o efeito de uma partida (anulação pelo administrador)
create or replace function public._revert_game(g uuid) returns void
language plpgsql security definer set search_path = public as $$
declare x record;
begin
  perform set_config('app.engine', 'on', true);
  for x in select * from public.rating_log where game = g and not reverted loop
    if x.modality = 'individual' then
      update public.profiles set rank = greatest(0, rank - x.delta), elo = round(elo - (x.elo_after - x.elo_before), 2) where id = x.player;
    else
      update public.ratings set points = greatest(0, points - x.delta), elo = round(elo - (x.elo_after - x.elo_before), 2),
             games = greatest(0, games - 1), wins = greatest(0, wins - (case when x.won then 1 else 0 end)),
             losses = greatest(0, losses - (case when x.won then 0 else 1 end)) where player = x.player and modality = x.modality;
    end if;
    update public.rating_log set reverted = true where id = x.id;
  end loop;
  for x in select * from public.pair_log where game = g and not reverted loop
    update public.pairs set points = greatest(0, points - (x.points_after - x.points_before)), elo = round(elo - (x.elo_after - x.elo_before), 2),
           games = greatest(0, games - 1), wins = greatest(0, wins - (case when x.won then 1 else 0 end)),
           losses = greatest(0, losses - (case when x.won then 0 else 1 end)) where a = x.a and b = x.b;
    update public.pair_log set reverted = true where id = x.id;
  end loop;
  perform set_config('app.engine', 'off', true);
end $$;
revoke execute on function public._revert_game(uuid) from public, anon, authenticated;

-- ===================== REGISTRO, CONFIRMAÇÃO E CONTESTAÇÃO =====================
drop function if exists public.report_result(uuid, uuid, text);
create or replace function public.report_result(g uuid, w uuid, p_score text default null, p_outcome text default 'normal', p_format text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.games; sc text; fmt text; oc text := coalesce(p_outcome, 'normal'); err text;
begin
  select * into r from public.games where id = g and done = false and not cancelled;
  if not found then raise exception 'Jogo não encontrado ou já encerrado'; end if;
  if r.disputed then raise exception 'Este resultado está em análise.'; end if;
  if auth.uid() not in (r.a, r.b) then raise exception 'Você não participa deste jogo'; end if;
  if w not in (r.a, r.b) then raise exception 'Vencedor inválido'; end if;
  if oc not in ('normal', 'wo', 'desistencia', 'void') then raise exception 'Desfecho inválido'; end if;
  fmt := coalesce(nullif(p_format, ''), r.match_format, 'melhor_de_3');
  sc := nullif(left(btrim(coalesce(p_score, '')), 60), '');
  if sc is not null and sc !~ '^[0-9()\[\] -]+$' then raise exception 'Placar inválido'; end if;
  if oc = 'normal' then
    err := public.check_score(fmt, sc);
    if err is not null then raise exception '%', err; end if;
  elsif oc = 'wo' then sc := null;
  end if;
  update public.games set winner = w, reported_by = auth.uid(), reported_at = now(), score = sc, match_format = fmt, outcome = oc where id = g;
  perform public._audit('resultado_informado', 'game', g, jsonb_build_object('vencedor', w, 'placar', sc, 'formato', fmt, 'desfecho', oc));
end $$;
revoke execute on function public.report_result(uuid, uuid, text, text, text) from public, anon;
grant execute on function public.report_result(uuid, uuid, text, text, text) to authenticated;

create or replace function public.confirm_result(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.games;
begin
  select * into r from public.games where id = g and done = false and winner is not null and not cancelled;
  if not found then raise exception 'Nenhum resultado aguardando confirmação'; end if;
  if r.disputed then raise exception 'Este resultado está em análise pelo administrador.'; end if;
  if auth.uid() not in (r.a, r.b) or auth.uid() = r.reported_by then raise exception 'Só o outro jogador pode confirmar'; end if;
  perform public._audit('resultado_confirmado', 'game', g, '{}'::jsonb);
  perform public._finish_game(g);
end $$;
revoke execute on function public.confirm_result(uuid) from public, anon;
grant execute on function public.confirm_result(uuid) to authenticated;

-- contestar: o resultado fica em análise (o administrador decide) e ninguém pontua até lá
drop function if exists public.contest_result(uuid);
create or replace function public.contest_result(g uuid, p_note text default null) returns void language plpgsql security definer set search_path = public as $$
declare r public.games;
begin
  select * into r from public.games where id = g and done = false and winner is not null and not cancelled;
  if not found then raise exception 'Nenhum resultado para contestar'; end if;
  if auth.uid() not in (r.a, r.b) or auth.uid() = r.reported_by then raise exception 'Só o outro jogador pode contestar'; end if;
  if r.reported_at is not null and r.reported_at < now() - interval '48 hours' then raise exception 'O prazo para contestar acabou.'; end if;
  update public.games set disputed = true, dispute_note = left(nullif(btrim(coalesce(p_note, '')), ''), 300), disputed_by = auth.uid() where id = g;
  perform public._audit('resultado_contestado', 'game', g, jsonb_build_object('nota', left(coalesce(p_note, ''), 300)));
  perform public.push_send(null, '⚖️ Resultado contestado', 'Um resultado foi contestado e espera a sua análise.', true);
end $$;
revoke execute on function public.contest_result(uuid, text) from public, anon;
grant execute on function public.contest_result(uuid, text) to authenticated;

-- quem informou pode retirar o resultado (os dois combinam de novo)
create or replace function public.retract_result(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.games;
begin
  select * into r from public.games where id = g and done = false and winner is not null and not cancelled;
  if not found then raise exception 'Nenhum resultado para retirar'; end if;
  if auth.uid() is distinct from r.reported_by then raise exception 'Só quem informou o resultado pode retirá-lo'; end if;
  update public.games set winner = null, reported_by = null, reported_at = null, score = null, disputed = false, dispute_note = null, disputed_by = null, outcome = 'normal' where id = g;
  perform public._audit('resultado_retirado', 'game', g, '{}'::jsonb);
end $$;
revoke execute on function public.retract_result(uuid) from public, anon;
grant execute on function public.retract_result(uuid) to authenticated;

-- resultados sem resposta em 48h valem, exceto os contestados
create or replace function public.finalize_expired() returns int language plpgsql security definer set search_path = public as $$
declare x record; n int := 0;
begin
  for x in select id from public.games where done = false and winner is not null and not disputed and not cancelled and reported_at < now() - interval '48 hours' loop
    perform public._finish_game(x.id); n := n + 1;
  end loop;
  perform public.finalize_payments();
  perform public.cleanup_expired();
  return n;
end $$;

-- ===================== ADMINISTRADOR =====================
create or replace function public.admin_resolve_game(p_game uuid, p_action text, p_winner uuid default null, p_score text default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.games; err text;
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  select * into r from public.games where id = p_game;
  if not found then raise exception 'Jogo não encontrado.'; end if;
  if p_action = 'confirmar' then
    if r.winner is null then raise exception 'Este jogo ainda não tem resultado.'; end if;
    update public.games set disputed = false where id = p_game;
    perform public._finish_game(p_game);
  elsif p_action = 'corrigir' then
    if p_winner is null or p_winner not in (r.a, r.b) then raise exception 'Escolha o vencedor entre os dois capitães.'; end if;
    if r.done then perform public._revert_game(p_game); update public.games set done = false where id = p_game; end if;
    err := public.check_score(r.match_format, nullif(btrim(coalesce(p_score, '')), ''));
    if err is not null then raise exception '%', err; end if;
    update public.games set winner = p_winner, score = nullif(btrim(coalesce(p_score, '')), ''), disputed = false, reported_by = coalesce(reported_by, auth.uid()), reported_at = coalesce(reported_at, now()), cancelled = false where id = p_game;
    perform public._finish_game(p_game);
  elsif p_action = 'anular' then
    if r.done then perform public._revert_game(p_game); end if;
    update public.games set cancelled = true, done = true, disputed = false where id = p_game;
  else
    raise exception 'Ação inválida.';
  end if;
  perform public._audit('admin_' || p_action, 'game', p_game, jsonb_build_object('vencedor', p_winner, 'placar', p_score, 'nota', p_note));
end $$;
revoke execute on function public.admin_resolve_game(uuid, text, uuid, text, text) from public, anon;
grant execute on function public.admin_resolve_game(uuid, text, uuid, text, text) to authenticated;

create or replace function public.admin_review_queue() returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  return (select coalesce(json_agg(x order by x.day desc), '[]'::json) from (
    select g.id, g.day, g.time, g.local, g.score, g.winner, g.disputed, g.dispute_note, g.suspicious, g.done, g.match_format, g.outcome,
           g.a, g.b, g.a2, g.b2, g.a2_name, g.b2_name, g.reported_by
      from public.games g
     where not g.cancelled and (g.disputed or (g.suspicious and g.done and g.day >= current_date - 60))
     order by g.day desc limit 60) x);
end $$;
revoke execute on function public.admin_review_queue() from public, anon;
grant execute on function public.admin_review_queue() to authenticated;

create or replace function public.admin_save_category(p_name text, p_min int, p_sort int default 0, p_active boolean default true) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  if nullif(btrim(p_name), '') is null or p_min < 0 then raise exception 'Informe o nome e uma pontuação mínima válida.'; end if;
  insert into public.categories(name, min_points, sort, active) values (btrim(p_name), p_min, p_sort, p_active)
  on conflict (name) do update set min_points = excluded.min_points, sort = excluded.sort, active = excluded.active;
  perform public._audit('categoria_salva', 'categoria', null, jsonb_build_object('nome', p_name, 'minimo', p_min, 'ativa', p_active));
end $$;
revoke execute on function public.admin_save_category(text, int, int, boolean) from public, anon;
grant execute on function public.admin_save_category(text, int, int, boolean) to authenticated;

create or replace function public.admin_set_level(p_user uuid, p_level text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  perform set_config('app.engine', 'on', true);
  update public.profiles set level = p_level, category = p_level, cat_pending = null, cat_streak = 0 where id = p_user;
  perform set_config('app.engine', 'off', true);
  perform public._audit('nivel_definido_pelo_admin', 'profile', p_user, jsonb_build_object('nivel', p_level));
end $$;
revoke execute on function public.admin_set_level(uuid, text) from public, anon;
grant execute on function public.admin_set_level(uuid, text) to authenticated;

-- ===================== CONSULTAS DO APP =====================
create or replace function public.take_rank_snapshot() returns int language plpgsql security definer set search_path = public as $$
declare m text; n int := 0;
begin
  delete from public.rank_snapshots where snap_date = current_date;
  insert into public.rank_snapshots(snap_date, modality, player, pos, points)
    select current_date, 'individual', p.id, row_number() over (order by p.rank desc, p.elo desc, p.name), p.rank
      from public.profiles p where p.role = 'jogador' and not p.is_admin;
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
         where p.role = 'jogador' and not p.is_admin
           and (p_mod = 'individual' or r.player is not null)
           and (p_cat is null or p.category = p_cat)
           and (p_city is null or lower(split_part(coalesce(p.city, ''), '/', 1)) = lower(split_part(p_city, '/', 1)))
      ) x
      left join public.rank_snapshots s on s.snap_date = snap and s.modality = p_mod and s.player = x.id
     order by pos limit greatest(1, least(p_limit, 500))) t);
end $$;
revoke execute on function public.ranking_board(text, text, text, int, int) from public, anon;
grant execute on function public.ranking_board(text, text, text, int, int) to authenticated;

create or replace function public.pair_board(p_city text default null, p_limit int default 100) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Entre para ver o ranking.'; end if;
  return (select coalesce(json_agg(t order by t.pos), '[]'::json) from (
    select row_number() over (order by pr.points desc, pr.elo desc, pr.wins desc) as pos,
           pr.a, pr.b, pa.name as name_a, pb.name as name_b, pa.photo_url as photo_a, pb.photo_url as photo_b,
           pr.points, pr.games, pr.wins, pr.losses,
           case when pr.games > 0 then round(pr.wins * 100.0 / pr.games) else 0 end as win_pct
      from public.pairs pr
      join public.profiles pa on pa.id = pr.a join public.profiles pb on pb.id = pr.b
     where pr.games > 0
       and (p_city is null or lower(split_part(coalesce(pa.city, ''), '/', 1)) = lower(split_part(p_city, '/', 1)))
     order by pos limit greatest(1, least(p_limit, 500))) t);
end $$;
revoke execute on function public.pair_board(text, int) from public, anon;
grant execute on function public.pair_board(text, int) to authenticated;

create or replace function public.my_history(p_mod text default 'individual', p_limit int default 60) returns json
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Entre para ver o histórico.'; end if;
  return (select coalesce(json_agg(t order by t.created_at desc), '[]'::json) from (
    select l.created_at, l.modality, l.points_before, l.points_after, l.delta, l.reason, l.won, l.reverted,
           g.day, g.time, g.local, g.score, g.format, g.suspicious,
           (select name from public.profiles where id = case when me in (g.a, g.a2) then g.b else g.a end) as opp,
           (select name from public.profiles where id = case when me = g.a then g.a2 when me = g.a2 then g.a when me = g.b then g.b2 else g.b end) as partner,
           coalesce(case when me = g.a then g.a2_name when me = g.b then g.b2_name end, null) as partner_guest
      from public.rating_log l join public.games g on g.id = l.game
     where l.player = me and l.modality = p_mod
     order by l.created_at desc limit greatest(1, least(p_limit, 200))) t);
end $$;
revoke execute on function public.my_history(text, int) from public, anon;
grant execute on function public.my_history(text, int) to authenticated;

-- ===================== PARTIDAS DUPLICADAS =====================
create or replace function public.trg_games_dup() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.done then return new; end if;
  if exists (select 1 from public.games x where not x.cancelled and x.day = new.day and x.time = new.time
             and ((x.a = new.a and x.b = new.b) or (x.a = new.b and x.b = new.a))) then
    raise exception 'Já existe uma partida marcada entre vocês neste dia e horário.';
  end if;
  return new;
end $$;
drop trigger if exists games_dup on public.games;
create trigger games_dup before insert on public.games for each row execute function public.trg_games_dup();

-- ===================== MIGRAÇÃO (uma vez) =====================
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'ranking_v2') then
    perform set_config('app.engine', 'on', true);
    update public.profiles
       set elo = 1000 + greatest(0, coalesce(rank, 0) - public._base_rating(level)),
           rank = greatest(0, coalesce(rank, 0) - public._base_rating(level)),
           category = coalesce(category, level)
     where role = 'jogador' and not coalesce(is_admin, false);
    perform set_config('app.engine', 'off', true);
    insert into public.app_settings(key, value) values ('ranking_v2', now()::text);
  end if;
end $$;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'rank-snapshot') then perform cron.unschedule('rank-snapshot'); end if;
exception when others then null; end $$;
select cron.schedule('rank-snapshot', '0 11 * * 1', 'select public.take_rank_snapshot()');

-- ===================== COMPLEMENTO: gênero do parceiro, leitura de colunas e emoji =====================
grant select (gender, category, best_pos) on public.profiles to authenticated;

alter table public.invites  add column if not exists partner_gender text;
alter table public.requests add column if not exists partner_gender text;

-- gênero do parceiro: vem do perfil (cadastrado) ou do que foi informado (sem cadastro, opcional)
create or replace function public.trg_games_partners_gender() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.a2 is not null then select gender into new.a2_gender from public.profiles where id = new.a2;
  elsif new.a2_gender is not null and new.a2_gender not in ('M', 'F') then new.a2_gender := null; end if;
  if new.b2 is not null then select gender into new.b2_gender from public.profiles where id = new.b2;
  elsif new.b2_gender is not null and new.b2_gender not in ('M', 'F') then new.b2_gender := null; end if;
  return new;
end $$;
drop trigger if exists games_partners_gender on public.games;
create trigger games_partners_gender before insert on public.games for each row execute function public.trg_games_partners_gender();
