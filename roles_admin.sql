-- ============================================================
-- Alerta Tránsito · Roles de administrador y comunidad
-- Pegar en Supabase > proyecto "Alerta Transito" > SQL Editor > Run (una sola vez)
-- ============================================================

-- Roles: 'usuario' (comunidad) y 'admin'
alter table public.profiles
  add column if not exists role text not null default 'usuario' check (role in ('usuario','admin')),
  add column if not exists blocked boolean not null default false;

-- Los usuarios solo pueden editar su nombre y celular (nunca su rol ni su bloqueo)
revoke update on public.profiles from authenticated, anon;
grant update (full_name, phone) on public.profiles to authenticated;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role = 'admin' from public.profiles where id = auth.uid()), false)
$$;
create or replace function public.is_blocked() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select blocked from public.profiles where id = auth.uid()), false)
$$;
revoke execute on function public.is_admin(), public.is_blocked() from public, anon;
grant execute on function public.is_admin(), public.is_blocked() to authenticated;

-- Perfiles: cada quien ve el suyo y el admin ve todos (el celular deja de ser visible para otros usuarios)
drop policy if exists "perfiles visibles" on public.profiles;
drop policy if exists "ver mi perfil o admin" on public.profiles;
create policy "ver mi perfil o admin" on public.profiles for select to authenticated
  using ((select auth.uid()) = id or (select public.is_admin()));

-- Nombres públicos para los comentarios (solo id y nombre)
create or replace function public.profile_names(ids uuid[]) returns table (id uuid, full_name text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.full_name from public.profiles p where p.id = any(ids)
$$;
revoke execute on function public.profile_names(uuid[]) from public, anon;
grant execute on function public.profile_names(uuid[]) to authenticated;

-- Reportes, votos y comentarios: los bloqueados no pueden publicar y el admin puede borrar todo
drop policy if exists "crear mis reportes" on public.reports;
create policy "crear mis reportes" on public.reports for insert to authenticated
  with check ((select auth.uid()) = user_id and not (select public.is_blocked()));
drop policy if exists "borrar mis reportes" on public.reports;
drop policy if exists "borrar mis reportes o admin" on public.reports;
create policy "borrar mis reportes o admin" on public.reports for delete to authenticated
  using ((select auth.uid()) = user_id or (select public.is_admin()));

drop policy if exists "votar" on public.report_votes;
create policy "votar" on public.report_votes for insert to authenticated
  with check ((select auth.uid()) = user_id and not (select public.is_blocked()));

drop policy if exists "comentar" on public.report_comments;
create policy "comentar" on public.report_comments for insert to authenticated
  with check ((select auth.uid()) = user_id and not (select public.is_blocked()));
drop policy if exists "borrar mi comentario" on public.report_comments;
drop policy if exists "borrar mi comentario o admin" on public.report_comments;
create policy "borrar mi comentario o admin" on public.report_comments for delete to authenticated
  using ((select auth.uid()) = user_id or (select public.is_admin()));

-- Funciones solo para el administrador
create or replace function public.admin_list_users() returns table (
  id uuid, email text, full_name text, phone text, role text, blocked boolean,
  created_at timestamptz, last_sign_in_at timestamptz, reports bigint
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  return query
    select u.id, u.email::text, p.full_name, p.phone, p.role, p.blocked, u.created_at, u.last_sign_in_at,
      (select count(*) from public.reports r where r.user_id = u.id)
    from auth.users u join public.profiles p on p.id = u.id
    order by u.created_at desc;
end $$;

create or replace function public.admin_set_blocked(target uuid, value boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  if target = auth.uid() then raise exception 'No puedes bloquear tu propia cuenta'; end if;
  update public.profiles set blocked = value where id = target;
end $$;

create or replace function public.admin_set_role(target uuid, new_role text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  if target = auth.uid() then raise exception 'No puedes cambiar tu propio rol'; end if;
  if new_role not in ('usuario','admin') then raise exception 'Rol inválido'; end if;
  update public.profiles set role = new_role where id = target;
end $$;

revoke execute on function public.admin_list_users(), public.admin_set_blocked(uuid, boolean), public.admin_set_role(uuid, text) from public, anon;
grant execute on function public.admin_list_users(), public.admin_set_blocked(uuid, boolean), public.admin_set_role(uuid, text) to authenticated;

-- Carlos es el administrador
update public.profiles set role = 'admin'
where id = (select id from auth.users where email = 'carlosdanielculmap@gmail.com');
