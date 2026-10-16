-- =====================================================================
-- Tênis de Campo Club: melhorias v2
--  * Aviso de convite mais curto
--  * Lembrete diário (9h) para informar o resultado de jogos que já passaram
--  * Denúncia de jogador (vai para o administrador)
-- Cole no SQL Editor e clique em Run. Pode rodar mais de uma vez.
-- =====================================================================

create or replace function public.trg_request_push() returns trigger language plpgsql security definer set search_path = public as $$
declare n text;
begin
  select name into n from public.profiles where id = new.from_user;
  perform public.push_send(new.to_user, '🎾 ' || coalesce(n, 'Alguém') || ' te convidou', 'Toque para aceitar ou recusar o convite.');
  return new;
end $$;

-- ----- lembrete de resultado pendente -----
alter table public.games add column if not exists result_reminded_at timestamptz;

create or replace function public.remind_pending_results() returns int
language plpgsql security definer set search_path = public as $$
declare g record; n int := 0; nm text;
begin
  for g in
    select * from public.games
     where done = false and winner is null and result_reminded_at is null
       and day < (now() at time zone 'America/Sao_Paulo')::date
       and day >= (now() at time zone 'America/Sao_Paulo')::date - 7
  loop
    select name into nm from public.profiles where id = g.b;
    perform public.push_send(g.a, '🏆 Como foi o jogo?', 'Informe o resultado do jogo com ' || coalesce(nm, 'seu adversário') || ' para atualizar o ranking.');
    select name into nm from public.profiles where id = g.a;
    perform public.push_send(g.b, '🏆 Como foi o jogo?', 'Informe o resultado do jogo com ' || coalesce(nm, 'seu adversário') || ' para atualizar o ranking.');
    update public.games set result_reminded_at = now() where id = g.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.remind_pending_results() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'remind-pending-results') then perform cron.unschedule('remind-pending-results'); end if;
exception when others then null; end $$;
select cron.schedule('remind-pending-results', '0 12 * * *', 'select public.remind_pending_results()');

-- ----- denúncias -----
create table if not exists public.player_reports (
  id uuid primary key default gen_random_uuid(),
  reporter uuid not null references public.profiles(id) on delete cascade,
  reported uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (char_length(reason) between 3 and 400),
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.player_reports enable row level security;
drop policy if exists "reports_admin_read" on public.player_reports;
create policy "reports_admin_read" on public.player_reports for select to authenticated using (public.is_admin());
drop policy if exists "reports_admin_update" on public.player_reports;
create policy "reports_admin_update" on public.player_reports for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "reports_admin_delete" on public.player_reports;
create policy "reports_admin_delete" on public.player_reports for delete to authenticated using (public.is_admin());
grant select, update, delete on public.player_reports to authenticated;

create or replace function public.report_player(p_reported uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare r text := nullif(btrim(coalesce(p_reason, '')), ''); n text;
begin
  if auth.uid() is null then raise exception 'Entre para denunciar.'; end if;
  if p_reported = auth.uid() then raise exception 'Você não pode denunciar a si mesmo.'; end if;
  if r is null or char_length(r) < 3 then raise exception 'Conte rapidamente o que aconteceu.'; end if;
  if (select count(*) from public.player_reports where reporter = auth.uid() and created_at > now() - interval '1 day') >= 5 then
    raise exception 'Muitas denúncias hoje. Tente amanhã.';
  end if;
  insert into public.player_reports(reporter, reported, reason) values (auth.uid(), p_reported, left(r, 400));
  select name into n from public.profiles where id = p_reported;
  perform public.push_send(null, '🚩 Nova denúncia', 'Sobre ' || coalesce(n, 'um jogador') || '. Veja na área do administrador.', true);
end $$;
revoke execute on function public.report_player(uuid, text) from public, anon;
grant execute on function public.report_player(uuid, text) to authenticated;
