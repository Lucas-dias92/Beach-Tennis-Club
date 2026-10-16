-- =====================================================================
-- Beach Tennis Club: privacidade do WhatsApp + Plano Pro + Torneios + Pix
-- Cole TUDO no SQL Editor do projeto "Beach Tennis" e clique em Run.
-- Pode rodar mais de uma vez sem problema.
-- =====================================================================

-- ---------- 1) colunas novas ----------
alter table public.profiles add column if not exists plan text not null default 'free';
alter table public.profiles drop constraint if exists profiles_plan_chk;
alter table public.profiles add constraint profiles_plan_chk check (plan in ('free', 'pro'));
alter table public.profiles add column if not exists featured boolean not null default false;
alter table public.profiles add column if not exists pix_key text;

-- ---------- 2) privacidade: contact e pix_key nao sao legiveis pela chave publica ----------
revoke select on public.profiles from anon, authenticated;
grant select (id, name, role, rank, local, bio, price, created_at, city, level, photo_url,
              price_ind_30, price_ind_60, price_grp_30, price_grp_60, is_admin, approval, plan, featured)
  on public.profiles to anon, authenticated;
grant update (pix_key) on public.profiles to authenticated;

-- WhatsApp: professor aprovado = publico | o proprio | admin | professor ve os alunos das suas aulas
create or replace function public.get_contacts()
returns table (id uuid, contact text)
language sql security definer stable set search_path = public as $$
  select p.id, p.contact
  from public.profiles p
  where p.contact is not null
    and ( (p.role = 'professor' and p.approval = 'aprovado')
          or (p.is_admin and p.local is not null)
          or p.id = auth.uid()
          or public.is_admin()
          or exists (select 1 from public.lessons l
                     where l.teacher = auth.uid() and l.student_id = p.id and l.status <> 'recusada') )
$$;
grant execute on function public.get_contacts() to anon, authenticated;

-- Pix do professor: so ele, o admin e alunos com aula confirmada
create or replace function public.get_lesson_pix(p_teacher uuid) returns text
language sql security definer stable set search_path = public as $$
  select p.pix_key from public.profiles p
  where p.id = p_teacher
    and ( auth.uid() = p_teacher or public.is_admin()
          or exists (select 1 from public.lessons l
                     where l.teacher = p_teacher and l.student_id = auth.uid() and l.status = 'confirmada') )
$$;
grant execute on function public.get_lesson_pix(uuid) to authenticated;

-- ---------- 3) cadastro: WhatsApp com DDD obrigatorio tambem no banco ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
        isprof boolean := (m->>'role') = 'professor';
begin
  if coalesce(m->>'contact', '') !~ '^[0-9]{10,11}$' then
    raise exception 'Informe o WhatsApp com DDD (10 ou 11 números).';
  end if;
  insert into public.profiles (id, name, role, local, bio, city, level, contact, approval,
                               price_ind_30, price_ind_60, price_grp_30, price_grp_60)
  values (new.id,
          coalesce(nullif(m->>'name',''), split_part(new.email,'@',1)),
          case when isprof then 'professor' else 'jogador' end,
          m->>'local', m->>'bio', m->>'city',
          coalesce(nullif(m->>'level',''), 'Iniciante'),
          m->>'contact',
          case when isprof then 'pendente' else 'aprovado' end,
          case when m->>'price_ind_30' ~ '^[0-9]+(\.[0-9]+)?$' then (m->>'price_ind_30')::numeric end,
          case when m->>'price_ind_60' ~ '^[0-9]+(\.[0-9]+)?$' then (m->>'price_ind_60')::numeric end,
          case when m->>'price_grp_30' ~ '^[0-9]+(\.[0-9]+)?$' then (m->>'price_grp_30')::numeric end,
          case when m->>'price_grp_60' ~ '^[0-9]+(\.[0-9]+)?$' then (m->>'price_grp_60')::numeric end);
  return new;
end $$;

-- ---------- 4) configuracao do app: "Pro liberado para todos" (modo teste) ----------
create table if not exists public.app_settings (key text primary key, value text not null);
alter table public.app_settings enable row level security;
drop policy if exists "settings_read" on public.app_settings;
create policy "settings_read" on public.app_settings for select using (true);
insert into public.app_settings (key, value) values ('pro_for_all', 'true') on conflict (key) do nothing;

create or replace function public.admin_set_setting(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só o administrador altera as configurações.'; end if;
  insert into public.app_settings (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
end $$;
revoke execute on function public.admin_set_setting(text, text) from public, anon;
grant execute on function public.admin_set_setting(text, text) to authenticated;

create or replace function public.admin_set_plan(p_id uuid, p_plan text, p_featured boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só o administrador altera o plano.'; end if;
  if p_plan not in ('free', 'pro') then raise exception 'Plano inválido.'; end if;
  update public.profiles set plan = p_plan, featured = coalesce(p_featured, false) where id = p_id;
end $$;
revoke execute on function public.admin_set_plan(uuid, text, boolean) from public, anon;
grant execute on function public.admin_set_plan(uuid, text, boolean) to authenticated;

-- ---------- 5) torneios ----------
create table if not exists public.tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  day date not null,
  time text not null,
  arena text not null,
  city text,
  format text not null default 'duplas',
  fee numeric not null default 0,
  max_players int not null default 16 check (max_players between 2 and 256),
  sponsor text,
  description text,
  pix_key text,
  status text not null default 'aberto' check (status in ('aberto', 'encerrado', 'cancelado')),
  first uuid references public.profiles(id) on delete set null,
  second uuid references public.profiles(id) on delete set null,
  third uuid references public.profiles(id) on delete set null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.tournament_entries (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  player_id uuid not null references public.profiles(id) on delete cascade,
  paid boolean not null default false,
  created_at timestamptz not null default now(),
  unique (tournament_id, player_id)
);
alter table public.tournaments enable row level security;
alter table public.tournament_entries enable row level security;

drop policy if exists "tournaments_read" on public.tournaments;
create policy "tournaments_read" on public.tournaments for select using (true);
drop policy if exists "tournaments_admin" on public.tournaments;
create policy "tournaments_admin" on public.tournaments for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "entries_read" on public.tournament_entries;
create policy "entries_read" on public.tournament_entries for select to authenticated using (true);
drop policy if exists "entries_join" on public.tournament_entries;
create policy "entries_join" on public.tournament_entries for insert to authenticated
  with check (player_id = auth.uid() and paid = false);
drop policy if exists "entries_leave" on public.tournament_entries;
create policy "entries_leave" on public.tournament_entries for delete to authenticated
  using ((player_id = auth.uid() and paid = false) or public.is_admin());
drop policy if exists "entries_admin_update" on public.tournament_entries;
create policy "entries_admin_update" on public.tournament_entries for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- inscricao: torneio aberto e com vaga
create or replace function public.guard_entry() returns trigger language plpgsql security definer set search_path = public as $$
declare t public.tournaments; n int;
begin
  select * into t from public.tournaments where id = new.tournament_id;
  if not found or t.status <> 'aberto' then raise exception 'Este torneio não está aberto para inscrições.'; end if;
  select count(*) into n from public.tournament_entries where tournament_id = new.tournament_id;
  if n >= t.max_players then raise exception 'Torneio lotado.'; end if;
  return new;
end $$;
drop trigger if exists entries_guard on public.tournament_entries;
create trigger entries_guard before insert on public.tournament_entries
  for each row execute function public.guard_entry();

-- encerrar e premiar: 1o +50, 2o +30, 3o +15 pontos no ranking
create or replace function public.admin_finish_tournament(p_id uuid, p_first uuid, p_second uuid, p_third uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só o administrador encerra torneios.'; end if;
  update public.tournaments set status = 'encerrado', first = p_first, second = p_second, third = p_third
  where id = p_id and status = 'aberto';
  if not found then raise exception 'Torneio não encontrado ou já encerrado.'; end if;
  if p_first  is not null then update public.profiles set rank = rank + 50 where id = p_first;  end if;
  if p_second is not null then update public.profiles set rank = rank + 30 where id = p_second; end if;
  if p_third  is not null then update public.profiles set rank = rank + 15 where id = p_third;  end if;
end $$;
revoke execute on function public.admin_finish_tournament(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.admin_finish_tournament(uuid, uuid, uuid, uuid) to authenticated;
