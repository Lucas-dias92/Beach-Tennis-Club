-- Beach Tennis Club: WhatsApp privado + obrigatorio no cadastro
-- Cole tudo no SQL Editor do projeto "Beach Tennis" e clique em Run.

-- 1) a chave publica deixa de poder ler a coluna "contact"
revoke select on public.profiles from anon, authenticated;
grant select (id, name, role, rank, local, bio, price, created_at, city, level, photo_url,
              price_ind_30, price_ind_60, price_grp_30, price_grp_60, is_admin, approval)
  on public.profiles to anon, authenticated;

-- 2) quem pode ver o WhatsApp de quem:
--    professor aprovado = publico (botao WhatsApp) | o proprio dono | o admin (todos)
create or replace function public.get_contacts()
returns table (id uuid, contact text)
language sql security definer stable set search_path = public as $$
  select p.id, p.contact
  from public.profiles p
  where p.contact is not null
    and ( (p.role = 'professor' and p.approval = 'aprovado')
          or (p.is_admin and p.local is not null)
          or p.id = auth.uid()
          or public.is_admin() )
$$;
grant execute on function public.get_contacts() to anon, authenticated;

-- 3) cadastro: WhatsApp com DDD (10 ou 11 numeros) e obrigatorio tambem no banco
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
        isprof boolean := (m->>'role') = 'professor';
begin
  if coalesce(m->>'contact', '') !~ '^[0-9]{10,11}$' then
    raise exception 'Informe o WhatsApp com DDD (10 ou 11 nÃºmeros).';
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