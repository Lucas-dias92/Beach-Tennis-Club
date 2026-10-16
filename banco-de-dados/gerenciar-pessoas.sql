-- Beach Tennis Club: admin gerencia pessoas (tornar aluno / excluir)
-- Cole no SQL Editor do projeto "Beach Tennis" e clique em Run.

-- Tornar aluno: deixa de ser professor, perde plano/destaque e os pedidos de aula pendentes sao recusados
create or replace function public.admin_demote_to_student(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só o administrador altera o tipo de conta.'; end if;
  if exists (select 1 from public.profiles where id = p_id and is_admin) then
    raise exception 'Não é possível alterar uma conta de administrador.';
  end if;
  update public.profiles
     set role = 'jogador', plan = 'free', featured = false, approval = 'aprovado'
   where id = p_id;
  update public.lessons set status = 'recusada' where teacher = p_id and status = 'pendente';
end $$;
revoke execute on function public.admin_demote_to_student(uuid) from public, anon;
grant execute on function public.admin_demote_to_student(uuid) to authenticated;

-- Excluir: apaga o perfil (e, em cascata, convites, jogos, aulas, inscricoes) e a conta de login
create or replace function public.admin_delete_user(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só o administrador exclui contas.'; end if;
  if p_id = auth.uid() then raise exception 'Você não pode excluir a sua própria conta.'; end if;
  if exists (select 1 from public.profiles where id = p_id and is_admin) then
    raise exception 'Não é possível excluir uma conta de administrador.';
  end if;
  delete from public.profiles where id = p_id;
  delete from auth.users where id = p_id;
end $$;
revoke execute on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;
