-- Beach Tennis Club: jogo "vale ranking" ou "amistoso"
-- Cole no SQL Editor do projeto "Beach Tennis" e clique em Run.

alter table public.invites add column if not exists ranked boolean not null default true;
alter table public.games   add column if not exists ranked boolean not null default true;

-- so soma pontos quando o jogo vale ranking
create or replace function public._finish_game(g uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.games; l uuid;
begin
  select * into r from public.games where id = g and done = false and winner is not null for update;
  if not found then return; end if;
  l := case when r.winner = r.a then r.b else r.a end;
  update public.games set done = true where id = g;
  if r.ranked then
    update public.profiles set rank = rank + 25 where id = r.winner;
    update public.profiles set rank = rank + 5 where id = l;
  end if;
end $$;

-- aviso de resultado confirmado: diz se contou pontos
create or replace function public.trg_game_result_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare n text; other uuid;
begin
  if new.winner is not null and new.reported_by is not null and (old.winner is distinct from new.winner) and not new.done then
    select name into n from public.profiles where id = new.reported_by;
    other := case when new.reported_by = new.a then new.b else new.a end;
    perform public.push_send(other, 'Confirme o resultado 🏆', coalesce(n, 'Seu adversário') || ' informou o resultado do jogo. Confirme ou conteste no site.');
  end if;
  if new.done and not old.done and new.reported_by is not null then
    perform public.push_send(new.reported_by, 'Resultado confirmado ✅',
      case when new.ranked then 'Seu adversário confirmou o resultado. O rank foi atualizado.'
           else 'Seu adversário confirmou o resultado (jogo amistoso, sem pontos).' end);
  end if;
  return new;
end $$;
