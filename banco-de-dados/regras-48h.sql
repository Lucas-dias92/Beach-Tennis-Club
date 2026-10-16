-- Beach Tennis Club: regra das 48 horas (resultado sem resposta vale o informado)
-- Cole no SQL Editor do projeto "Beach Tennis" e clique em Run. Pode rodar mais de uma vez.

alter table public.games add column if not exists reported_at timestamptz;

create or replace function public.report_result(g uuid, w uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.games;
begin
  select * into r from public.games where id = g and done = false;
  if not found then raise exception 'Jogo não encontrado ou já encerrado'; end if;
  if auth.uid() not in (r.a, r.b) then raise exception 'Você não participa deste jogo'; end if;
  if w not in (r.a, r.b) then raise exception 'Vencedor inválido'; end if;
  update public.games set winner = w, reported_by = auth.uid(), reported_at = now() where id = g;
end $$;

create or replace function public.contest_result(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.games;
begin
  select * into r from public.games where id = g and done = false and winner is not null;
  if not found then raise exception 'Nenhum resultado para contestar'; end if;
  if auth.uid() not in (r.a, r.b) or auth.uid() = r.reported_by then raise exception 'Só o outro jogador pode contestar'; end if;
  if r.reported_at is not null and r.reported_at < now() - interval '48 hours' then raise exception 'O prazo para contestar acabou.'; end if;
  update public.games set winner = null, reported_by = null, reported_at = null where id = g;
end $$;

revoke execute on function public.report_result(uuid, uuid), public.contest_result(uuid) from public, anon;
grant execute on function public.report_result(uuid, uuid), public.contest_result(uuid) to authenticated;

-- resultados que ja estavam aguardando e nao tinham data: o prazo de 48h passa a contar a partir de agora
update public.games set reported_at = now() where done = false and winner is not null and reported_at is null;
