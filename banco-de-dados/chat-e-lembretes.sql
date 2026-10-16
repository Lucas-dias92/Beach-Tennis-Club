-- Beach Tennis Club: chat entre membros + lembrete de jogo (2h antes, ajustavel)
-- Cole no SQL Editor do projeto "Beach Tennis" e clique em Run.

-- ============ CHAT ============
create table if not exists public.dm (
  id uuid primary key default gen_random_uuid(),
  sender uuid not null references public.profiles(id) on delete cascade,
  receiver uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists dm_receiver_idx on public.dm (receiver, sender, created_at desc);
create index if not exists dm_sender_idx   on public.dm (sender, receiver, created_at desc);
alter table public.dm enable row level security;

drop policy if exists "dm_select" on public.dm;
create policy "dm_select" on public.dm for select to authenticated
  using (sender = auth.uid() or receiver = auth.uid());
drop policy if exists "dm_insert" on public.dm;
create policy "dm_insert" on public.dm for insert to authenticated
  with check (sender = auth.uid() and receiver <> auth.uid());

-- marcar como lida (so quem recebeu)
create or replace function public.dm_mark_read(p_other uuid) returns void
language sql security definer set search_path = public as $$
  update public.dm set read_at = now()
   where receiver = auth.uid() and sender = p_other and read_at is null;
$$;
revoke execute on function public.dm_mark_read(uuid) from public, anon;
grant execute on function public.dm_mark_read(uuid) to authenticated;

-- aviso no celular quando chega mensagem (no maximo 1 a cada 2 minutos por conversa)
create or replace function public.trg_dm_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  if exists (select 1 from public.dm
              where sender = new.sender and receiver = new.receiver and id <> new.id
                and read_at is null and created_at > now() - interval '2 minutes') then
    return new;
  end if;
  select name into n from public.profiles where id = new.sender;
  perform public.push_send(new.receiver, '💬 ' || coalesce(n, 'Nova mensagem'), left(new.body, 90));
  return new;
end $$;
drop trigger if exists dm_push on public.dm;
create trigger dm_push after insert on public.dm for each row execute function public.trg_dm_push();

-- ============ LEMBRETE DE JOGO ============
create table if not exists public.user_prefs (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  remind_min int not null default 120 check (remind_min between 0 and 2880)
);
alter table public.user_prefs enable row level security;
drop policy if exists "prefs_select" on public.user_prefs;
create policy "prefs_select" on public.user_prefs for select to authenticated using (user_id = auth.uid());

create table if not exists public.game_reminders (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (game_id, user_id)
);
alter table public.game_reminders enable row level security;

-- a pessoa escolhe com quanta antecedencia quer o lembrete (0 = desligado)
create or replace function public.set_remind(p_min int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Entre para continuar.'; end if;
  if p_min < 0 or p_min > 2880 then raise exception 'Valor invalido.'; end if;
  insert into public.user_prefs (user_id, remind_min) values (auth.uid(), p_min)
  on conflict (user_id) do update set remind_min = excluded.remind_min;
  -- se mudou o horario, vale de novo para os jogos que ainda nao comecaram
  delete from public.game_reminders gr using public.games g
   where gr.game_id = g.id and gr.user_id = auth.uid() and g.done = false;
end $$;
revoke execute on function public.set_remind(int) from public, anon;
grant execute on function public.set_remind(int) to authenticated;

create or replace function public.send_game_reminders() returns void
language plpgsql security definer set search_path = public as $$
declare r record; u uuid; starts timestamptz; mins int; opp text; lbl text;
begin
  for r in
    select * from public.games
     where done = false
       and day >= ((now() at time zone 'America/Sao_Paulo')::date - 1)
       and day <= ((now() at time zone 'America/Sao_Paulo')::date + 3)
  loop
    starts := ((r.day::text || ' ' || left(r.time::text, 5))::timestamp) at time zone 'America/Sao_Paulo';
    foreach u in array array[r.a, r.b] loop
      if u is null then continue; end if;
      select coalesce((select remind_min from public.user_prefs where user_id = u), 120) into mins;
      if mins = 0 then continue; end if;
      if starts <= now() or starts - make_interval(mins => mins) > now() then continue; end if;
      insert into public.game_reminders (game_id, user_id) values (r.id, u) on conflict do nothing;
      if found then
        select name into opp from public.profiles
         where id = case when u = r.a then r.b else r.a end;
        lbl := case when mins >= 1440 then 'amanhã' when mins >= 120 then 'em ' || (mins / 60) || ' horas'
                    when mins >= 60 then 'em 1 hora' else 'em ' || mins || ' minutos' end;
        perform public.push_send(u, 'Lembrete de jogo 🎾',
          'Seu jogo' || coalesce(' com ' || opp, '') || ' é ' || lbl || ' (' || to_char(r.day, 'DD/MM') || ' às ' || left(r.time::text, 5) || ').');
      end if;
    end loop;
  end loop;
end $$;
revoke execute on function public.send_game_reminders() from public, anon, authenticated;

-- roda a cada 5 minutos
select cron.unschedule('game-reminders') where exists (select 1 from cron.job where jobname = 'game-reminders');
select cron.schedule('game-reminders', '*/5 * * * *', 'select public.send_game_reminders()');
