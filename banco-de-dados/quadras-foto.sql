-- Quadras com foto, gratuitas ou pagas, e cadastro aberto aos jogadores.
--  * photo_url: foto da quadra   * free: quadra gratuita   * reservable: reservar horários pelo app
--  * qualquer jogador logado cadastra até 5 quadras (ele passa a ser o gestor); o administrador cadastra sem limite
--  * o gestor edita e exclui a própria quadra; o administrador edita e exclui qualquer uma
alter table public.arenas add column if not exists photo_url text;
alter table public.arenas add column if not exists free boolean not null default false;
alter table public.arenas add column if not exists reservable boolean not null default true;

drop policy if exists "arenas_insert" on public.arenas;
create policy "arenas_insert" on public.arenas for insert to authenticated
  with check (public.is_admin()
              or (owner = auth.uid() and (select count(*) from public.arenas x where x.owner = auth.uid()) < 5));
drop policy if exists "arenas_delete" on public.arenas;
create policy "arenas_delete" on public.arenas for delete to authenticated
  using (public.is_admin() or owner = auth.uid());
