-- ============================================================
-- Alerta Tránsito · Meses, descuentos y registro financiero de suscripciones
-- Requiere haber ejecutado antes planes.sql
-- Pegar en Supabase > proyecto "Alerta Transito" > SQL Editor > Run (una sola vez)
-- ============================================================

-- 1. Descuentos por pagar varios meses y datos de la empresa para los recibos
alter table public.app_settings
  add column if not exists disc_3 int not null default 5 check (disc_3 between 0 and 90),
  add column if not exists disc_6 int not null default 10 check (disc_6 between 0 and 90),
  add column if not exists disc_12 int not null default 15 check (disc_12 between 0 and 90),
  add column if not exists biz_name text not null default 'Orion Nova Technologies',
  add column if not exists biz_nit text,
  add column if not exists biz_city text not null default 'Neiva, Huila';

-- 2. Cotización oficial (la calcula la base de datos para que nadie altere el precio)
create or replace function public.plan_quote(p_plan text, p_months int)
returns table (unit_price int, discount_pct int, amount int)
language sql stable security definer set search_path = '' as $$
  select
    case when p_plan = 'empresa' then s.empresa_price else s.plus_price end,
    case p_months when 3 then s.disc_3 when 6 then s.disc_6 when 12 then s.disc_12 else 0 end,
    round((case when p_plan = 'empresa' then s.empresa_price else s.plus_price end) * p_months
      * (100 - case p_months when 3 then s.disc_3 when 6 then s.disc_6 when 12 then s.disc_12 else 0 end) / 100.0)::int
  from public.app_settings s where s.id = 1
$$;

-- 3. La solicitud guarda los meses que el usuario eligió y el valor a pagar
alter table public.plan_requests
  add column if not exists months int not null default 1 check (months in (1, 3, 6, 12)),
  add column if not exists amount int;

create or replace function public.plan_requests_set_amount() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  select q.amount into new.amount from public.plan_quote(new.plan, new.months) q;
  return new;
end $$;
drop trigger if exists plan_requests_amount on public.plan_requests;
create trigger plan_requests_amount before insert on public.plan_requests
  for each row execute function public.plan_requests_set_amount();

update public.plan_requests r
set amount = (select q.amount from public.plan_quote(r.plan, r.months) q)
where r.amount is null;

-- 4. Libro de pagos (registro contable). Nunca se borra: los errores se ANULAN.
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  number bigint generated always as identity (start with 1001),
  request_id uuid references public.plan_requests(id) on delete set null,
  user_id uuid references auth.users(id) on delete set null,
  customer_name text not null,
  customer_email text,
  customer_doc text,
  plan text not null check (plan in ('plus','empresa','otro')),
  concept text not null,
  months int not null default 1 check (months between 1 and 24),
  unit_price int not null default 0 check (unit_price >= 0),
  discount_pct int not null default 0 check (discount_pct between 0 and 100),
  amount int not null check (amount >= 0),
  method text not null default 'Nequi',
  payment_ref text,
  paid_at timestamptz not null default now(),
  period_start timestamptz,
  period_end timestamptz,
  status text not null default 'valido' check (status in ('valido','anulado')),
  void_reason text,
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create unique index if not exists payments_number_idx on public.payments (number);
create index if not exists payments_paid_at_idx on public.payments (paid_at desc);
create index if not exists payments_user_idx on public.payments (user_id);
create index if not exists payments_request_idx on public.payments (request_id);
create index if not exists payments_created_by_idx on public.payments (created_by);
alter table public.payments enable row level security;
-- Solo las funciones del administrador escriben en el libro (así el consecutivo no salta números)
revoke insert, update, delete, truncate on public.payments from anon, authenticated;
drop policy if exists "admin ve pagos" on public.payments;
create policy "admin ve pagos" on public.payments for select to authenticated using ((select public.is_admin()));
drop policy if exists "veo mis pagos" on public.payments;
create policy "veo mis pagos" on public.payments for select to authenticated using (user_id = (select auth.uid()));

-- 5. Aprobar: activa el plan y registra el pago en el libro
create or replace function public.admin_approve_request(req uuid, months int) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.plan_requests; s public.app_settings; q record; cid uuid; base timestamptz; fin timestamptz;
  cname text; cmail text;
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  if months not between 1 and 24 then raise exception 'Meses inválidos'; end if;
  select * into r from public.plan_requests where id = req for update;
  if r.id is null then raise exception 'Solicitud no encontrada'; end if;
  if r.status <> 'pendiente' then raise exception 'Esta solicitud ya fue revisada'; end if;
  select * into s from public.app_settings where id = 1;
  select * into q from public.plan_quote(r.plan, months);
  if r.plan = 'plus' then
    select greatest(coalesce(p.plan_until, now()), now()) into base from public.profiles p where p.id = r.user_id;
    fin := base + make_interval(0, months);
    update public.profiles set plan = 'plus', plan_until = fin where id = r.user_id;
  else
    select c.id, greatest(c.plan_until, now()) into cid, base from public.companies c where c.owner_id = r.user_id;
    if cid is null then
      base := now();
      fin := base + make_interval(0, months);
      insert into public.companies (name, nit, owner_id, seats, plan_until)
      values (coalesce(nullif(trim(r.company_name), ''), 'Mi empresa'), r.nit, r.user_id, s.empresa_seats, fin)
      returning id into cid;
    else
      fin := base + make_interval(0, months);
      update public.companies set plan_until = fin where id = cid;
    end if;
    update public.profiles set company_id = cid where id = r.user_id;
  end if;
  update public.plan_requests set status = 'aprobada', reviewed_at = now() where id = req;

  select coalesce(nullif(p.full_name, ''), u.email::text), u.email::text into cname, cmail
  from public.profiles p join auth.users u on u.id = p.id where p.id = r.user_id;
  insert into public.payments (request_id, user_id, customer_name, customer_email, customer_doc, plan, concept, months,
    unit_price, discount_pct, amount, method, payment_ref, period_start, period_end)
  values (r.id, r.user_id,
    case when r.plan = 'empresa' then coalesce(nullif(trim(r.company_name), ''), cname) else cname end,
    cmail, r.nit, r.plan,
    'Suscripción Alerta Tránsito ' || case when r.plan = 'empresa' then 'Empresa' else 'Plus' end || ' · ' || months || case when months = 1 then ' mes' else ' meses' end,
    months, q.unit_price, q.discount_pct,
    case when months = r.months and r.amount is not null then r.amount else q.amount end,
    'Nequi / transferencia', r.payment_ref, base, fin);
end $$;

-- 6. Registrar un pago a mano (efectivo, pagos fuera de la app, otros ingresos)
create or replace function public.admin_add_payment(
  p_customer text, p_email text, p_doc text, p_plan text, p_concept text, p_months int,
  p_amount int, p_method text, p_ref text, p_paid_at timestamptz, p_notes text
) returns bigint
language plpgsql security definer set search_path = '' as $$
declare n bigint;
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  if coalesce(trim(p_customer), '') = '' then raise exception 'Escribe el nombre del cliente'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Valor inválido'; end if;
  insert into public.payments (customer_name, customer_email, customer_doc, plan, concept, months, unit_price, amount,
    method, payment_ref, paid_at, notes)
  values (trim(p_customer), nullif(trim(p_email), ''), nullif(trim(p_doc), ''), coalesce(p_plan, 'otro'),
    coalesce(nullif(trim(p_concept), ''), 'Ingreso Alerta Tránsito'), greatest(coalesce(p_months, 1), 1),
    round(p_amount::numeric / greatest(coalesce(p_months, 1), 1))::int, p_amount,
    coalesce(nullif(trim(p_method), ''), 'Efectivo'), nullif(trim(p_ref), ''), coalesce(p_paid_at, now()), nullif(trim(p_notes), ''))
  returning number into n;
  return n;
end $$;

-- 7. Anular un pago (queda en el libro marcado como anulado, con el motivo)
create or replace function public.admin_void_payment(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Escribe el motivo de la anulación'; end if;
  update public.payments set status = 'anulado', void_reason = left(trim(p_reason), 300)
  where id = p_id and status = 'valido';
end $$;

-- 8. La lista de solicitudes ahora incluye meses y valor
drop function if exists public.admin_list_requests();
create function public.admin_list_requests() returns table (
  id uuid, user_id uuid, email text, full_name text, plan text, company_name text, nit text,
  contact_phone text, payment_ref text, status text, created_at timestamptz, reviewed_at timestamptz,
  months int, amount int
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  return query
    select r.id, r.user_id, u.email::text, p.full_name, r.plan, r.company_name, r.nit,
      r.contact_phone, r.payment_ref, r.status, r.created_at, r.reviewed_at, r.months, r.amount
    from public.plan_requests r
    join auth.users u on u.id = r.user_id
    join public.profiles p on p.id = r.user_id
    order by (r.status = 'pendiente') desc, r.created_at desc
    limit 200;
end $$;

-- 9. Permisos
revoke execute on function public.plan_quote(text, int), public.admin_add_payment(text, text, text, text, text, int, int, text, text, timestamptz, text),
  public.admin_void_payment(uuid, text), public.admin_list_requests(), public.admin_approve_request(uuid, int),
  public.plan_requests_set_amount() from public, anon;
grant execute on function public.plan_quote(text, int), public.admin_add_payment(text, text, text, text, text, int, int, text, text, timestamptz, text),
  public.admin_void_payment(uuid, text), public.admin_list_requests(), public.admin_approve_request(uuid, int)
  to authenticated;
revoke execute on function public.plan_requests_set_amount() from authenticated;
