-- ============================================================
-- Alerta Tránsito · El administrador puede eliminar usuarios
-- Pegar en Supabase > proyecto "Alerta Transito" > SQL Editor > Run (una sola vez)
-- ============================================================
-- Borra la cuenta y, en cascada, su perfil, reportes, confirmaciones, comentarios y solicitudes.
-- Los pagos del libro de Finanzas se conservan (quedan sin usuario, con el nombre del cliente).
create or replace function public.admin_delete_user(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  if target = auth.uid() then raise exception 'No puedes eliminar tu propia cuenta desde aquí'; end if;
  if exists (select 1 from public.profiles where id = target and role = 'admin') then
    raise exception 'Primero quítale el rol de administrador a este usuario';
  end if;
  delete from auth.users where id = target;
end $$;
revoke execute on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;
