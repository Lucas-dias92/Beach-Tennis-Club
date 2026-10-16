-- Beach Tennis Club: novidades (perfil do jogador, quadras, chave, pacotes, feed). Cole inteiro e clique em Run.

-- ===== perfil-jogador =====
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

-- ===== plataforma =====
-- Beach Tennis Club: quadras/arenas, chave de torneio, pacotes de aula, seguir amigos e feed
-- Cole no SQL Editor do projeto "Beach Tennis" e clique em Run. Pode rodar mais de uma vez.

-- =====================================================================
-- 1) ARENAS E RESERVA DE QUADRA
-- =====================================================================
create table if not exists public.arenas (
  id uuid primary key default gen_random_uuid(),
  owner uuid references public.profiles(id) on delete set null,
  name text not null check (char_length(name) between 2 and 80),
  city text,
  address text,
  whatsapp text,
  price_hour numeric(10,2) not null default 0 check (price_hour >= 0),
  courts int not null default 1 check (courts between 1 and 20),
  open_time text not null default '06:00',
  close_time text not null default '22:00',
  slot_min int not null default 60 check (slot_min in (30, 60, 90, 120)),
  note text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.arenas enable row level security;
drop policy if exists "arenas_select" on public.arenas;
create policy "arenas_select" on public.arenas for select using (true);
drop policy if exists "arenas_insert" on public.arenas;
create policy "arenas_insert" on public.arenas for insert to authenticated with check (public.is_admin());
drop policy if exists "arenas_update" on public.arenas;
create policy "arenas_update" on public.arenas for update to authenticated
  using (public.is_admin() or owner = auth.uid()) with check (public.is_admin() or owner = auth.uid());
drop policy if exists "arenas_delete" on public.arenas;
create policy "arenas_delete" on public.arenas for delete to authenticated using (public.is_admin());

create table if not exists public.court_bookings (
  id uuid primary key default gen_random_uuid(),
  arena uuid not null references public.arenas(id) on delete cascade,
  court int not null,
  day date not null,
  time text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'confirmada' check (status in ('confirmada', 'cancelada')),
  created_at timestamptz not null default now()
);
create unique index if not exists court_bookings_slot
  on public.court_bookings (arena, court, day, time) where status = 'confirmada';
create index if not exists court_bookings_user on public.court_bookings (user_id, day);
alter table public.court_bookings enable row level security;
drop policy if exists "bookings_select" on public.court_bookings;
create policy "bookings_select" on public.court_bookings for select to authenticated
  using (user_id = auth.uid() or public.is_admin()
         or exists (select 1 from public.arenas a where a.id = arena and a.owner = auth.uid()));

-- horarios ocupados de um dia (sem mostrar quem reservou)
create or replace function public.arena_busy(p_arena uuid, p_day date)
returns table (court int, "time" text)
language sql security definer set search_path = public stable as $$
  select b.court, b.time from public.court_bookings b
   where b.arena = p_arena and b.day = p_day and b.status = 'confirmada';
$$;
revoke execute on function public.arena_busy(uuid, date) from public, anon;
grant execute on function public.arena_busy(uuid, date) to authenticated;

create or replace function public.book_court(p_arena uuid, p_court int, p_day date, p_time text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_a public.arenas;
  v_id uuid;
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_nowm int := extract(hour from (now() at time zone 'America/Sao_Paulo'))::int * 60
              + extract(minute from (now() at time zone 'America/Sao_Paulo'))::int;
  v_m int; v_om int; v_cm int; v_name text;
begin
  if auth.uid() is null then raise exception 'Entre para reservar.'; end if;
  select * into v_a from public.arenas where id = p_arena and active;
  if not found then raise exception 'Essa arena não está disponível.'; end if;
  if p_court < 1 or p_court > v_a.courts then raise exception 'Quadra inválida.'; end if;
  if p_day < v_today or p_day > v_today + 60 then raise exception 'Escolha uma data nos próximos 60 dias.'; end if;
  v_m  := split_part(p_time, ':', 1)::int * 60 + split_part(p_time, ':', 2)::int;
  v_om := split_part(v_a.open_time, ':', 1)::int * 60 + split_part(v_a.open_time, ':', 2)::int;
  v_cm := split_part(v_a.close_time, ':', 1)::int * 60 + split_part(v_a.close_time, ':', 2)::int;
  if v_m < v_om or v_m + v_a.slot_min > v_cm or (v_m - v_om) % v_a.slot_min <> 0 then
    raise exception 'Horário fora do funcionamento da arena.';
  end if;
  if p_day = v_today and v_m <= v_nowm then raise exception 'Esse horário já passou.'; end if;
  if (select count(*) from public.court_bookings
       where user_id = auth.uid() and status = 'confirmada' and day >= v_today) >= 10 then
    raise exception 'Você já tem 10 reservas ativas. Cancele alguma para reservar outra.';
  end if;
  begin
    insert into public.court_bookings (arena, court, day, time, user_id)
    values (p_arena, p_court, p_day, p_time, auth.uid()) returning id into v_id;
  exception when unique_violation then
    raise exception 'Esse horário acabou de ser reservado. Escolha outro.';
  end;
  select name into v_name from public.profiles where id = auth.uid();
  if v_a.owner is not null and v_a.owner <> auth.uid() then
    perform public.push_send(v_a.owner, 'Nova reserva 📅',
      coalesce(v_name, 'Um jogador') || ' reservou a quadra ' || p_court || ' em '
      || to_char(p_day, 'DD/MM') || ' às ' || p_time || '.');
  end if;
  return v_id;
end $$;
revoke execute on function public.book_court(uuid, int, date, text) from public, anon;
grant execute on function public.book_court(uuid, int, date, text) to authenticated;

create or replace function public.cancel_booking(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_b public.court_bookings; v_a public.arenas; v_name text;
begin
  select * into v_b from public.court_bookings where id = p_id and status = 'confirmada';
  if not found then raise exception 'Reserva não encontrada.'; end if;
  select * into v_a from public.arenas where id = v_b.arena;
  if not (v_b.user_id = auth.uid() or public.is_admin() or v_a.owner = auth.uid()) then
    raise exception 'Você não pode cancelar essa reserva.';
  end if;
  update public.court_bookings set status = 'cancelada' where id = p_id;
  if v_b.user_id <> auth.uid() then
    perform public.push_send(v_b.user_id, 'Reserva cancelada',
      'Sua reserva em ' || v_a.name || ' (' || to_char(v_b.day, 'DD/MM') || ' às ' || v_b.time || ') foi cancelada pela arena.');
  elsif v_a.owner is not null and v_a.owner <> auth.uid() then
    select name into v_name from public.profiles where id = auth.uid();
    perform public.push_send(v_a.owner, 'Reserva cancelada',
      coalesce(v_name, 'Um jogador') || ' cancelou a quadra ' || v_b.court || ' de ' || to_char(v_b.day, 'DD/MM') || ' às ' || v_b.time || '.');
  end if;
end $$;
revoke execute on function public.cancel_booking(uuid) from public, anon;
grant execute on function public.cancel_booking(uuid) to authenticated;

-- =====================================================================
-- 2) CHAVE (MATA-MATA) DOS TORNEIOS
-- =====================================================================
create table if not exists public.tournament_matches (
  id uuid primary key default gen_random_uuid(),
  tournament uuid not null references public.tournaments(id) on delete cascade,
  round int not null,
  pos int not null,
  p1 uuid references public.profiles(id) on delete set null,
  p2 uuid references public.profiles(id) on delete set null,
  winner uuid references public.profiles(id) on delete set null,
  score text,
  unique (tournament, round, pos)
);
alter table public.tournament_matches enable row level security;
drop policy if exists "matches_select" on public.tournament_matches;
create policy "matches_select" on public.tournament_matches for select using (true);

-- leva o vencedor de uma partida para a proxima fase
create or replace function public._advance_match(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.tournament_matches; v_max int; v_pos int;
begin
  select * into m from public.tournament_matches where id = p_match;
  if not found or m.winner is null then return; end if;
  select max(round) into v_max from public.tournament_matches where tournament = m.tournament;
  if m.round >= v_max then return; end if;
  v_pos := (m.pos + 1) / 2;
  if m.pos % 2 = 1 then
    update public.tournament_matches set p1 = m.winner
     where tournament = m.tournament and round = m.round + 1 and pos = v_pos;
  else
    update public.tournament_matches set p2 = m.winner
     where tournament = m.tournament and round = m.round + 1 and pos = v_pos;
  end if;
end $$;
revoke execute on function public._advance_match(uuid) from public, anon, authenticated;

create or replace function public.admin_generate_bracket(p_t uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  seeds uuid[]; n int; v_size int := 1; v_rounds int := 0;
  ord int[] := array[1]; nxt int[]; s int; i int; r int; k int;
  v_p1 uuid; v_p2 uuid; v_id uuid;
begin
  if not public.is_admin() then raise exception 'Só o administrador monta a chave.'; end if;
  select array_agg(e.player_id order by coalesce(p.rank, 0) desc, e.player_id)
    into seeds
    from public.tournament_entries e join public.profiles p on p.id = e.player_id
   where e.tournament_id = p_t;
  n := coalesce(array_length(seeds, 1), 0);
  if n < 2 then raise exception 'Precisa de pelo menos 2 inscritos para montar a chave.'; end if;
  while v_size < n loop v_size := v_size * 2; v_rounds := v_rounds + 1; end loop;
  -- ordem padrao de chaveamento (1 contra o ultimo, etc.)
  while coalesce(array_length(ord, 1), 0) < v_size loop
    nxt := array[]::int[];
    foreach s in array ord loop
      nxt := nxt || s || (array_length(ord, 1) * 2 + 1 - s);
    end loop;
    ord := nxt;
  end loop;
  delete from public.tournament_matches where tournament = p_t;
  for i in 1 .. v_size / 2 loop
    s := ord[2 * i - 1]; k := ord[2 * i];
    v_p1 := case when s <= n then seeds[s] else null end;
    v_p2 := case when k <= n then seeds[k] else null end;
    insert into public.tournament_matches (tournament, round, pos, p1, p2) values (p_t, 1, i, v_p1, v_p2);
  end loop;
  for r in 2 .. v_rounds loop
    for i in 1 .. (v_size / (2 ^ r)::int) loop
      insert into public.tournament_matches (tournament, round, pos) values (p_t, r, i);
    end loop;
  end loop;
  -- quem pegou "bye" avanca direto
  for v_id in
    select id from public.tournament_matches
     where tournament = p_t and round = 1 and ((p1 is null) <> (p2 is null))
  loop
    update public.tournament_matches set winner = coalesce(p1, p2), score = 'bye' where id = v_id;
    perform public._advance_match(v_id);
  end loop;
end $$;
revoke execute on function public.admin_generate_bracket(uuid) from public, anon;
grant execute on function public.admin_generate_bracket(uuid) to authenticated;

create or replace function public.admin_set_match_winner(p_match uuid, p_winner uuid, p_score text default null)
returns void language plpgsql security definer set search_path = public as $$
declare m public.tournament_matches; nx public.tournament_matches; v_max int;
begin
  if not public.is_admin() then raise exception 'Só o administrador lança resultados.'; end if;
  select * into m from public.tournament_matches where id = p_match;
  if not found then raise exception 'Partida não encontrada.'; end if;
  if p_winner is distinct from m.p1 and p_winner is distinct from m.p2 then
    raise exception 'O vencedor precisa ser um dos dois jogadores da partida.';
  end if;
  select max(round) into v_max from public.tournament_matches where tournament = m.tournament;
  if m.round < v_max then
    select * into nx from public.tournament_matches
     where tournament = m.tournament and round = m.round + 1 and pos = (m.pos + 1) / 2;
    if nx.winner is not null then raise exception 'A próxima fase já foi decidida. Desfaça-a antes.'; end if;
  end if;
  update public.tournament_matches set winner = p_winner, score = nullif(left(coalesce(p_score, ''), 40), '')
   where id = p_match;
  perform public._advance_match(p_match);
end $$;
revoke execute on function public.admin_set_match_winner(uuid, uuid, text) from public, anon;
grant execute on function public.admin_set_match_winner(uuid, uuid, text) to authenticated;

-- =====================================================================
-- 3) PACOTES DE AULA
-- =====================================================================
create table if not exists public.lesson_packages (
  id uuid primary key default gen_random_uuid(),
  teacher uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 60),
  lessons int not null check (lessons between 1 and 100),
  price numeric(10,2) not null default 0 check (price >= 0),
  validity_days int not null default 60 check (validity_days between 7 and 365),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.lesson_packages enable row level security;
drop policy if exists "pkg_select" on public.lesson_packages;
create policy "pkg_select" on public.lesson_packages for select using (true);
drop policy if exists "pkg_insert" on public.lesson_packages;
create policy "pkg_insert" on public.lesson_packages for insert to authenticated
  with check (teacher = auth.uid() or public.is_admin());
drop policy if exists "pkg_update" on public.lesson_packages;
create policy "pkg_update" on public.lesson_packages for update to authenticated
  using (teacher = auth.uid() or public.is_admin()) with check (teacher = auth.uid() or public.is_admin());
drop policy if exists "pkg_delete" on public.lesson_packages;
create policy "pkg_delete" on public.lesson_packages for delete to authenticated
  using (teacher = auth.uid() or public.is_admin());

create table if not exists public.student_packages (
  id uuid primary key default gen_random_uuid(),
  package uuid references public.lesson_packages(id) on delete set null,
  teacher uuid not null references public.profiles(id) on delete cascade,
  student uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  total int not null,
  used int not null default 0,
  price numeric(10,2) not null default 0,
  paid boolean not null default false,
  expires date not null,
  status text not null default 'ativo' check (status in ('ativo', 'encerrado')),
  created_at timestamptz not null default now()
);
alter table public.student_packages enable row level security;
drop policy if exists "spk_select" on public.student_packages;
create policy "spk_select" on public.student_packages for select to authenticated
  using (student = auth.uid() or teacher = auth.uid() or public.is_admin());

create or replace function public.buy_package(p_pkg uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_p public.lesson_packages; v_id uuid; v_name text;
begin
  if auth.uid() is null then raise exception 'Entre para contratar.'; end if;
  select * into v_p from public.lesson_packages where id = p_pkg and active;
  if not found then raise exception 'Pacote indisponível.'; end if;
  if v_p.teacher = auth.uid() then raise exception 'Você não pode contratar o seu próprio pacote.'; end if;
  insert into public.student_packages (package, teacher, student, name, total, price, expires)
  values (v_p.id, v_p.teacher, auth.uid(), v_p.name, v_p.lessons, v_p.price,
          (now() at time zone 'America/Sao_Paulo')::date + v_p.validity_days)
  returning id into v_id;
  select name into v_name from public.profiles where id = auth.uid();
  perform public.push_send(v_p.teacher, 'Novo pacote contratado 📦',
    coalesce(v_name, 'Um aluno') || ' contratou "' || v_p.name || '". Combine o pagamento com ele.');
  return v_id;
end $$;
revoke execute on function public.buy_package(uuid) from public, anon;
grant execute on function public.buy_package(uuid) to authenticated;

create or replace function public.pkg_adjust(p_sp uuid, p_delta int) returns void
language plpgsql security definer set search_path = public as $$
declare v_s public.student_packages; v_used int;
begin
  select * into v_s from public.student_packages where id = p_sp;
  if not found then raise exception 'Pacote não encontrado.'; end if;
  if not (v_s.teacher = auth.uid() or public.is_admin()) then raise exception 'Só o professor controla as aulas do pacote.'; end if;
  v_used := least(v_s.total, greatest(0, v_s.used + p_delta));
  update public.student_packages
     set used = v_used, status = case when v_used >= total then 'encerrado' else 'ativo' end
   where id = p_sp;
  if p_delta > 0 then
    perform public.push_send(v_s.student, 'Aula descontada do pacote 🎓',
      'Restam ' || (v_s.total - v_used) || ' aula(s) do pacote "' || v_s.name || '".');
  end if;
end $$;
revoke execute on function public.pkg_adjust(uuid, int) from public, anon;
grant execute on function public.pkg_adjust(uuid, int) to authenticated;

create or replace function public.pkg_set_paid(p_sp uuid, p_paid boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.student_packages set paid = p_paid
   where id = p_sp and (teacher = auth.uid() or public.is_admin());
  if not found then raise exception 'Pacote não encontrado.'; end if;
end $$;
revoke execute on function public.pkg_set_paid(uuid, boolean) from public, anon;
grant execute on function public.pkg_set_paid(uuid, boolean) to authenticated;

-- =====================================================================
-- 4) SEGUIR JOGADORES, FEED E TORCIDA
-- =====================================================================
create table if not exists public.follows (
  follower uuid not null references public.profiles(id) on delete cascade,
  followee uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee)
);
alter table public.follows enable row level security;
drop policy if exists "follows_select" on public.follows;
create policy "follows_select" on public.follows for select to authenticated using (follower = auth.uid());
drop policy if exists "follows_insert" on public.follows;
create policy "follows_insert" on public.follows for insert to authenticated with check (follower = auth.uid());
drop policy if exists "follows_delete" on public.follows;
create policy "follows_delete" on public.follows for delete to authenticated using (follower = auth.uid());

create table if not exists public.game_cheers (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (game_id, user_id)
);
alter table public.game_cheers enable row level security;

create or replace function public.community_feed(p_following boolean default false, p_limit int default 30)
returns table (id uuid, a uuid, b uuid, winner uuid, day date, "time" text, ranked boolean, cheers int, cheered boolean)
language sql security definer set search_path = public stable as $$
  select g.id, g.a, g.b, g.winner, g.day, g.time,
         coalesce((to_jsonb(g) ->> 'ranked')::boolean, true),
         (select count(*)::int from public.game_cheers c where c.game_id = g.id),
         exists (select 1 from public.game_cheers c where c.game_id = g.id and c.user_id = auth.uid())
    from public.games g
   where auth.uid() is not null and g.done and g.winner is not null
     and (not p_following
          or g.a = auth.uid() or g.b = auth.uid()
          or g.a in (select followee from public.follows where follower = auth.uid())
          or g.b in (select followee from public.follows where follower = auth.uid()))
   order by g.day desc, g.time desc
   limit least(greatest(p_limit, 1), 60);
$$;
revoke execute on function public.community_feed(boolean, int) from public, anon;
grant execute on function public.community_feed(boolean, int) to authenticated;

create or replace function public.toggle_cheer(p_game uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Entre para torcer.'; end if;
  if exists (select 1 from public.game_cheers where game_id = p_game and user_id = auth.uid()) then
    delete from public.game_cheers where game_id = p_game and user_id = auth.uid();
    return false;
  end if;
  if not exists (select 1 from public.games where id = p_game and done) then raise exception 'Jogo não encontrado.'; end if;
  insert into public.game_cheers (game_id, user_id) values (p_game, auth.uid());
  return true;
end $$;
revoke execute on function public.toggle_cheer(uuid) from public, anon;
grant execute on function public.toggle_cheer(uuid) to authenticated;
