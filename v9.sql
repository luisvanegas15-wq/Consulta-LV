-- =====================================================
-- CONSULTA LV · Actualización v9: suscripciones y panel de administración (LV Studio)
-- Prueba gratis de 14 días, solicitudes de renovación, aprobación por el administrador,
-- avisos de vencimiento por correo y bloqueo de nuevas citas con la suscripción vencida.
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;
create table if not exists privado.config (clave text primary key, valor text not null);
revoke all on privado.config from public, anon, authenticated;

-- ---------- ADMINISTRADORES ----------
create table if not exists privado.admins (user_id uuid primary key references auth.users(id) on delete cascade);
revoke all on privado.admins from public, anon, authenticated;
alter table privado.admins enable row level security;

create or replace function privado.hacer_admin(p_email text) returns text
language plpgsql security definer set search_path = public, privado, auth as $$
declare v uuid;
begin
  select id into v from auth.users where lower(email) = lower(btrim(p_email));
  if v is null then return 'No existe una cuenta con el correo ' || p_email || '. Crea la cuenta en la app y vuelve a ejecutar.'; end if;
  insert into privado.admins values (v) on conflict do nothing;
  insert into privado.config values ('admin_email', lower(btrim(p_email))) on conflict (clave) do update set valor = excluded.valor;
  return 'Administrador listo ✅';
end $$;
revoke all on function privado.hacer_admin(text) from public, anon, authenticated;

create or replace function public.soy_admin() returns boolean
language sql stable security definer set search_path = public, privado as $$
  select exists (select 1 from privado.admins a where a.user_id = auth.uid());
$$;
revoke execute on function public.soy_admin() from public, anon;
grant execute on function public.soy_admin() to authenticated;

create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public, privado as $$
  select public.soy_admin() and public.mfa_ok();
$$;
revoke execute on function public.es_admin() from public, anon;
grant execute on function public.es_admin() to authenticated;

-- El profesional no puede cambiarse la fecha de suscripción; el administrador sí (desde sus funciones)
create or replace function public.proteger_profesional() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(auth.role(), '') in ('authenticated', 'anon') then
    if not public.soy_admin() then new.activo_hasta := old.activo_hasta; end if;
    new.id := old.id;
    new.email := old.email;
  end if;
  new.slug := nullif(lower(btrim(coalesce(new.slug, ''))), '');
  return new;
end $$;

-- ---------- PLANES ----------
create or replace function public.planes() returns json language sql immutable as $$
  select '[{"id":"mensual","nombre":"Mensual","meses":1,"valor":39000},
           {"id":"semestral","nombre":"Semestral","meses":6,"valor":199000},
           {"id":"anual","nombre":"Anual","meses":12,"valor":349000}]'::json;
$$;
grant execute on function public.planes() to anon, authenticated;

-- ---------- SOLICITUDES DE RENOVACIÓN ----------
create table if not exists public.renovaciones (
  id uuid primary key default gen_random_uuid(),
  profesional_id uuid not null default auth.uid() references public.profesionales(id) on delete cascade,
  plan text not null check (plan in ('mensual', 'semestral', 'anual')),
  valor int not null default 0,
  referencia text not null default '' check (char_length(referencia) <= 80),
  estado text not null default 'pendiente' check (estado in ('pendiente', 'aprobada', 'rechazada')),
  nota text not null default '' check (char_length(nota) <= 200),
  hasta date,
  created_at timestamptz not null default now(),
  resuelta_at timestamptz
);
create unique index if not exists una_pendiente on public.renovaciones (profesional_id) where estado = 'pendiente';
alter table public.renovaciones enable row level security;
grant select, insert on public.renovaciones to authenticated;

drop policy if exists ren_ver on public.renovaciones;
create policy ren_ver on public.renovaciones for select to authenticated using (profesional_id = auth.uid());
drop policy if exists ren_crear on public.renovaciones;
create policy ren_crear on public.renovaciones for insert to authenticated
  with check (profesional_id = auth.uid() and estado = 'pendiente' and resuelta_at is null and hasta is null and nota = '');

-- El valor siempre sale del plan, nunca de lo que envíe la app
create or replace function public.valor_renovacion() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    select (x ->> 'valor')::int into new.valor from json_array_elements(public.planes()) x where x ->> 'id' = new.plan;
    new.referencia := btrim(new.referencia);
  end if;
  return new;
end $$;
drop trigger if exists trg_valor_ren on public.renovaciones;
create trigger trg_valor_ren before insert on public.renovaciones for each row execute function public.valor_renovacion();

-- ---------- CORREOS (Brevo, configurado en v4) ----------
create or replace function privado.correo(p_para text, p_asunto text, p_html text) returns boolean
language plpgsql security definer set search_path = public, privado, extensions as $$
declare v_key text; v_from text; v_nom text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'brevo_api_key';
  select valor into v_from from privado.config where clave = 'remitente_email';
  select valor into v_nom from privado.config where clave = 'remitente_nombre';
  if v_key is null or v_from is null or coalesce(p_para, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return false; end if;
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', v_key, 'Content-Type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object('sender', jsonb_build_object('email', v_from, 'name', coalesce(v_nom, 'Consulta LV')),
      'to', jsonb_build_array(jsonb_build_object('email', p_para)), 'subject', p_asunto,
      'htmlContent', '<div style="font-family:Arial,sans-serif;max-width:520px;margin:auto;color:#0f172a;font-size:15px;line-height:1.6">' || p_html
        || '<p style="font-size:12px;color:#64748b;border-top:1px solid #e2e8f0;padding-top:10px;margin-top:18px">Consulta LV · LV Studio</p></div>',
      'tags', jsonb_build_array('suscripcion')));
  return true;
end $$;
revoke all on function privado.correo(text, text, text) from public, anon, authenticated;

-- Avisa al administrador cuando llega una solicitud de renovación
create or replace function privado.avisar_solicitud() returns trigger
language plpgsql security definer set search_path = public, privado as $$
declare v_admin text; p record;
begin
  select valor into v_admin from privado.config where clave = 'admin_email';
  select nombre, email into p from public.profesionales where id = new.profesional_id;
  perform privado.correo(v_admin, '💳 Nueva renovación: ' || coalesce(nullif(p.nombre, ''), p.email),
    '<p><b>' || privado.html(coalesce(nullif(p.nombre, ''), 'Sin nombre')) || '</b> (' || privado.html(p.email) || ') informó un pago.</p>'
    || '<p>Plan: <b>' || new.plan || '</b> · Valor: <b>$' || replace(to_char(new.valor, 'FM999,999,999'), ',', '.') || '</b><br>Referencia: '
    || privado.html(coalesce(nullif(new.referencia, ''), '(sin referencia)')) || '</p><p>Revisa el pago y apruébalo en Consulta LV → Más → Administración.</p>');
  return new;
end $$;
drop trigger if exists trg_avisar_ren on public.renovaciones;
create trigger trg_avisar_ren after insert on public.renovaciones for each row execute function privado.avisar_solicitud();

-- ---------- FUNCIONES DEL ADMINISTRADOR (exigen ser administrador y haber pasado la verificación en dos pasos) ----------
create or replace function public.admin_resumen() returns json
language plpgsql stable security definer set search_path = public, privado as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  return json_build_object(
    'profesionales', coalesce((select json_agg(x order by x.pendiente desc, x.activo_hasta) from (
      select p.id, p.nombre, p.email, p.slug, p.ciudad, p.whatsapp, p.activo_hasta, p.created_at,
             (select count(*) from public.renovaciones r where r.profesional_id = p.id and r.estado = 'aprobada') pagos,
             (select count(*) from public.pacientes pa where pa.profesional_id = p.id) pacientes,
             (select count(*) from public.citas c where c.profesional_id = p.id and c.inicio > now() - interval '30 days') citas_mes,
             exists (select 1 from public.renovaciones r where r.profesional_id = p.id and r.estado = 'pendiente') pendiente
      from public.profesionales p) x), '[]'::json),
    'pendientes', coalesce((select json_agg(json_build_object('id', r.id, 'plan', r.plan, 'valor', r.valor, 'referencia', r.referencia,
        'created_at', r.created_at, 'nombre', p.nombre, 'email', p.email, 'whatsapp', p.whatsapp, 'activo_hasta', p.activo_hasta) order by r.created_at)
      from public.renovaciones r join public.profesionales p on p.id = r.profesional_id where r.estado = 'pendiente'), '[]'::json),
    'ingresos_mes', (select coalesce(sum(valor), 0) from public.renovaciones where estado = 'aprobada'
      and resuelta_at >= date_trunc('month', now() at time zone 'America/Bogota') at time zone 'America/Bogota'),
    'ingresos_total', (select coalesce(sum(valor), 0) from public.renovaciones where estado = 'aprobada'));
end $$;

create or replace function public.admin_resolver(p_id uuid, p_aprobar boolean, p_nota text default '') returns date
language plpgsql security definer set search_path = public, privado as $$
declare r record; v_meses int; v_hasta date; v_email text;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  select * into r from public.renovaciones where id = p_id and estado = 'pendiente' for update;
  if r.id is null then raise exception 'La solicitud ya fue resuelta'; end if;
  select email into v_email from public.profesionales where id = r.profesional_id;
  if p_aprobar then
    select (x ->> 'meses')::int into v_meses from json_array_elements(public.planes()) x where x ->> 'id' = r.plan;
    update public.profesionales set activo_hasta = (greatest(activo_hasta, current_date) + make_interval(months => v_meses))::date
      where id = r.profesional_id returning activo_hasta into v_hasta;
    update public.renovaciones set estado = 'aprobada', hasta = v_hasta, resuelta_at = now(), nota = left(coalesce(p_nota, ''), 200) where id = p_id;
    perform privado.correo(v_email, '✅ Tu suscripción a Consulta LV está activa',
      '<p>¡Gracias por tu pago! Tu plan <b>' || r.plan || '</b> quedó activo hasta el <b>' || to_char(v_hasta, 'DD/MM/YYYY') || '</b>.</p><p>Tu página de reservas sigue visible para tus pacientes.</p>');
  else
    update public.renovaciones set estado = 'rechazada', resuelta_at = now(), nota = left(coalesce(p_nota, ''), 200) where id = p_id;
    perform privado.correo(v_email, 'Revisemos tu pago de Consulta LV',
      '<p>No pudimos confirmar tu pago del plan <b>' || r.plan || '</b>.' || case when coalesce(p_nota, '') <> '' then '<br>Motivo: ' || privado.html(p_nota) else '' end
      || '</p><p>Escríbenos por WhatsApp al 320 290 3722 con tu comprobante y lo resolvemos.</p>');
  end if;
  return v_hasta;
end $$;

create or replace function public.admin_extender(p_prof uuid, p_dias int) returns date
language plpgsql security definer set search_path = public, privado as $$
declare v date;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  if p_dias is null or p_dias = 0 or abs(p_dias) > 400 then raise exception 'Días no válidos'; end if;
  update public.profesionales set activo_hasta = (case when p_dias > 0 then greatest(activo_hasta, current_date) else activo_hasta end + p_dias)
    where id = p_prof returning activo_hasta into v;
  if v is null then raise exception 'Profesional no encontrado'; end if;
  return v;
end $$;

revoke execute on function public.admin_resumen() from public, anon;
revoke execute on function public.admin_resolver(uuid, boolean, text) from public, anon;
revoke execute on function public.admin_extender(uuid, int) from public, anon;
grant execute on function public.admin_resumen() to authenticated;
grant execute on function public.admin_resolver(uuid, boolean, text) to authenticated;
grant execute on function public.admin_extender(uuid, int) to authenticated;

-- ---------- CON LA SUSCRIPCIÓN VENCIDA: se puede consultar y exportar todo, pero no crear pacientes ni citas ----------
create or replace function public.licencia_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profesionales where id = auth.uid() and activo_hasta >= current_date);
$$;
revoke execute on function public.licencia_ok() from public, anon;
grant execute on function public.licencia_ok() to authenticated;
drop policy if exists licencia_pacientes on public.pacientes;
create policy licencia_pacientes on public.pacientes as restrictive for insert to authenticated with check (public.licencia_ok());
drop policy if exists licencia_citas on public.citas;
create policy licencia_citas on public.citas as restrictive for insert to authenticated with check (public.licencia_ok());

-- ---------- AVISOS DE VENCIMIENTO (todos los días 9 a. m. Colombia) ----------
alter table public.profesionales add column if not exists aviso_venc date;
create or replace function privado.avisar_vencimientos() returns int
language plpgsql security definer set search_path = public, privado as $$
declare p record; n int := 0; d int; v_url text := 'https://luisvanegas15-wq.github.io/Consulta-LV/';
begin
  for p in select id, nombre, email, activo_hasta from public.profesionales
           where activo_hasta - current_date in (3, 0, -1) and aviso_venc is distinct from current_date loop
    d := p.activo_hasta - current_date;
    perform privado.correo(p.email,
      case when d = 3 then '⏳ Tu suscripción a Consulta LV vence en 3 días' when d = 0 then '⚠️ Tu suscripción a Consulta LV vence hoy' else 'Tu suscripción a Consulta LV venció' end,
      '<p>Hola ' || privado.html(coalesce(nullif(split_part(btrim(p.nombre), ' ', 1), ''), '')) || ',</p><p>'
      || case when d = 3 then 'Tu suscripción vence el <b>' || to_char(p.activo_hasta, 'DD/MM/YYYY') || '</b>. Renueva a tiempo para que tu página de reservas siga visible.'
              when d = 0 then 'Tu suscripción vence <b>hoy</b>. Desde mañana tu página de reservas quedará oculta.'
              else 'Tu suscripción venció. Tu página de reservas está oculta y no puedes crear citas nuevas. <b>Tus datos siguen guardados y seguros</b>: puedes consultarlos y exportarlos.' end
      || '</p><p><a href="' || v_url || '" style="background:#0e7490;color:#fff;padding:11px 16px;border-radius:10px;text-decoration:none;font-weight:bold">Renovar en Consulta LV</a></p>'
      || '<p>Entra a Más → Mi suscripción.</p>');
    update public.profesionales set aviso_venc = current_date where id = p.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function privado.avisar_vencimientos() from public, anon, authenticated;
select cron.schedule('vencimientos-consulta-lv', '0 14 * * *', 'select privado.avisar_vencimientos()');

-- ---------- TU CUENTA DE ADMINISTRADOR (cambia el correo si entras con otro) ----------
select privado.hacer_admin('luisvanegas15@gmail.com');
