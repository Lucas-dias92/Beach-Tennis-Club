-- Beach Tennis Club: tabelas, regras de acesso (RLS) e gatilho de cadastro

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  role text not null default 'jogador' check (role in ('jogador','professor')),
  rank int not null default 0,
  local text,
  bio text,
  price text,
  created_at timestamptz not null default now()
);

create table if not exists public.invites (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  time text not null,
  local text not null,
  status text not null default 'open' check (status in ('open','matched')),
  created_at timestamptz not null default now()
);

create table if not exists public.requests (
  id uuid primary key default gen_random_uuid(),
  invite_id uuid not null references public.invites(id) on delete cascade,
  from_user uuid not null references public.profiles(id) on delete cascade,
  to_user uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  unique (invite_id, from_user)
);

create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  a uuid not null references public.profiles(id) on delete cascade,
  b uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  time text not null,
  local text not null,
  done boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.lessons (
  id uuid primary key default gen_random_uuid(),
  teacher uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  time text not null,
  student text not null,
  local text,
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  teacher uuid not null references public.profiles(id) on delete cascade,
  from_user uuid not null references public.profiles(id) on delete cascade,
  from_name text not null,
  text text not null,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.invites  enable row level security;
alter table public.requests enable row level security;
alter table public.games    enable row level security;
alter table public.lessons  enable row level security;
alter table public.messages enable row level security;

-- profiles: ranking e professores são públicos; cada um edita só o seu
create policy "profiles_select" on public.profiles for select using (true);
create policy "profiles_update_own" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- invites: membros logados veem; dono cria/edita/apaga; dono do convite pode marcar como fechado
create policy "invites_select" on public.invites for select to authenticated using (true);
create policy "invites_insert" on public.invites for insert to authenticated with check (owner = auth.uid());
create policy "invites_update" on public.invites for update to authenticated using (owner = auth.uid());
create policy "invites_delete" on public.invites for delete to authenticated using (owner = auth.uid());

-- requests: só quem enviou ou recebeu
create policy "requests_select" on public.requests for select to authenticated using (from_user = auth.uid() or to_user = auth.uid());
create policy "requests_insert" on public.requests for insert to authenticated with check (from_user = auth.uid());
create policy "requests_update" on public.requests for update to authenticated using (to_user = auth.uid());

-- games: só os dois jogadores
create policy "games_select" on public.games for select to authenticated using (a = auth.uid() or b = auth.uid());
create policy "games_insert" on public.games for insert to authenticated with check (a = auth.uid());
create policy "games_update" on public.games for update to authenticated using (a = auth.uid() or b = auth.uid());

-- lessons: só o professor dono
create policy "lessons_all" on public.lessons for all to authenticated using (teacher = auth.uid()) with check (teacher = auth.uid());

-- messages: aluno envia; aluno e professor leem
create policy "messages_select" on public.messages for select to authenticated using (teacher = auth.uid() or from_user = auth.uid());
create policy "messages_insert" on public.messages for insert to authenticated with check (from_user = auth.uid());

-- cria o perfil automaticamente quando alguém se cadastra
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, role, local, bio, price)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'name',''), split_part(new.email,'@',1)),
    case when new.raw_user_meta_data->>'role' = 'professor' then 'professor' else 'jogador' end,
    new.raw_user_meta_data->>'local',
    new.raw_user_meta_data->>'bio',
    'A combinar'
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ===== Parte 2: resultado precisa ser confirmado pelo adversário =====
alter table public.games add column if not exists winner uuid references public.profiles(id);
alter table public.games add column if not exists reported_by uuid references public.profiles(id);
drop policy if exists "games_update" on public.games;
revoke update on public.profiles from authenticated;
grant update (name, local, bio, price) on public.profiles to authenticated;

create or replace function public.report_result(g uuid, w uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.games;
begin
  select * into r from public.games where id = g and done = false;
  if not found then raise exception 'Jogo não encontrado ou já encerrado'; end if;
  if auth.uid() not in (r.a, r.b) then raise exception 'Você não participa deste jogo'; end if;
  if w not in (r.a, r.b) then raise exception 'Vencedor inválido'; end if;
  update public.games set winner = w, reported_by = auth.uid() where id = g;
end $$;

create or replace function public.confirm_result(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.games; l uuid;
begin
  select * into r from public.games where id = g and done = false and winner is not null;
  if not found then raise exception 'Nenhum resultado aguardando confirmação'; end if;
  if auth.uid() not in (r.a, r.b) or auth.uid() = r.reported_by then raise exception 'Só o outro jogador pode confirmar'; end if;
  l := case when r.winner = r.a then r.b else r.a end;
  update public.games set done = true where id = g;
  update public.profiles set rank = rank + 25 where id = r.winner;
  update public.profiles set rank = rank + 5 where id = l;
end $$;

create or replace function public.contest_result(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.games;
begin
  select * into r from public.games where id = g and done = false and winner is not null;
  if not found then raise exception 'Nenhum resultado para contestar'; end if;
  if auth.uid() not in (r.a, r.b) or auth.uid() = r.reported_by then raise exception 'Só o outro jogador pode contestar'; end if;
  update public.games set winner = null, reported_by = null where id = g;
end $$;

revoke execute on function public.report_result(uuid, uuid), public.confirm_result(uuid), public.contest_result(uuid) from public, anon;
grant execute on function public.report_result(uuid, uuid), public.confirm_result(uuid), public.contest_result(uuid) to authenticated;

-- ===== Parte 3: prazo de 48h. Sem resposta, vale o resultado informado =====
alter table public.games add column if not exists reported_at timestamptz;

create or replace function public._finish_game(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.games; l uuid;
begin
  select * into r from public.games where id = g and done = false and winner is not null for update;
  if not found then return; end if;
  l := case when r.winner = r.a then r.b else r.a end;
  update public.games set done = true where id = g;
  update public.profiles set rank = rank + 25 where id = r.winner;
  update public.profiles set rank = rank + 5 where id = l;
end $$;
revoke execute on function public._finish_game(uuid) from public, anon, authenticated;

-- report_result passa a gravar reported_at = now(); confirm_result chama _finish_game;
-- contest_result recusa depois de 48h (veja as versões aplicadas no banco).

create or replace function public.finalize_expired() returns int language plpgsql security definer set search_path = public as $$
declare x record; n int := 0;
begin
  for x in select id from public.games where done = false and winner is not null and reported_at < now() - interval '48 hours' loop
    perform public._finish_game(x.id); n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.finalize_expired() from public, anon;
grant execute on function public.finalize_expired() to authenticated;

create extension if not exists pg_cron;
select cron.schedule('finalize-expired-games', '0 * * * *', 'select public.finalize_expired()');


-- ===== Parte 4: campos usados pelo design "beach tennis 2" =====
alter table public.profiles add column if not exists city text;
alter table public.profiles add column if not exists level text default 'Iniciante';
alter table public.profiles add column if not exists contact text;
alter table public.profiles alter column price type numeric using nullif(regexp_replace(coalesce(price,''),'[^0-9.]','','g'),'')::numeric;
alter table public.invites add column if not exists city text;
alter table public.invites add column if not exists level text;
alter table public.invites add column if not exists format text default 'quarteto';
alter table public.invites add column if not exists note text;
alter table public.games add column if not exists format text;
alter table public.games add column if not exists city text;
grant update (city, level, contact) on public.profiles to authenticated;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, role, local, bio, price, city, level, contact)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'name',''), split_part(new.email,'@',1)),
    case when new.raw_user_meta_data->>'role' = 'professor' then 'professor' else 'jogador' end,
    new.raw_user_meta_data->>'local',
    new.raw_user_meta_data->>'bio',
    case when new.raw_user_meta_data->>'price' ~ '^[0-9]+(\.[0-9]+)?$' then (new.raw_user_meta_data->>'price')::numeric end,
    new.raw_user_meta_data->>'city',
    coalesce(nullif(new.raw_user_meta_data->>'level',''), 'Iniciante'),
    new.raw_user_meta_data->>'contact'
  );
  return new;
end $$;

create or replace function public.public_stats() returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'players',  (select count(*) from public.profiles where role = 'jogador'),
    'teachers', (select count(*) from public.profiles where role = 'professor'),
    'open',     (select count(*) from public.invites where status = 'open'));
$$;
grant execute on function public.public_stats() to anon, authenticated;

-- ===== Parte 5: administrador =====
alter table public.profiles add column if not exists is_admin boolean not null default false;
create or replace function public.is_admin() returns boolean language sql security definer stable set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;
grant execute on function public.is_admin() to authenticated;
create policy "profiles_admin_update" on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "lessons_admin" on public.lessons for all to authenticated using (public.is_admin()) with check (public.is_admin());
-- is_admin NÃO está na lista de colunas editáveis: ninguém vira admin pelo site, só por SQL.

-- ===== Parte 6: foto, preços, regras de agenda, só o admin cadastra professor =====
alter table public.profiles drop constraint if exists profiles_id_fkey;   -- permite professor cadastrado pelo admin, sem login próprio
alter table public.profiles alter column id set default gen_random_uuid();
alter table public.profiles add column if not exists photo_url text;
alter table public.profiles add column if not exists price_ind_30 numeric;
alter table public.profiles add column if not exists price_ind_60 numeric;
alter table public.profiles add column if not exists price_grp_30 numeric;
alter table public.profiles add column if not exists price_grp_60 numeric;
grant update (photo_url, price_ind_30, price_ind_60, price_grp_30, price_grp_60) on public.profiles to authenticated;

alter table public.lessons add column if not exists duration int not null default 60;
alter table public.lessons add column if not exists kind text not null default 'individual';
alter table public.lessons add column if not exists price numeric;
alter table public.lessons drop constraint if exists lessons_duration_chk;
alter table public.lessons add constraint lessons_duration_chk check (duration in (30, 60));
alter table public.lessons drop constraint if exists lessons_kind_chk;
alter table public.lessons add constraint lessons_kind_chk check (kind in ('individual', 'grupo'));

-- aula: nada no passado; nada em dois locais diferentes ao mesmo tempo (mesmo local pode)
create or replace function public.guard_lesson() returns trigger language plpgsql set search_path = public as $$
declare s timestamptz; e timestamptz;
begin
  s := ((new.day + new.time::time) at time zone 'America/Sao_Paulo');
  e := s + make_interval(mins => new.duration);
  if s < now() then raise exception 'Não é possível agendar uma aula em dia ou horário que já passou.'; end if;
  if exists (select 1 from public.lessons l
             where l.teacher = new.teacher and l.id <> new.id
               and lower(trim(coalesce(l.local, ''))) <> lower(trim(coalesce(new.local, '')))
               and ((l.day + l.time::time) at time zone 'America/Sao_Paulo') < e
               and ((l.day + l.time::time) at time zone 'America/Sao_Paulo') + make_interval(mins => l.duration) > s)
  then raise exception 'Este professor já tem aula nesse horário em outro local.'; end if;
  return new;
end $$;
drop trigger if exists lessons_guard on public.lessons;
create trigger lessons_guard before insert or update of day, time, local, duration on public.lessons
  for each row execute function public.guard_lesson();

-- professor (não admin) só pode trocar a própria foto
create or replace function public.guard_profile_update() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() and old.role = 'professor' then
    if new.name is distinct from old.name or new.city is distinct from old.city or new.local is distinct from old.local
       or new.contact is distinct from old.contact or new.bio is distinct from old.bio or new.price is distinct from old.price
       or new.price_ind_30 is distinct from old.price_ind_30 or new.price_ind_60 is distinct from old.price_ind_60
       or new.price_grp_30 is distinct from old.price_grp_30 or new.price_grp_60 is distinct from old.price_grp_60
    then raise exception 'Só o administrador pode alterar os dados do professor.'; end if;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles for each row execute function public.guard_profile_update();

create or replace function public.admin_create_teacher(p_name text, p_city text, p_local text, p_contact text, p_bio text, p_i30 numeric, p_i60 numeric, p_g30 numeric, p_g60 numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  if not public.is_admin() then raise exception 'Só o administrador pode cadastrar professores.'; end if;
  insert into public.profiles (name, role, city, local, contact, bio, price_ind_30, price_ind_60, price_grp_30, price_grp_60)
  values (p_name, 'professor', p_city, p_local, p_contact, p_bio, p_i30, p_i60, p_g30, p_g60) returning id into nid;
  return nid;
end $$;
create or replace function public.admin_set_role(p_id uuid, p_role text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só o administrador pode alterar o tipo de conta.'; end if;
  if p_role not in ('jogador', 'professor') then raise exception 'Tipo inválido.'; end if;
  update public.profiles set role = p_role where id = p_id;
end $$;
revoke execute on function public.admin_create_teacher(text, text, text, text, text, numeric, numeric, numeric, numeric), public.admin_set_role(uuid, text) from public, anon;
grant execute on function public.admin_create_teacher(text, text, text, text, text, numeric, numeric, numeric, numeric), public.admin_set_role(uuid, text) to authenticated;

-- fotos (bucket público; cada um grava na própria pasta, admin grava em qualquer uma)
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
create policy "avatars_read" on storage.objects for select using (bucket_id = 'avatars');
create policy "avatars_insert" on storage.objects for insert to authenticated with check (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "avatars_update" on storage.objects for update to authenticated using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "avatars_delete" on storage.objects for delete to authenticated using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ===== Parte 7: aluno pede aula, professor aceita; agenda visível para o aluno =====
alter table public.lessons add column if not exists status text not null default 'confirmada';
alter table public.lessons drop constraint if exists lessons_status_chk;
alter table public.lessons add constraint lessons_status_chk check (status in ('pendente', 'confirmada', 'recusada'));
alter table public.lessons add column if not exists student_id uuid references public.profiles(id) on delete set null;
create policy "lessons_student_select" on public.lessons for select to authenticated using (student_id = auth.uid());
create policy "lessons_student_insert" on public.lessons for insert to authenticated with check (student_id = auth.uid() and status = 'pendente');
create policy "lessons_student_delete" on public.lessons for delete to authenticated using (student_id = auth.uid() and status = 'pendente');
-- guard_lesson passa a ignorar aulas 'recusada' na checagem de sobreposição (função completa na Parte 6 + "and l.status <> 'recusada'")

-- horários ocupados do professor, sem nomes de alunos (para o aluno ver a agenda)
create or replace function public.teacher_agenda(p_teacher uuid)
returns table (day date, "time" text, duration int, kind text, status text, local text, mine boolean)
language sql security definer stable set search_path = public as $$
  select l.day, l.time, l.duration, l.kind, l.status, l.local, (l.student_id = auth.uid())
  from public.lessons l
  where l.teacher = p_teacher and l.status in ('pendente', 'confirmada')
    and l.day >= (now() at time zone 'America/Sao_Paulo')::date
  order by l.day, l.time
$$;
grant execute on function public.teacher_agenda(uuid) to anon, authenticated;

-- ===== Parte 8: forma de pagamento da aula (prazo de 48h) =====
alter table public.lessons add column if not exists payment_method text;
alter table public.lessons drop constraint if exists lessons_payment_chk;
alter table public.lessons add constraint lessons_payment_chk
  check (payment_method is null or payment_method in ('pix', 'dinheiro', 'cartao', 'outro', 'nao_informado'));

-- só dá para escolher depois que a aula terminou, e só em aula confirmada
create or replace function public.guard_payment() returns trigger language plpgsql set search_path = public as $$
begin
  if new.payment_method is not null and new.payment_method is distinct from old.payment_method then
    if new.status <> 'confirmada' then raise exception 'Só aulas confirmadas têm forma de pagamento.'; end if;
    if ((new.day + new.time::time) at time zone 'America/Sao_Paulo') + make_interval(mins => new.duration) > now() then
      raise exception 'A forma de pagamento só pode ser escolhida depois da aula.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists lessons_payment_guard on public.lessons;
create trigger lessons_payment_guard before update of payment_method on public.lessons
  for each row execute function public.guard_payment();

-- 48h depois do fim da aula sem escolha: vira "nao_informado"
create or replace function public.finalize_payments() returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.lessons set payment_method = 'nao_informado'
  where status = 'confirmada' and payment_method is null
    and ((day + time::time) at time zone 'America/Sao_Paulo') + make_interval(mins => duration) + interval '48 hours' < now();
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.finalize_payments() from public, anon, authenticated;

-- finalize_expired (jogos + pagamentos) roda no job de hora em hora e a cada abertura do site
create or replace function public.finalize_expired() returns int language plpgsql security definer set search_path = public as $$
declare x record; n int := 0;
begin
  for x in select id from public.games where done = false and winner is not null and reported_at < now() - interval '48 hours' loop
    perform public._finish_game(x.id); n := n + 1;
  end loop;
  perform public.finalize_payments();
  return n;
end $$;

-- ===== Parte 9: aprovação de professores + avisos push =====
alter table public.profiles add column if not exists approval text not null default 'aprovado';
alter table public.profiles drop constraint if exists profiles_approval_chk;
alter table public.profiles add constraint profiles_approval_chk check (approval in ('pendente', 'aprovado', 'recusado'));
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$ declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb); isprof boolean := (m->>'role') = 'professor'; begin insert into public.profiles (id, name, role, local, bio, city, level, contact, approval, price_ind_30, price_ind_60, price_grp_30, price_grp_60) values (new.id, coalesce(nullif(m->>'name',''), split_part(new.email,'@',1)), case when isprof then 'professor' else 'jogador' end, m->>'local', m->>'bio', m->>'city', coalesce(nullif(m->>'level',''), 'Iniciante'), m->>'contact', case when isprof then 'pendente' else 'aprovado' end, case when m->>'price_ind_30' ~ '^[0-9]+(\.[0-9]+)?$' then (m->>'price_ind_30')::numeric end, case when m->>'price_ind_60' ~ '^[0-9]+(\.[0-9]+)?$' then (m->>'price_ind_60')::numeric end, case when m->>'price_grp_30' ~ '^[0-9]+(\.[0-9]+)?$' then (m->>'price_grp_30')::numeric end, case when m->>'price_grp_60' ~ '^[0-9]+(\.[0-9]+)?$' then (m->>'price_grp_60')::numeric end); return new; end $$;
create or replace function public.admin_set_approval(p_id uuid, p_status text) returns void language plpgsql security definer set search_path = public as $$ begin if not public.is_admin() then raise exception 'Só o administrador pode aprovar professores.'; end if; if p_status not in ('aprovado', 'recusado', 'pendente') then raise exception 'Status inválido.'; end if; update public.profiles set approval = p_status where id = p_id and role = 'professor'; end $$;
revoke execute on function public.admin_set_approval(uuid, text) from public, anon;
grant execute on function public.admin_set_approval(uuid, text) to authenticated;
create or replace function public.admin_set_role(p_id uuid, p_role text) returns void language plpgsql security definer set search_path = public as $$ begin if not public.is_admin() then raise exception 'Só o administrador pode alterar o tipo de conta.'; end if; if p_role not in ('jogador', 'professor') then raise exception 'Tipo inválido.'; end if; update public.profiles set role = p_role, approval = 'aprovado' where id = p_id; end $$;
drop policy if exists "lessons_all" on public.lessons;
create policy "lessons_all" on public.lessons for all to authenticated using (teacher = auth.uid()) with check (teacher = auth.uid() and exists (select 1 from public.profiles p where p.id = auth.uid() and p.approval = 'aprovado'));
drop policy if exists "lessons_student_insert" on public.lessons;
create policy "lessons_student_insert" on public.lessons for insert to authenticated with check (student_id = auth.uid() and status = 'pendente' and exists (select 1 from public.profiles t where t.id = teacher and t.approval = 'aprovado'));
create table if not exists public.push_subscriptions (id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade, endpoint text not null unique, p256dh text not null, auth text not null, created_at timestamptz not null default now());
alter table public.push_subscriptions enable row level security;
drop policy if exists "push_own" on public.push_subscriptions;
create policy "push_own" on public.push_subscriptions for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create extension if not exists pg_net with schema extensions;
create or replace function public.notify_lesson_request() returns trigger language plpgsql security definer set search_path = public, extensions as $$ begin if new.status = 'pendente' then begin perform net.http_post(url := 'https://fecryyqnteetwnvwnvwq.supabase.co/functions/v1/push-lesson', headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', 'TROQUE-PELO-SEGREDO-DA-FUNCAO'), body := jsonb_build_object('teacher', new.teacher, 'title', 'Novo pedido de aula', 'body', new.student || ' pediu aula em ' || to_char(new.day, 'DD/MM') || ' às ' || new.time || '. Toque para aceitar.')); exception when others then null; end; end if; return new; end $$;
drop trigger if exists lessons_notify on public.lessons;
create trigger lessons_notify after insert on public.lessons for each row execute function public.notify_lesson_request();


-- ===== Parte 10: avisos push para alunos e professores =====
-- push_send(): chama a função "push-lesson" (segredo = o mesmo PUSH_SECRET da função)
create or replace function public.push_send(p_user uuid, p_title text, p_body text, p_admins boolean default false)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  begin
    perform net.http_post(
      url := 'https://fecryyqnteetwnvwnvwq.supabase.co/functions/v1/push-lesson',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', 'TROQUE-PELO-SEGREDO-DA-FUNCAO'),
      body := jsonb_build_object('user', p_user, 'admins', p_admins, 'title', p_title, 'body', p_body));
  exception when others then null; end;
end $$;
revoke execute on function public.push_send(uuid, text, text, boolean) from public, anon, authenticated;

-- aula aceita / recusada -> avisa o aluno
create or replace function public.trg_lesson_status() returns trigger language plpgsql security definer set search_path = public as $$
declare t text;
begin
  if new.status is distinct from old.status and new.student_id is not null then
    select name into t from public.profiles where id = new.teacher;
    if new.status = 'confirmada' then
      perform public.push_send(new.student_id, 'Aula confirmada ✅', coalesce(t, 'O professor') || ' aceitou sua aula de ' || to_char(new.day, 'DD/MM') || ' às ' || new.time || '.');
    elsif new.status = 'recusada' then
      perform public.push_send(new.student_id, 'Aula não confirmada', coalesce(t, 'O professor') || ' não pôde aceitar a aula de ' || to_char(new.day, 'DD/MM') || ' às ' || new.time || '. Escolha outro horário.');
    end if;
  end if;
  return new;
end $$;
create trigger lessons_status_push after update of status on public.lessons for each row execute function public.trg_lesson_status();

-- convite para jogar -> avisa quem foi convidado
create or replace function public.trg_request_push() returns trigger language plpgsql security definer set search_path = public as $$
declare n text;
begin
  select name into n from public.profiles where id = new.from_user;
  perform public.push_send(new.to_user, 'Convite para jogar 🎾', coalesce(n, 'Alguém') || ' quer jogar com você. Abra o site para responder.');
  return new;
end $$;
create trigger requests_push after insert on public.requests for each row execute function public.trg_request_push();

-- convite aceito (jogo criado) -> avisa quem convidou
create or replace function public.trg_game_push() returns trigger language plpgsql security definer set search_path = public as $$
declare n text;
begin
  select name into n from public.profiles where id = new.a;
  perform public.push_send(new.b, 'Convite aceito! 🎾', coalesce(n, 'Seu adversário') || ' aceitou jogar com você em ' || to_char(new.day, 'DD/MM') || ' às ' || new.time || '.');
  return new;
end $$;
create trigger games_push after insert on public.games for each row execute function public.trg_game_push();

-- resultado informado -> avisa o adversário; resultado confirmado -> avisa quem informou
create or replace function public.trg_game_result_push() returns trigger language plpgsql security definer set search_path = public as $$
declare n text; other uuid;
begin
  if new.winner is not null and new.reported_by is not null and (old.winner is distinct from new.winner) and not new.done then
    select name into n from public.profiles where id = new.reported_by;
    other := case when new.reported_by = new.a then new.b else new.a end;
    perform public.push_send(other, 'Confirme o resultado 🏆', coalesce(n, 'Seu adversário') || ' informou o resultado do jogo. Confirme ou conteste no site.');
  end if;
  if new.done and not old.done and new.reported_by is not null then
    perform public.push_send(new.reported_by, 'Resultado confirmado ✅', 'Seu adversário confirmou o resultado. O rank foi atualizado.');
  end if;
  return new;
end $$;
create trigger games_result_push after update of winner, done on public.games for each row execute function public.trg_game_result_push();

-- professor: cadastro novo -> avisa admins; aprovado/recusado -> avisa o professor
create or replace function public.trg_profile_push() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.role = 'professor' and new.approval = 'pendente' then
      perform public.push_send(null, 'Novo professor para aprovar 👨‍🏫', new.name || ' se cadastrou e espera sua aprovação.', true);
    end if;
  elsif new.approval is distinct from old.approval and new.role = 'professor' then
    if new.approval = 'aprovado' then perform public.push_send(new.id, 'Cadastro aprovado 🎉', 'Você já pode usar sua agenda e receber pedidos de aula.');
    elsif new.approval = 'recusado' then perform public.push_send(new.id, 'Cadastro não aprovado', 'Fale com o administrador do clube.'); end if;
  end if;
  return new;
end $$;
create trigger profiles_push_ins after insert on public.profiles for each row execute function public.trg_profile_push();
create trigger profiles_push_upd after update of approval on public.profiles for each row execute function public.trg_profile_push();
