-- ============================================================
-- Alerta Tránsito · Planes Plus y Empresa
-- Pegar en Supabase > proyecto "Alerta Transito" > SQL Editor > Run (una sola vez)
-- ============================================================

-- 1. Ajustes de cobro (los edita el administrador desde la app)
create table if not exists public.app_settings (
  id int primary key default 1 check (id = 1),
  plus_price int not null default 6900,
  empresa_price int not null default 89900,
  empresa_seats int not null default 10,
  pay_instructions text not null default 'Paga por Nequi o transferencia y escribe el número de la transacción en la solicitud.',
  updated_at timestamptz not null default now()
);
insert into public.app_settings (id) values (1) on conflict (id) do nothing;
alter table public.app_settings enable row level security;
drop policy if exists "ver ajustes" on public.app_settings;
create policy "ver ajustes" on public.app_settings for select to authenticated using (true);
drop policy if exists "admin edita ajustes" on public.app_settings;
create policy "admin edita ajustes" on public.app_settings for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- 2. Empresas
create table if not exists public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 120),
  nit text,
  owner_id uuid not null references auth.users(id) on delete cascade,
  seats int not null default 10 check (seats between 1 and 500),
  plan_until timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists companies_owner_idx on public.companies (owner_id);
alter table public.companies enable row level security;

-- 3. Plan de cada usuario
alter table public.profiles
  add column if not exists plan text not null default 'gratis' check (plan in ('gratis','plus')),
  add column if not exists plan_until timestamptz,
  add column if not exists company_id uuid references public.companies(id) on delete set null;
create index if not exists profiles_company_idx on public.profiles (company_id);

drop policy if exists "ver mi empresa" on public.companies;
create policy "ver mi empresa" on public.companies for select to authenticated
  using (owner_id = (select auth.uid())
    or id = (select company_id from public.profiles where id = (select auth.uid()))
    or (select public.is_admin()));

-- 4. Solicitudes de plan
create table if not exists public.plan_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  plan text not null check (plan in ('plus','empresa')),
  company_name text check (company_name is null or char_length(company_name) <= 120),
  nit text check (nit is null or char_length(nit) <= 30),
  contact_phone text check (contact_phone is null or char_length(contact_phone) <= 20),
  payment_ref text check (payment_ref is null or char_length(payment_ref) <= 120),
  status text not null default 'pendiente' check (status in ('pendiente','aprobada','rechazada')),
  admin_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists plan_requests_user_idx on public.plan_requests (user_id);
create index if not exists plan_requests_status_idx on public.plan_requests (status);
alter table public.plan_requests enable row level security;
drop policy if exists "ver mis solicitudes" on public.plan_requests;
create policy "ver mis solicitudes" on public.plan_requests for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));
drop policy if exists "crear solicitud" on public.plan_requests;
create policy "crear solicitud" on public.plan_requests for insert to authenticated
  with check (user_id = (select auth.uid()) and status = 'pendiente' and admin_note is null and reviewed_at is null);

-- 5. Plan efectivo del usuario actual
create or replace function public.my_plan() returns table (
  plan text, plan_until timestamptz, company_id uuid, company_name text, is_owner boolean, seats int, members bigint
)
language sql stable security definer set search_path = '' as $$
  select
    case
      when c.id is not null and c.plan_until > now() then 'empresa'
      when p.plan = 'plus' and p.plan_until > now() then 'plus'
      else 'gratis'
    end,
    case
      when c.id is not null and c.plan_until > now() then c.plan_until
      when p.plan = 'plus' then p.plan_until
      else null
    end,
    c.id, c.name, coalesce(c.owner_id = p.id, false), c.seats,
    (select count(*) from public.profiles m where m.company_id = c.id)
  from public.profiles p
  left join public.companies c on c.id = p.company_id
  where p.id = auth.uid()
$$;

-- 6. Funciones del dueño de la empresa
create or replace function public.company_members() returns table (
  id uuid, email text, full_name text, is_owner boolean, last_sign_in_at timestamptz, reports_7d bigint
)
language plpgsql stable security definer set search_path = '' as $$
declare cid uuid;
begin
  select c.id into cid from public.companies c where c.owner_id = auth.uid();
  if cid is null then raise exception 'Solo el dueño de la empresa puede ver sus conductores'; end if;
  return query
    select u.id, u.email::text, p.full_name, u.id = auth.uid(), u.last_sign_in_at,
      (select count(*) from public.reports r where r.user_id = u.id and r.created_at > now() - interval '7 days')
    from public.profiles p join auth.users u on u.id = p.id
    where p.company_id = cid
    order by (u.id = auth.uid()) desc, p.full_name;
end $$;

create or replace function public.company_add_member(member_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare cid uuid; cseats int; used int; target uuid; other uuid;
begin
  select c.id, c.seats into cid, cseats from public.companies c where c.owner_id = auth.uid();
  if cid is null then raise exception 'Solo el dueño de la empresa puede agregar conductores'; end if;
  select count(*) into used from public.profiles where company_id = cid;
  if used >= cseats then raise exception 'Ya usaste todos los cupos de tu plan (%)', cseats; end if;
  select u.id into target from auth.users u where lower(u.email) = lower(trim(member_email));
  if target is null then raise exception 'Ese correo no tiene cuenta en Alerta Tránsito. Pídele que se registre primero.'; end if;
  select company_id into other from public.profiles where id = target;
  if other is not null and other <> cid then raise exception 'Ese usuario ya pertenece a otra empresa'; end if;
  update public.profiles set company_id = cid where id = target;
end $$;

create or replace function public.company_remove_member(member uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare cid uuid;
begin
  select c.id into cid from public.companies c where c.owner_id = auth.uid();
  if cid is null then raise exception 'Solo el dueño de la empresa puede quitar conductores'; end if;
  if member = auth.uid() then raise exception 'No puedes quitarte a ti mismo de tu empresa'; end if;
  update public.profiles set company_id = null where id = member and company_id = cid;
end $$;

-- 7. Funciones del administrador
create or replace function public.admin_list_requests() returns table (
  id uuid, user_id uuid, email text, full_name text, plan text, company_name text, nit text,
  contact_phone text, payment_ref text, status text, created_at timestamptz, reviewed_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  return query
    select r.id, r.user_id, u.email::text, p.full_name, r.plan, r.company_name, r.nit,
      r.contact_phone, r.payment_ref, r.status, r.created_at, r.reviewed_at
    from public.plan_requests r
    join auth.users u on u.id = r.user_id
    join public.profiles p on p.id = r.user_id
    order by (r.status = 'pendiente') desc, r.created_at desc
    limit 200;
end $$;

create or replace function public.admin_approve_request(req uuid, months int) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.plan_requests; s public.app_settings; cid uuid; base timestamptz;
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  if months not between 1 and 24 then raise exception 'Meses inválidos'; end if;
  select * into r from public.plan_requests where id = req for update;
  if r.id is null then raise exception 'Solicitud no encontrada'; end if;
  if r.status <> 'pendiente' then raise exception 'Esta solicitud ya fue revisada'; end if;
  select * into s from public.app_settings where id = 1;
  if r.plan = 'plus' then
    select greatest(coalesce(plan_until, now()), now()) into base from public.profiles where id = r.user_id;
    update public.profiles set plan = 'plus', plan_until = base + make_interval(0, months) where id = r.user_id;
  else
    select c.id, greatest(c.plan_until, now()) into cid, base from public.companies c where c.owner_id = r.user_id;
    if cid is null then
      insert into public.companies (name, nit, owner_id, seats, plan_until)
      values (coalesce(nullif(trim(r.company_name), ''), 'Mi empresa'), r.nit, r.user_id, s.empresa_seats, now() + make_interval(0, months))
      returning id into cid;
    else
      update public.companies set plan_until = base + make_interval(0, months) where id = cid;
    end if;
    update public.profiles set company_id = cid where id = r.user_id;
  end if;
  update public.plan_requests set status = 'aprobada', reviewed_at = now() where id = req;
end $$;

create or replace function public.admin_reject_request(req uuid, note text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  update public.plan_requests set status = 'rechazada', admin_note = left(note, 300), reviewed_at = now()
  where id = req and status = 'pendiente';
end $$;

create or replace function public.admin_list_subscriptions() returns table (
  kind text, name text, email text, plan_until timestamptz, seats int, members bigint, owner_or_user uuid
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  return query
    select 'plus'::text, p.full_name, u.email::text, p.plan_until, null::int, null::bigint, p.id
      from public.profiles p join auth.users u on u.id = p.id
      where p.plan = 'plus' and p.plan_until is not null
    union all
    select 'empresa'::text, c.name, u.email::text, c.plan_until, c.seats,
      (select count(*) from public.profiles m where m.company_id = c.id), c.owner_id
      from public.companies c join auth.users u on u.id = c.owner_id
    order by 4 desc;
end $$;

create or replace function public.admin_end_plan(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  update public.profiles set plan = 'gratis', plan_until = null where id = target;
  update public.companies set plan_until = now() where owner_id = target;
end $$;

-- 8. Permisos de las funciones
revoke execute on function public.my_plan(), public.company_members(), public.company_add_member(text),
  public.company_remove_member(uuid), public.admin_list_requests(), public.admin_approve_request(uuid, int),
  public.admin_reject_request(uuid, text), public.admin_list_subscriptions(), public.admin_end_plan(uuid)
  from public, anon;
grant execute on function public.my_plan(), public.company_members(), public.company_add_member(text),
  public.company_remove_member(uuid), public.admin_list_requests(), public.admin_approve_request(uuid, int),
  public.admin_reject_request(uuid, text), public.admin_list_subscriptions(), public.admin_end_plan(uuid)
  to authenticated;

-- 9. Que el panel se actualice solo cuando llegan solicitudes
do $$ begin
  alter publication supabase_realtime add table public.plan_requests;
exception when duplicate_object then null; end $$;
