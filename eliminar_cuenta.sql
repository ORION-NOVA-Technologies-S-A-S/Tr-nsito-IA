-- PENDIENTE: pega esto en Supabase > proyecto "Alerta Transito" > SQL Editor > Run.
-- Permite que cada usuario borre SU PROPIA cuenta desde la app (requisito de Google Play).
-- Al borrar el usuario se borran en cascada su perfil, reportes, likes y comentarios.

create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'No autenticado'; end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
