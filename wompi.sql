-- =====================================================================
-- Alerta Tránsito · Pago de planes con el link de Wompi (Nequi, PSE, tarjetas, Bancolombia)
-- Igual que en NOVA COURSE: la base de datos le pregunta a Wompi si el pago está APROBADO,
-- si entró por tu link y si el valor alcanza. Si todo cuadra, el plan se activa solo
-- y el pago queda registrado en Finanzas. Si no se puede confirmar que sea de tu link,
-- queda como solicitud pendiente para que la apruebes en Admin > Planes.
-- Requiere haber ejecutado antes planes.sql y finanzas.sql.
-- Pégalo en Supabase > SQL Editor y pulsa "Run". Se puede ejecutar varias veces.
-- =====================================================================

-- Extensión para que la base de datos pueda consultar la API de Wompi
create extension if not exists http with schema extensions;

begin;

-- ---------- Configuración del link de Wompi (editable desde Admin > Planes) ----------
alter table public.app_settings
  add column if not exists wompi_link_url text not null default 'https://checkout.wompi.co/l/4CnTOr',
  add column if not exists wompi_link_id text not null default '4CnTOr',
  add column if not exists wompi_api_url text not null default 'https://production.wompi.co/v1';

-- ---------- Cada transacción de Wompi solo se puede usar una vez ----------
alter table public.payments add column if not exists provider_tx_id text;
create unique index if not exists payments_provider_tx_unique on public.payments (provider_tx_id) where provider_tx_id is not null;
alter table public.plan_requests add column if not exists wompi_tx text;
create unique index if not exists plan_requests_wompi_tx_unique on public.plan_requests (wompi_tx) where wompi_tx is not null;

-- ---------- Consecutivo de pagos sin saltos (contabilidad) ----------
-- Se asigna al guardar, con bloqueo, para que nunca se salten números aunque algo falle.
alter table public.payments alter column number drop identity if exists;
create or replace function public.payments_set_number() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtext('alerta_payments_number'));
  new.number := coalesce((select max(p.number) from public.payments p), 1000) + 1;
  return new;
end $$;
revoke all on function public.payments_set_number() from public, anon, authenticated;
drop trigger if exists payments_number on public.payments;
create trigger payments_number before insert on public.payments
  for each row execute function public.payments_set_number();

-- ---------- Activación interna de un plan (la usan el admin y el pago automático) ----------
create or replace function public.activate_plan_request(req uuid, p_months int, p_method text, p_amount int, p_tx text)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare r public.plan_requests; s public.app_settings; q record; cid uuid; base timestamptz; fin timestamptz;
  cname text; cmail text; n bigint;
begin
  if p_months not between 1 and 24 then raise exception 'Meses inválidos'; end if;
  select * into r from public.plan_requests where id = req for update;
  if r.id is null then raise exception 'Solicitud no encontrada'; end if;
  if r.status <> 'pendiente' then raise exception 'Esta solicitud ya fue revisada'; end if;
  select * into s from public.app_settings where id = 1;
  select * into q from public.plan_quote(r.plan, p_months);
  if r.plan = 'plus' then
    select greatest(coalesce(p.plan_until, now()), now()) into base from public.profiles p where p.id = r.user_id;
    fin := base + make_interval(0, p_months);
    update public.profiles set plan = 'plus', plan_until = fin where id = r.user_id;
  else
    select c.id, greatest(c.plan_until, now()) into cid, base from public.companies c where c.owner_id = r.user_id;
    if cid is null then
      base := now();
      fin := base + make_interval(0, p_months);
      insert into public.companies (name, nit, owner_id, seats, plan_until)
      values (coalesce(nullif(trim(r.company_name), ''), 'Mi empresa'), r.nit, r.user_id, s.empresa_seats, fin)
      returning id into cid;
    else
      fin := base + make_interval(0, p_months);
      update public.companies set plan_until = fin where id = cid;
    end if;
    update public.profiles set company_id = cid where id = r.user_id;
  end if;
  update public.plan_requests set status = 'aprobada', reviewed_at = now() where id = req;

  select coalesce(nullif(p.full_name, ''), u.email::text), u.email::text into cname, cmail
  from public.profiles p join auth.users u on u.id = p.id where p.id = r.user_id;
  insert into public.payments (request_id, user_id, customer_name, customer_email, customer_doc, plan, concept, months,
    unit_price, discount_pct, amount, method, payment_ref, period_start, period_end, provider_tx_id)
  values (r.id, r.user_id,
    case when r.plan = 'empresa' then coalesce(nullif(trim(r.company_name), ''), cname) else cname end,
    cmail, r.nit, r.plan,
    'Suscripción Alerta Tránsito ' || case when r.plan = 'empresa' then 'Empresa' else 'Plus' end || ' · ' || p_months || case when p_months = 1 then ' mes' else ' meses' end,
    p_months, q.unit_price, q.discount_pct,
    coalesce(p_amount, case when p_months = r.months and r.amount is not null then r.amount else q.amount end),
    coalesce(p_method, 'Nequi / transferencia'), coalesce(p_tx, r.payment_ref), base, fin, p_tx)
  returning number into n;
  return n;
end $$;
revoke all on function public.activate_plan_request(uuid, int, text, int, text) from public, anon, authenticated;

-- El administrador sigue aprobando a mano los pagos por Nequi/transferencia (y los de Wompi en revisión)
create or replace function public.admin_approve_request(req uuid, months int) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.plan_requests;
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  select * into r from public.plan_requests where id = req;
  perform public.activate_plan_request(req, months,
    case when r.wompi_tx is not null then 'Wompi' else 'Nequi / transferencia' end, null, r.wompi_tx);
end $$;

-- ---------- El usuario confirma su pago de Wompi con el número de la transacción ----------
create or replace function public.claim_wompi_plan(p_plan text, p_months int, p_tx_id text,
  p_company text default null, p_nit text default null, p_phone text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_tx text := trim(coalesce(p_tx_id, ''));
  v_set public.app_settings;
  v_q record;
  v_resp extensions.http_response;
  v_data jsonb;
  v_status text;
  v_paid bigint;
  v_method text;
  v_ok_link boolean;
  v_req uuid;
  v_prev public.plan_requests;
  v_num bigint;
begin
  if v_uid is null then raise exception 'Inicia sesión para confirmar tu pago'; end if;
  if (select blocked from public.profiles where id = v_uid) then raise exception 'Tu cuenta está bloqueada. Escríbele al administrador.'; end if;
  if p_plan not in ('plus', 'empresa') then raise exception 'Plan inválido'; end if;
  if p_months not in (1, 3, 6, 12) then raise exception 'Meses inválidos'; end if;
  if p_plan = 'empresa' and coalesce(trim(p_company), '') = '' then raise exception 'Escribe el nombre de la empresa'; end if;
  if v_tx !~ '^[A-Za-z0-9_-]{5,80}$' then
    raise exception 'Ese número de transacción no es válido. Cópialo tal como aparece en el comprobante de Wompi.';
  end if;

  -- Un mismo pago no se puede usar dos veces
  select * into v_prev from public.plan_requests where wompi_tx = v_tx;
  if v_prev.id is not null then
    if v_prev.user_id = v_uid then
      return jsonb_build_object('status', case when v_prev.status = 'aprobada' then 'approved' else 'review' end,
        'message', case when v_prev.status = 'aprobada' then 'Ese pago ya está registrado y tu plan está activo.' else 'Ese pago ya está registrado y lo estamos revisando.' end);
    end if;
    raise exception 'Ese pago ya fue usado por otra cuenta.';
  end if;
  if exists (select 1 from public.payments where provider_tx_id = v_tx) then raise exception 'Ese pago ya fue usado.'; end if;

  select * into v_set from public.app_settings where id = 1;
  select * into v_q from public.plan_quote(p_plan, p_months);

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '15');
  select * into v_resp from extensions.http_get(v_set.wompi_api_url || '/transactions/' || v_tx);
  if v_resp.status = 404 then raise exception 'No encontramos esa transacción en Wompi. Revisa el número.'; end if;
  if v_resp.status <> 200 then raise exception 'Wompi no respondió. Intenta de nuevo en un momento.'; end if;

  v_data := (v_resp.content::jsonb) -> 'data';
  v_status := v_data ->> 'status';
  v_paid := coalesce((v_data ->> 'amount_in_cents')::bigint, 0);
  v_method := 'Wompi · ' || coalesce(v_data ->> 'payment_method_type', 'pago');

  if v_status = 'PENDING' then raise exception 'Wompi todavía está procesando tu pago. Espera un minuto y vuelve a intentarlo.'; end if;
  if v_status <> 'APPROVED' then raise exception 'Wompi reporta este pago como % (no aprobado).', v_status; end if;
  if coalesce(v_data ->> 'currency', 'COP') <> 'COP' or v_paid < v_q.amount::bigint * 100 then
    raise exception 'El valor pagado ($%) es menor que el valor del plan ($%).',
      replace(to_char(v_paid / 100, 'FM999,999,999'), ',', '.'), replace(to_char(v_q.amount, 'FM999,999,999'), ',', '.');
  end if;

  v_ok_link := (v_data ->> 'payment_link_id') = v_set.wompi_link_id;

  insert into public.plan_requests (user_id, plan, months, company_name, nit, contact_phone, payment_ref, wompi_tx)
  values (v_uid, p_plan, p_months, nullif(trim(p_company), ''), nullif(trim(p_nit), ''), nullif(trim(p_phone), ''),
          'Wompi ' || v_tx, v_tx)
  returning id into v_req;

  if v_ok_link then
    v_num := public.activate_plan_request(v_req, p_months, v_method, (v_paid / 100)::int, v_tx);
    return jsonb_build_object('status', 'approved', 'number', v_num,
      'message', '¡Pago confirmado con Wompi! Tu plan ' || case when p_plan = 'empresa' then 'Empresa' else 'Plus' end || ' ya está activo.');
  end if;
  return jsonb_build_object('status', 'review', 'request_id', v_req,
    'message', 'Recibimos tu pago. Lo revisamos y activamos tu plan en breve.');
end $$;
revoke all on function public.claim_wompi_plan(text, int, text, text, text, text) from public, anon;
grant execute on function public.claim_wompi_plan(text, int, text, text, text, text) to authenticated;

-- La lista de solicitudes del admin muestra si el pago fue con Wompi
drop function if exists public.admin_list_requests();
create function public.admin_list_requests() returns table (
  id uuid, user_id uuid, email text, full_name text, plan text, company_name text, nit text,
  contact_phone text, payment_ref text, status text, created_at timestamptz, reviewed_at timestamptz,
  months int, amount int, wompi_tx text
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Solo para administradores'; end if;
  return query
    select r.id, r.user_id, u.email::text, p.full_name, r.plan, r.company_name, r.nit,
      r.contact_phone, r.payment_ref, r.status, r.created_at, r.reviewed_at, r.months, r.amount, r.wompi_tx
    from public.plan_requests r
    join auth.users u on u.id = r.user_id
    join public.profiles p on p.id = r.user_id
    order by (r.status = 'pendiente') desc, r.created_at desc
    limit 200;
end $$;
revoke all on function public.admin_list_requests() from public, anon;
grant execute on function public.admin_list_requests() to authenticated;

-- Los usuarios no pueden crear solicitudes marcadas como Wompi a mano (solo por claim_wompi_plan)
drop policy if exists "crear solicitud" on public.plan_requests;
create policy "crear solicitud" on public.plan_requests for insert to authenticated
  with check (user_id = (select auth.uid()) and status = 'pendiente' and admin_note is null
    and reviewed_at is null and wompi_tx is null);

commit;

-- Comprobación: debe mostrar tu link de Wompi
select wompi_link_url as link_de_pago from public.app_settings where id = 1;
