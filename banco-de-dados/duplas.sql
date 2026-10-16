-- =====================================================================
-- Jogos em DUPLAS (formatos "Dupla fechada" e "Duplas · 4 jogadores")
--  * Cada lado tem um capitão (quem publica ou pede o convite) e um parceiro
--  * O parceiro pode ser cadastrado (ganha ou perde pontos) ou sem cadastro (só nome e nível)
--  * Pontos por jogador: cada um é comparado com a MÉDIA da dupla adversária, usando a própria pontuação
--    (quem é mais forte ganha menos ao vencer e perde mais ao perder; parceiro sem cadastro entra pelo nível)
--  * O capitão continua sendo quem informa e confirma o resultado
-- Pré-requisito: nome-unico.sql e ranking-elo.sql já aplicados.
-- Cole no SQL Editor e clique em Run. Pode rodar mais de uma vez.
-- =====================================================================

-- ----- colunas -----
alter table public.invites  add column if not exists partner uuid references public.profiles(id) on delete set null;
alter table public.invites  add column if not exists partner_name text;
alter table public.invites  add column if not exists partner_level text;
alter table public.requests add column if not exists partner uuid references public.profiles(id) on delete set null;
alter table public.requests add column if not exists partner_name text;
alter table public.requests add column if not exists partner_level text;
alter table public.games add column if not exists a2 uuid references public.profiles(id) on delete set null;
alter table public.games add column if not exists b2 uuid references public.profiles(id) on delete set null;
alter table public.games add column if not exists a2_name text;
alter table public.games add column if not exists b2_name text;
alter table public.games add column if not exists a2_level text;
alter table public.games add column if not exists b2_level text;
alter table public.games add column if not exists deltas jsonb;

-- o parceiro cadastrado também enxerga a partida
drop policy if exists "games_select" on public.games;
create policy "games_select" on public.games for select to authenticated
  using (a = auth.uid() or b = auth.uid() or a2 = auth.uid() or b2 = auth.uid());

-- ----- validação dos parceiros ao criar o jogo -----
create or replace function public.trg_games_partners() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  side text; uid uuid; gname text; glevel text; pn text; pl text;
  names text[] := '{}'; ids uuid[] := array[new.a, new.b];
begin
  if coalesce(new.format, '') not in ('duplas', 'quarteto') then
    new.a2 := null; new.b2 := null; new.a2_name := null; new.b2_name := null; new.a2_level := null; new.b2_level := null;
    return new;
  end if;
  -- sem nenhum parceiro informado: jogo antigo, segue como está
  if new.a2 is null and new.b2 is null
     and nullif(btrim(coalesce(new.a2_name, '')), '') is null and nullif(btrim(coalesce(new.b2_name, '')), '') is null then
    return new;
  end if;
  foreach side in array array['a', 'b'] loop
    uid    := case side when 'a' then new.a2 else new.b2 end;
    gname  := nullif(btrim(coalesce(case side when 'a' then new.a2_name else new.b2_name end, '')), '');
    glevel := case side when 'a' then new.a2_level else new.b2_level end;
    if uid is null and gname is null then
      raise exception 'Informe o parceiro de cada dupla.';
    end if;
    if uid is not null then
      select name, level into pn, pl from public.profiles where id = uid;
      if pn is null then raise exception 'Parceiro não encontrado.'; end if;
      if uid = any(ids) then raise exception 'O mesmo jogador não pode aparecer duas vezes na partida.'; end if;
      ids := ids || uid; gname := pn; glevel := pl;
    else
      if char_length(gname) < 2 then raise exception 'Informe o nome do parceiro.'; end if;
      if exists (select 1 from public.profiles where public.norm_name(name) = public.norm_name(gname)) then
        raise exception 'O jogador "%" já tem cadastro. Escolha ele na lista.', gname;
      end if;
      if public.norm_name(gname) = any(names) then raise exception 'Os parceiros precisam ter nomes diferentes.'; end if;
      if glevel is null or glevel not in ('Iniciante', 'Intermediário', 'Avançado') then glevel := 'Intermediário'; end if;
    end if;
    names := names || public.norm_name(gname);
    if side = 'a' then new.a2_name := gname; new.a2_level := glevel; else new.b2_name := gname; new.b2_level := glevel; end if;
  end loop;
  return new;
end $$;
drop trigger if exists games_partners on public.games;
create trigger games_partners before insert on public.games for each row execute function public.trg_games_partners();

-- avisa o parceiro cadastrado
create or replace function public.trg_games_partner_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare cap text; side text; uid uuid;
begin
  foreach side in array array['a', 'b'] loop
    uid := case side when 'a' then new.a2 else new.b2 end;
    if uid is not null then
      select name into cap from public.profiles where id = case side when 'a' then new.a else new.b end;
      perform public.push_send(uid, '🎾 Você entrou numa partida de duplas',
        coalesce(cap, 'Seu parceiro') || ' marcou um jogo com você em ' || to_char(new.day, 'DD/MM') || ' às ' || new.time || '. Os pontos também contam para você.');
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists games_partner_push on public.games;
create trigger games_partner_push after insert on public.games for each row execute function public.trg_games_partner_push();

-- ----- pontuação -----
create or replace function public._finish_game(g uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.games; l uuid;
  rw int; rl int; k int; e numeric; wgt numeric; n int; gw int; gl int; d int; applied int;
  ra numeric; ra2 numeric; rb numeric; rb2 numeric; avga numeric; avgb numeric; win_a boolean;
  p record; won boolean; cnt int; own numeric; opp numeric; mag int; ds jsonb := '{}'::jsonb; dwin int; dlose int;
begin
  select * into r from public.games where id = g and done = false and winner is not null for update;
  if not found then return; end if;
  l := case when r.winner = r.a then r.b else r.a end;
  update public.games set done = true where id = g;
  if not r.ranked then return; end if;

  select count(*) into n from public.games x
   where x.done and x.ranked and x.winner is not null and x.id <> g
     and ((x.a = r.a and x.b = r.b) or (x.a = r.b and x.b = r.a))
     and x.day >= r.day - 7;
  wgt := case when n < 2 then 1 when n < 4 then 0.5 else 0.25 end;

  if coalesce(r.format, '') in ('duplas', 'quarteto') and (r.a2 is not null or r.b2 is not null or r.a2_name is not null or r.b2_name is not null) then
    -- ===== duplas: cada jogador contra a média da dupla adversária =====
    select coalesce(rank, 0) into ra from public.profiles where id = r.a;
    select coalesce(rank, 0) into rb from public.profiles where id = r.b;
    ra2 := case when r.a2 is not null then (select coalesce(rank, 0) from public.profiles where id = r.a2) else public._base_rating(r.a2_level) end;
    rb2 := case when r.b2 is not null then (select coalesce(rank, 0) from public.profiles where id = r.b2) else public._base_rating(r.b2_level) end;
    avga := (ra + coalesce(ra2, ra)) / 2; avgb := (rb + coalesce(rb2, rb)) / 2;
    win_a := (r.winner = r.a);
    for p in
      select * from (values (r.a, ra, avgb, true), (r.a2, ra2, avgb, true), (r.b, rb, avga, false), (r.b2, rb2, avga, false)) as t(uid, rating, opp, side_a)
       where uid is not null
    loop
      won := (p.side_a = win_a);
      select count(*) into cnt from public.games x
       where x.done and x.ranked and x.winner is not null and x.id <> g and p.uid in (x.a, x.b, x.a2, x.b2);
      k := case when cnt < 10 then 40 else 32 end;
      e := 1 / (1 + power(10, (p.opp - p.rating) / 400.0));
      mag := greatest(1, round(k * (case when won then 1 - e else e end) * wgt));
      if won then
        update public.profiles set rank = rank + mag where id = p.uid;
        ds := ds || jsonb_build_object(p.uid::text, mag);
      else
        applied := least(mag, greatest(0, p.rating)::int);
        update public.profiles set rank = rank - applied where id = p.uid;
        ds := ds || jsonb_build_object(p.uid::text, -applied);
      end if;
    end loop;
    dwin  := coalesce((ds ->> r.winner::text)::int, 0);
    dlose := coalesce((ds ->> l::text)::int, 0);
    update public.games set deltas = ds, delta_w = dwin, delta_l = dlose where id = g;
    return;
  end if;

  -- ===== simples =====
  select coalesce(rank, 0) into rw from public.profiles where id = r.winner;
  select coalesce(rank, 0) into rl from public.profiles where id = l;
  select count(*) into gw from public.games x
   where x.done and x.ranked and x.winner is not null and x.id <> g and (x.a = r.winner or x.b = r.winner);
  select count(*) into gl from public.games x
   where x.done and x.ranked and x.winner is not null and x.id <> g and (x.a = l or x.b = l);
  k := case when least(gw, gl) < 10 then 40 else 32 end;
  e := 1 / (1 + power(10, (rl - rw) / 400.0));
  d := greatest(1, round(k * (1 - e) * wgt));
  applied := least(d, rl);
  update public.profiles set rank = rank + d where id = r.winner;
  update public.profiles set rank = rank - applied where id = l;
  update public.games set delta_w = d, delta_l = -applied where id = g;
end $$;
revoke execute on function public._finish_game(uuid) from public, anon, authenticated;

-- ----- perfil: conta também as partidas em que a pessoa foi parceira -----
create or replace function public.player_stats(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r record; pwin boolean;
  w int := 0; l int := 0; total int := 0;
  streak int := 0; counting boolean := true;
  last jsonb := '[]'::jsonb; n int := 0;
  hw int := 0; hl int := 0;
  votes int := 0; noshows int := 0; refs int := 0;
begin
  if me is null then raise exception 'Entre para ver perfis.'; end if;
  for r in
    select g.*, case when p_id in (g.a, g.a2) then g.b else g.a end as opp
      from public.games g
     where g.done and g.winner is not null and (g.a = p_id or g.b = p_id or g.a2 = p_id or g.b2 = p_id)
     order by g.day desc, g.time desc
  loop
    pwin := case when p_id in (r.a, r.a2) then r.winner = r.a else r.winner = r.b end;
    total := total + 1;
    if pwin then w := w + 1; else l := l + 1; end if;
    if counting then
      if pwin then streak := streak + 1; else counting := false; end if;
    end if;
    if n < 10 then
      last := last || jsonb_build_array(jsonb_build_object(
        'day', r.day, 'win', pwin, 'opp', r.opp, 'score', r.score,
        'ranked', coalesce((to_jsonb(r) ->> 'ranked')::boolean, true)));
      n := n + 1;
    end if;
    if me <> p_id and (r.a = me or r.b = me) then
      if pwin then hw := hw + 1; else hl := hl + 1; end if;
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
