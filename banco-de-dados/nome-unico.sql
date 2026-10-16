-- =====================================================================
-- Nomes únicos: ninguém pode ter o mesmo nome de outra pessoa (sem diferenciar
-- maiúsculas, acentos nem espaços repetidos). Evita confusão em convites, ranking e duplas.
--  * name_available(): o app pergunta antes de cadastrar ou trocar o nome
--  * índice único: garante a regra mesmo se alguém tentar burlar o app
-- Cole no SQL Editor e clique em Run. Pode rodar mais de uma vez.
-- Se já existirem nomes repetidos, o índice não é criado e o aviso aparece nas mensagens
-- (o app continua barrando nomes novos repetidos pelo name_available()).
-- =====================================================================

create or replace function public.norm_name(t text) returns text
language sql immutable as $$
  select lower(translate(btrim(regexp_replace(coalesce(t, ''), '\s+', ' ', 'g')),
    'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
    'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN'))
$$;

create or replace function public.name_available(p_name text, p_except uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.profiles
     where public.norm_name(name) = public.norm_name(p_name)
       and id is distinct from p_except)
$$;
revoke execute on function public.name_available(text, uuid) from public;
grant execute on function public.name_available(text, uuid) to anon, authenticated;

do $$
begin
  if exists (select 1 from public.profiles group by public.norm_name(name) having count(*) > 1) then
    raise notice 'Existem nomes repetidos: o índice único NÃO foi criado. Corrija os nomes e rode de novo.';
  else
    create unique index if not exists profiles_name_unique on public.profiles (public.norm_name(name));
  end if;
end $$;
