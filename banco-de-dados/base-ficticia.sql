-- Beach Tennis Club: base fictícia (30 alunos + 5 professores + jogos, torneios...) e limpeza geral
-- Cole no SQL Editor do projeto "Beach Tennis" e clique em Run. Pode rodar mais de uma vez.
-- Funciona só para administrador, pelos botões da engrenagem (⚙️ > Dados de teste).

create table if not exists public.demo_marks (
  kind text not null check (kind in ('tournament', 'arena')),
  id uuid not null,
  primary key (kind, id)
);
alter table public.demo_marks enable row level security;

-- =====================================================================
-- LIMPAR TUDO: apaga alunos, professores e tudo ligado a eles (administradores ficam)
-- =====================================================================
create or replace function public.admin_wipe_all(p_confirm text) returns json
language plpgsql security definer set search_path = public as $$
declare n_users int; n_t int; n_l int; n_a int;
begin
  if not public.is_admin() then raise exception 'Só o administrador pode limpar a base.'; end if;
  if p_confirm is distinct from 'LIMPAR' then raise exception 'Confirmação incorreta. Digite LIMPAR.'; end if;
  delete from public.games;
  delete from public.requests;
  delete from public.invites;
  delete from public.tournaments;                       -- inscrições e chaves vão junto
  get diagnostics n_t = row_count;
  delete from public.lessons;
  get diagnostics n_l = row_count;
  delete from public.court_bookings;
  delete from public.dm;
  delete from public.arenas where id in (select id from public.demo_marks where kind = 'arena');
  get diagnostics n_a = row_count;
  delete from auth.users u using public.profiles p where p.id = u.id and not p.is_admin;
  get diagnostics n_users = row_count;
  delete from public.profiles where not is_admin;       -- sobras sem conta de login
  update public.profiles set rank = 0;
  delete from public.demo_marks;
  return json_build_object('pessoas', n_users, 'torneios', n_t, 'aulas', n_l, 'arenas_demo', n_a);
end $$;
revoke execute on function public.admin_wipe_all(text) from public, anon;
grant execute on function public.admin_wipe_all(text) to authenticated;

-- =====================================================================
-- REMOVER SO A BASE FICTICIA
-- =====================================================================
create or replace function public.admin_remove_demo() returns json
language plpgsql security definer set search_path = public as $$
declare n_users int; n_t int; n_a int;
begin
  if not public.is_admin() then raise exception 'Só o administrador pode remover a base fictícia.'; end if;
  delete from public.tournaments where id in (select id from public.demo_marks where kind = 'tournament');
  get diagnostics n_t = row_count;
  delete from public.arenas where id in (select id from public.demo_marks where kind = 'arena');
  get diagnostics n_a = row_count;
  delete from auth.users where email like '%@demo.beachtennis.app';
  get diagnostics n_users = row_count;
  delete from public.demo_marks;
  return json_build_object('pessoas', n_users, 'torneios', n_t, 'arenas', n_a);
end $$;
revoke execute on function public.admin_remove_demo() from public, anon;
grant execute on function public.admin_remove_demo() to authenticated;

-- =====================================================================
-- CARREGAR BASE FICTICIA
-- =====================================================================
create or replace function public.admin_seed_demo() returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  first_names text[] := array['Ana','Bruno','Carla','Diego','Eduarda','Felipe','Gabriela','Henrique','Isabela','João','Karina','Lucas','Mariana','Nicolas','Olivia','Pedro','Rafaela','Samuel','Tatiana','Vinicius','Amanda','Bernardo','Camila','Daniel','Fernanda','Gustavo','Helena','Igor','Juliana','Leonardo'];
  last_names text[] := array['Silva','Souza','Costa','Oliveira','Lima','Pereira','Almeida','Nunes','Ribeiro','Carvalho','Gomes','Martins','Rocha','Barbosa','Araújo','Dias','Moreira','Freitas','Teixeira','Cardoso'];
  t_names text[] := array['Prof. Rodrigo Mendes','Profa. Patrícia Lopes','Prof. André Batista','Profa. Larissa Campos','Prof. Márcio Duarte'];
  cities text[] := array['Caraguatatuba','São Sebastião','Ubatuba','São Paulo'];
  levels text[] := array['Iniciante','Intermediário','Avançado'];
  arenas_t text[] := array['Arena Praia Grande','Quadras do Centro','Beach Club Massaguaçu','Arena Sol e Mar'];
  times_t text[] := array['07:00','08:00','09:00','10:00','16:00','17:00','18:00','19:00'];
  scores text[] := array['6-3 6-4','6-2 6-3','7-5 6-4','6-4 3-6 6-2','6-1 6-2','7-6 6-3'];
  notes_t text[] := array['Vamos jogar de manhã!','Procuro dupla para treinar.','Jogo tranquilo, sem pressa.','Quero um jogo puxado.','Venha jogar com a gente!'];
  students uuid[] := '{}'; teachers uuid[] := '{}';
  v_id uuid; i int; j int; a uuid; b uuid; w uuid; d date; v_t uuid; v_m record; v_n int;
  g_id uuid; v_arena uuid; v_pk uuid; n_games int := 0; n_users int := 0;
  rk int[]; tid uuid; ttime text; arena_name text; st uuid; v_price numeric;
begin
  if not public.is_admin() then raise exception 'Só o administrador pode carregar a base fictícia.'; end if;
  if exists (select 1 from auth.users where email like '%@demo.beachtennis.app') then
    raise exception 'A base fictícia já está carregada. Remova antes de carregar de novo.';
  end if;

  -- ---------- pessoas: 30 alunos + 5 professores ----------
  for i in 1 .. 35 loop
    v_id := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
            'demo' || i || '@demo.beachtennis.app', md5(random()::text), now(),
            '{"provider":"email","providers":["email"]}'::jsonb,
            jsonb_build_object(
              'name', case when i <= 30 then first_names[i] || ' ' || last_names[1 + (i * 7) % 20] else t_names[i - 30] end,
              'role', 'jogador',
              'city', cities[1 + (i % 4)],
              'level', levels[1 + (i % 3)],
              'contact', '1299' || lpad((1000000 + i * 7919 % 8999999)::text, 7, '0')),
            now() - (random() * 60 || ' days')::interval, now(),
            '', '', '', '');
    if i <= 30 then students := students || v_id; else teachers := teachers || v_id; end if;
    n_users := n_users + 1;
  end loop;

  -- professores: aprovados, com arena, valores e plano
  for i in 1 .. 5 loop
    update public.profiles set
      role = 'professor', approval = 'aprovado',
      local = arenas_t[1 + (i % 4)],
      bio = (array['Professor há 8 anos, foco em iniciantes e técnica de saque.','Ex-atleta, treino de alto rendimento e duplas.','Aulas leves e divertidas para todas as idades.','Especialista em estratégia de jogo e preparação para torneios.','Aulas em grupo e clínicas de fim de semana.'])[i],
      price_ind_30 = 60 + i * 5, price_ind_60 = 110 + i * 10, price_grp_30 = 35 + i * 3, price_grp_60 = 60 + i * 5,
      plan = case when i <= 2 then 'pro' else 'free' end, featured = (i = 1)
     where id = teachers[i];
  end loop;

  -- ---------- jogos finalizados (ultimos 60 dias) ----------
  for i in 1 .. 70 loop
    a := students[1 + (random() * 29)::int];
    b := students[1 + (random() * 29)::int];
    continue when a = b;
    d := current_date - (1 + (random() * 58)::int);
    -- quem esta mais acima na lista tende a ganhar
    w := case when random() < 0.5 + (array_position(students, b) - array_position(students, a)) * 0.012 then a else b end;
    insert into public.games (a, b, day, time, local, format, city, done, winner, reported_by, reported_at, ranked)
    values (a, b, d, times_t[1 + (random() * 7)::int], arenas_t[1 + (random() * 3)::int],
            (array['simples','quarteto','duplas'])[1 + (random() * 2)::int], cities[1 + (random() * 3)::int],
            true, w, a, d + interval '20 hours', random() > 0.2);
    n_games := n_games + 1;
  end loop;
  -- aguardando confirmacao
  for i in 1 .. 3 loop
    a := students[i]; b := students[i + 10];
    insert into public.games (a, b, day, time, local, format, city, done, winner, reported_by, reported_at, ranked)
    values (a, b, current_date - 1, '18:00', arenas_t[1], 'simples', cities[1], false, a, a, now() - interval '5 hours', true);
  end loop;
  -- agendados (proximos dias)
  for i in 1 .. 8 loop
    a := students[(i * 3) % 30 + 1]; b := students[(i * 3 + 5) % 30 + 1];
    continue when a = b;
    insert into public.games (a, b, day, time, local, format, city, done, ranked)
    values (a, b, current_date + (1 + i % 6), times_t[1 + i % 8], arenas_t[1 + i % 4], 'duplas', cities[1 + i % 4], false, i % 3 <> 0);
  end loop;

  -- pontos de ranking a partir dos resultados
  update public.profiles p set rank = public._base_rating(p.level) + coalesce((
      select sum(case when g.winner = p.id then 25 else 5 end)::int from public.games g
       where g.done and coalesce(g.ranked, true) and (g.a = p.id or g.b = p.id)), 0)
   where p.id = any(students);

  -- ---------- convites abertos + pedidos ----------
  for i in 1 .. 14 loop
    insert into public.invites (owner, day, time, local, city, level, format, note, status, ranked)
    values (students[(i * 2) % 30 + 1], current_date + (1 + i % 12), times_t[1 + i % 8], arenas_t[1 + i % 4], cities[1 + i % 4],
            levels[1 + i % 3], (array['simples','quarteto','duplas'])[1 + i % 3], notes_t[1 + i % 5], 'open', i % 4 <> 0);
  end loop;
  for v_m in select id, owner from public.invites order by created_at desc limit 6 loop
    insert into public.requests (invite_id, from_user, to_user, status)
    values (v_m.id, (select s from unnest(students) s where s <> v_m.owner order by random() limit 1), v_m.owner, 'pending')
    on conflict do nothing;
  end loop;

  -- ---------- aulas (proximos dias) ----------
  for i in 1 .. 24 loop
    tid := teachers[1 + i % 5];
    st := students[1 + (i * 4) % 30];
    select local, coalesce(price_ind_60, 100) into arena_name, v_price from public.profiles where id = tid;
    insert into public.lessons (teacher, day, time, student, local, duration, kind, price, status, student_id)
    values (tid, current_date + (1 + i % 10), times_t[1 + (i * 3) % 8], (select name from public.profiles where id = st),
            arena_name, case when i % 4 = 0 then 30 else 60 end, case when i % 5 = 0 then 'grupo' else 'individual' end,
            v_price, 'confirmada', st);
  end loop;
  update public.lessons set status = 'pendente'
   where id in (select id from public.lessons where student_id = any(students) order by created_at desc limit 6);

  -- ---------- pacotes de aula ----------
  for i in 1 .. 5 loop
    v_pk := gen_random_uuid();
    insert into public.lesson_packages (id, teacher, name, lessons, price, validity_days)
    values (v_pk, teachers[i], '4 aulas individuais', 4, 380 + i * 10, 60);
    insert into public.lesson_packages (teacher, name, lessons, price, validity_days)
    values (teachers[i], '8 aulas em grupo', 8, 420 + i * 15, 90);
    insert into public.student_packages (package, teacher, student, name, total, used, price, paid, expires, status)
    values (v_pk, teachers[i], students[i * 3], '4 aulas individuais', 4, i % 4, 380 + i * 10, i % 2 = 0,
            current_date + 40, 'ativo');
  end loop;

  -- ---------- arenas e reservas ----------
  for i in 1 .. 2 loop
    v_arena := gen_random_uuid();
    insert into public.arenas (id, owner, name, city, address, whatsapp, price_hour, courts, open_time, close_time, slot_min, note)
    values (v_arena, case when i = 1 then teachers[1] else null end, arenas_t[i] || ' (demo)', cities[i],
            'Av. Beira Mar, ' || (100 * i), '12999990000', 70 + i * 20, 2 + i, '07:00', '21:00', 60,
            'Vestiário, estacionamento e aluguel de raquete.');
    insert into public.demo_marks values ('arena', v_arena);
    for j in 1 .. 5 loop
      begin
        insert into public.court_bookings (arena, court, day, time, user_id)
        values (v_arena, 1 + j % 2, current_date + (1 + j % 4), times_t[1 + (j * 2) % 8], students[1 + (j * 5 + i) % 30]);
      exception when unique_violation then null; end;
    end loop;
  end loop;

  -- ---------- torneios ----------
  -- 1) encerrado, chave completa e podio
  v_t := gen_random_uuid();
  insert into public.tournaments (id, name, day, time, arena, city, format, fee, max_players, sponsor, description, status)
  values (v_t, 'Copa Verão 2026 (demo)', current_date - 20, '09:00', arenas_t[1], cities[1], 'simples', 40, 16,
          'Sorvetes do Litoral', 'Torneio de simples, mata-mata, 16 jogadores.', 'aberto');
  insert into public.demo_marks values ('tournament', v_t);
  insert into public.tournament_entries (tournament_id, player_id, paid)
  select v_t, s, true from unnest(students[1:16]) s;
  perform public.admin_generate_bracket(v_t);
  for v_n in 1 .. 4 loop
    for v_m in select id, p1, p2 from public.tournament_matches
                where tournament = v_t and round = v_n and winner is null and p1 is not null and p2 is not null
                order by pos loop
      perform public.admin_set_match_winner(v_m.id,
        case when array_position(students, v_m.p1) < array_position(students, v_m.p2) then v_m.p1 else v_m.p2 end,
        scores[1 + (random() * 5)::int]);
    end loop;
  end loop;
  perform public.admin_finish_tournament(v_t,
    (select winner from public.tournament_matches where tournament = v_t order by round desc, pos limit 1),
    (select case when winner = p1 then p2 else p1 end from public.tournament_matches where tournament = v_t order by round desc, pos limit 1),
    (select case when winner = p1 then p2 else p1 end from public.tournament_matches where tournament = v_t and round = 3 order by pos limit 1));

  -- 2) inscricoes abertas, com vagas
  v_t := gen_random_uuid();
  insert into public.tournaments (id, name, day, time, arena, city, format, fee, max_players, description, status)
  values (v_t, 'Open de Primavera (demo)', current_date + 14, '09:00', arenas_t[3], cities[3], 'duplas', 60, 16,
          'Inscrições abertas! Categoria livre.', 'aberto');
  insert into public.demo_marks values ('tournament', v_t);
  insert into public.tournament_entries (tournament_id, player_id, paid)
  select v_t, s, (random() > 0.4) from unnest(students[17:25]) s;

  -- 3) em andamento: lotado, chave gerada e primeiras rodadas decididas
  v_t := gen_random_uuid();
  insert into public.tournaments (id, name, day, time, arena, city, format, fee, max_players, description, status)
  values (v_t, 'Torneio Relâmpago (demo)', current_date + 2, '16:00', arenas_t[2], cities[2], 'simples', 25, 8,
          'Oito jogadores, mata-mata em um dia.', 'aberto');
  insert into public.demo_marks values ('tournament', v_t);
  insert into public.tournament_entries (tournament_id, player_id, paid)
  select v_t, s, true from unnest(students[9:16]) s;
  perform public.admin_generate_bracket(v_t);
  for v_m in select id, p1, p2 from public.tournament_matches where tournament = v_t and round = 1 order by pos limit 3 loop
    perform public.admin_set_match_winner(v_m.id, v_m.p1, scores[1 + (random() * 5)::int]);
  end loop;

  -- ---------- seguir, torcida e conversas ----------
  for i in 1 .. 6 loop
    insert into public.follows (follower, followee) values (me, students[i]) on conflict do nothing;
  end loop;
  for i in 1 .. 45 loop
    a := students[1 + (random() * 29)::int]; b := students[1 + (random() * 29)::int];
    continue when a = b;
    insert into public.follows (follower, followee) values (a, b) on conflict do nothing;
  end loop;
  for g_id in select id from public.games where done order by random() limit 35 loop
    for j in 1 .. (1 + (random() * 4)::int) loop
      insert into public.game_cheers (game_id, user_id) values (g_id, students[1 + (random() * 29)::int]) on conflict do nothing;
    end loop;
  end loop;
  for i in 1 .. 12 loop
    a := students[i]; b := students[i + 12];
    insert into public.dm (sender, receiver, body, created_at, read_at) values
      (a, b, (array['Oi! Bora jogar sábado?','E aí, topa uma partida?','Vi seu convite, posso entrar?'])[1 + i % 3], now() - (i || ' hours')::interval, now()),
      (b, a, (array['Bora! Que horas?','Fechado 👍','Pode ser, onde?'])[1 + i % 3], now() - (i || ' hours')::interval + interval '10 minutes', now());
  end loop;
  insert into public.dm (sender, receiver, body) values
    (students[2], me, 'Olá! Vi que você organiza os torneios. Tem vaga no Open de Primavera?'),
    (students[5], me, 'Boa tarde! Dá para reservar a quadra de sábado de manhã?');

  return json_build_object('alunos', 30, 'professores', 5, 'jogos', n_games + 11, 'torneios', 3, 'arenas', 2);
end $$;
revoke execute on function public.admin_seed_demo() from public, anon;
grant execute on function public.admin_seed_demo() to authenticated;
