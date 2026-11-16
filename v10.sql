-- =====================================================
-- CONSULTA LV · Actualización v10
-- 1) Verificación en dos pasos con código al correo (sin apps)
-- 2) Consentimiento y pruebas que el paciente llena en línea (cifrados para el profesional)
-- 3) Videollamada automática para citas virtuales
-- 4) El paciente confirma, cancela o reprograma desde el correo
-- 5) Correo de confirmación al reservar y aviso al profesional
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;

-- ---------- COLUMNAS NUEVAS ----------
alter table public.profesionales add column if not exists mfa_correo boolean not null default false;
alter table public.profesionales add column if not exists clave_publica jsonb;
alter table public.profesionales add column if not exists clave_privada_cifrada text;
alter table public.profesionales add column if not exists clave_privada_iv text;
alter table public.citas add column if not exists token_paciente uuid not null default gen_random_uuid();
alter table public.citas add column if not exists confirmada_paciente_at timestamptz;
alter table public.citas add column if not exists cambio_paciente text not null default '';
create unique index if not exists citas_token_paciente on public.citas (token_paciente);

-- La verificación por correo solo se cambia desde sus funciones
create or replace function public.proteger_profesional() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(auth.role(), '') in ('authenticated', 'anon') then
    if not public.soy_admin() then new.activo_hasta := old.activo_hasta; end if;
    if coalesce(current_setting('lv.cambio_mfa', true), '') <> '1' then new.mfa_correo := old.mfa_correo; end if;
    new.id := old.id;
    new.email := old.email;
  end if;
  new.slug := nullif(lower(btrim(coalesce(new.slug, ''))), '');
  return new;
end $$;

-- ---------- 1) VERIFICACIÓN EN DOS PASOS POR CORREO ----------
create table if not exists privado.codigos (
  user_id uuid primary key, hash text not null, expira timestamptz not null,
  intentos int not null default 0, enviados int not null default 1, ventana timestamptz not null default now(), ultimo timestamptz not null default now());
create table if not exists privado.sesiones_ok (session_id uuid primary key, user_id uuid not null, verificada_at timestamptz not null default now());
revoke all on privado.codigos, privado.sesiones_ok from public, anon, authenticated;

create or replace function public.mfa_ok() returns boolean
language sql stable security definer set search_path = public, auth, privado as $$
  select case
    when exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified')
      then coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
    when coalesce((select p.mfa_correo from public.profesionales p where p.id = auth.uid()), false)
      then exists (select 1 from privado.sesiones_ok s where s.user_id = auth.uid()
                    and s.session_id::text = coalesce(auth.jwt() ->> 'session_id', '-'))
    else true end;
$$;
revoke execute on function public.mfa_ok() from public, anon;
grant execute on function public.mfa_ok() to authenticated;

create or replace function public.estado_2fa() returns json
language sql stable security definer set search_path = public, auth as $$
  select json_build_object(
    'metodo', case when exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified') then 'app'
                   when p.mfa_correo then 'correo' end,
    'ok', public.mfa_ok(),
    'correo', regexp_replace(coalesce(p.email, ''), '^(.{2})[^@]*', '\1•••'))
  from public.profesionales p where p.id = auth.uid();
$$;

create or replace function public.enviar_codigo_2fa() returns text
language plpgsql security definer set search_path = public, privado as $$
declare v_uid uuid := auth.uid(); v_email text; v_cod text; c record;
begin
  if v_uid is null then raise exception 'No autorizado'; end if;
  select email into v_email from public.profesionales where id = v_uid;
  select * into c from privado.codigos where user_id = v_uid;
  if c.user_id is not null then
    if c.ultimo > now() - interval '45 seconds' then raise exception 'Espera un momento antes de pedir otro código'; end if;
    if c.ventana > now() - interval '30 minutes' and c.enviados >= 5 then raise exception 'Demasiados códigos. Intenta en 30 minutos'; end if;
  end if;
  v_cod := lpad((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint % 1000000)::text, 6, '0');
  insert into privado.codigos (user_id, hash, expira, intentos, enviados, ventana, ultimo)
  values (v_uid, encode(sha256(convert_to(v_cod || v_uid::text, 'UTF8')), 'hex'), now() + interval '10 minutes', 0, 1, now(), now())
  on conflict (user_id) do update set hash = excluded.hash, expira = excluded.expira, intentos = 0, ultimo = now(),
    enviados = case when privado.codigos.ventana > now() - interval '30 minutes' then privado.codigos.enviados + 1 else 1 end,
    ventana = case when privado.codigos.ventana > now() - interval '30 minutes' then privado.codigos.ventana else now() end;
  if not privado.correo(v_email, v_cod || ' es tu código de Consulta LV',
      '<p>Tu código para entrar a Consulta LV es:</p><p style="font-size:34px;font-weight:bold;letter-spacing:8px;margin:10px 0">' || v_cod || '</p>'
      || '<p>Vence en 10 minutos. Si no fuiste tú quien intentó entrar, cambia tu contraseña de inmediato.</p>') then
    raise exception 'No se pudo enviar el correo. Intenta de nuevo';
  end if;
  return regexp_replace(v_email, '^(.{2})[^@]*', '\1•••');
end $$;

create or replace function privado.validar_codigo(p_codigo text) returns boolean
language plpgsql security definer set search_path = public, privado as $$
declare v_uid uuid := auth.uid(); c record; v_sid text := auth.jwt() ->> 'session_id';
begin
  select * into c from privado.codigos where user_id = v_uid for update;
  if c.user_id is null or c.expira < now() then raise exception 'El código venció. Pide uno nuevo'; end if;
  if c.intentos >= 5 then delete from privado.codigos where user_id = v_uid; raise exception 'Demasiados intentos. Pide un código nuevo'; end if;
  if c.hash <> encode(sha256(convert_to(regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g') || v_uid::text, 'UTF8')), 'hex') then
    update privado.codigos set intentos = intentos + 1 where user_id = v_uid;
    return false;
  end if;
  delete from privado.codigos where user_id = v_uid;
  if v_sid is not null then
    insert into privado.sesiones_ok (session_id, user_id) values (v_sid::uuid, v_uid) on conflict (session_id) do update set verificada_at = now();
  end if;
  return true;
end $$;
revoke all on function privado.validar_codigo(text) from public, anon, authenticated;

create or replace function public.verificar_codigo_2fa(p_codigo text) returns boolean
language plpgsql security definer set search_path = public, privado as $$
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  return privado.validar_codigo(p_codigo);
end $$;

create or replace function public.activar_2fa_correo(p_codigo text) returns boolean
language plpgsql security definer set search_path = public, privado as $$
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  if not privado.validar_codigo(p_codigo) then return false; end if;
  perform set_config('lv.cambio_mfa', '1', true);
  update public.profesionales set mfa_correo = true where id = auth.uid();
  return true;
end $$;

create or replace function public.desactivar_2fa_correo() returns boolean
language plpgsql security definer set search_path = public, privado as $$
begin
  if auth.uid() is null or not public.mfa_ok() then raise exception 'No autorizado'; end if;
  perform set_config('lv.cambio_mfa', '1', true);
  update public.profesionales set mfa_correo = false where id = auth.uid();
  return true;
end $$;

revoke execute on function public.estado_2fa() from public, anon;
revoke execute on function public.enviar_codigo_2fa() from public, anon;
revoke execute on function public.verificar_codigo_2fa(text) from public, anon;
revoke execute on function public.activar_2fa_correo(text) from public, anon;
revoke execute on function public.desactivar_2fa_correo() from public, anon;
grant execute on function public.estado_2fa() to authenticated;
grant execute on function public.enviar_codigo_2fa() to authenticated;
grant execute on function public.verificar_codigo_2fa(text) to authenticated;
grant execute on function public.activar_2fa_correo(text) to authenticated;
grant execute on function public.desactivar_2fa_correo() to authenticated;

-- ---------- 2) FORMULARIOS QUE LLENA EL PACIENTE (consentimiento y pruebas) ----------
-- La respuesta se cifra en el celular del paciente con la llave pública del profesional:
-- solo el profesional (con su clave clínica) puede abrirla.
create table if not exists public.formularios (
  id uuid primary key default gen_random_uuid(),
  token uuid not null unique default gen_random_uuid(),
  profesional_id uuid not null default auth.uid() references public.profesionales(id) on delete cascade,
  paciente_id uuid not null references public.pacientes(id) on delete cascade,
  tipo text not null check (tipo in ('consentimiento', 'prueba')),
  prueba text not null default '' check (prueba in ('', 'PHQ-9', 'GAD-7', 'PCL-5', 'AUDIT')),
  estado text not null default 'enviado' check (estado in ('enviado', 'respondido', 'importado')),
  respuesta_cifrada text, epk jsonb, iv text,
  expira timestamptz not null default now() + interval '14 days',
  respondido_at timestamptz,
  created_at timestamptz not null default now(),
  check (tipo <> 'prueba' or prueba <> '')
);
alter table public.formularios enable row level security;
grant select, insert, update, delete on public.formularios to authenticated;
drop policy if exists form_ver on public.formularios;
create policy form_ver on public.formularios for select to authenticated using (profesional_id = auth.uid());
drop policy if exists form_crear on public.formularios;
create policy form_crear on public.formularios for insert to authenticated with check (
  profesional_id = auth.uid() and estado = 'enviado' and respuesta_cifrada is null
  and exists (select 1 from public.pacientes pa where pa.id = paciente_id and pa.profesional_id = auth.uid()));
drop policy if exists form_editar on public.formularios;
create policy form_editar on public.formularios for update to authenticated using (profesional_id = auth.uid()) with check (profesional_id = auth.uid());
drop policy if exists form_borrar on public.formularios;
create policy form_borrar on public.formularios for delete to authenticated using (profesional_id = auth.uid());
drop policy if exists mfa_exigido on public.formularios;
create policy mfa_exigido on public.formularios as restrictive for all to authenticated using (public.mfa_ok()) with check (public.mfa_ok());

-- Documentos firmados por el paciente (cifrados con la clave del profesional)
create table if not exists public.documentos (
  id uuid primary key default gen_random_uuid(),
  profesional_id uuid not null default auth.uid() references public.profesionales(id) on delete restrict,
  paciente_id uuid not null references public.pacientes(id) on delete restrict,
  tipo text not null default 'consentimiento' check (tipo in ('consentimiento')),
  contenido_cifrado text not null, iv text not null,
  created_at timestamptz not null default now()
);
alter table public.documentos enable row level security;
grant select, insert on public.documentos to authenticated;
drop policy if exists doc_ver on public.documentos;
create policy doc_ver on public.documentos for select to authenticated using (profesional_id = auth.uid());
drop policy if exists doc_crear on public.documentos;
create policy doc_crear on public.documentos for insert to authenticated with check (
  profesional_id = auth.uid() and exists (select 1 from public.pacientes pa where pa.id = paciente_id and pa.profesional_id = auth.uid()));
drop policy if exists mfa_exigido on public.documentos;
create policy mfa_exigido on public.documentos as restrictive for all to authenticated using (public.mfa_ok()) with check (public.mfa_ok());

create or replace function public.formulario_info(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('tipo', f.tipo, 'prueba', f.prueba, 'estado', f.estado, 'vencido', f.expira < now(),
    'profesional', p.nombre, 'titulo', p.titulo, 'tarjeta', p.tarjeta_profesional, 'foto', p.foto_url, 'color', p.color_marca,
    'paciente', split_part(btrim(pa.nombres), ' ', 1), 'clave', p.clave_publica)
  from public.formularios f join public.profesionales p on p.id = f.profesional_id join public.pacientes pa on pa.id = f.paciente_id
  where f.token = p_token;
$$;

create or replace function public.formulario_responder(p_token uuid, p_cifrado text, p_epk jsonb, p_iv text) returns boolean
language plpgsql security definer set search_path = public, privado as $$
declare f record; v_email text; v_pac text;
begin
  select * into f from public.formularios where token = p_token for update;
  if f.id is null or f.estado <> 'enviado' then raise exception 'Este enlace ya se usó'; end if;
  if f.expira < now() then raise exception 'Este enlace venció. Pide uno nuevo a tu profesional'; end if;
  if coalesce(length(p_cifrado), 0) not between 20 and 400000 or coalesce(length(p_iv), 0) not between 10 and 40 or p_epk is null then
    raise exception 'Respuesta no válida';
  end if;
  update public.formularios set estado = 'respondido', respuesta_cifrada = p_cifrado, epk = p_epk, iv = p_iv, respondido_at = now() where id = f.id;
  select p.email, split_part(btrim(pa.nombres), ' ', 1) into v_email, v_pac
    from public.profesionales p join public.pacientes pa on pa.id = f.paciente_id where p.id = f.profesional_id;
  perform privado.correo(v_email, '📩 ' || v_pac || ' respondió ' || case when f.tipo = 'prueba' then 'la prueba ' || f.prueba else 'el consentimiento informado' end,
    '<p><b>' || privado.html(v_pac) || '</b> ' || case when f.tipo = 'prueba' then 'completó la prueba <b>' || f.prueba || '</b>' else 'firmó el consentimiento informado' end
    || '.</p><p>Por seguridad la respuesta viaja cifrada. Abre su ficha en Consulta LV para verla.</p>');
  return true;
end $$;
revoke execute on function public.formulario_info(uuid) from public;
revoke execute on function public.formulario_responder(uuid, text, jsonb, text) from public;
grant execute on function public.formulario_info(uuid) to anon, authenticated;
grant execute on function public.formulario_responder(uuid, text, jsonb, text) to anon, authenticated;

create or replace function public.enviar_formulario_correo(p_id uuid, p_url text) returns boolean
language plpgsql security definer set search_path = public, privado as $$
declare f record;
begin
  select fo.tipo, fo.prueba, pa.email, pa.nombres, p.nombre prof into f
    from public.formularios fo join public.pacientes pa on pa.id = fo.paciente_id join public.profesionales p on p.id = fo.profesional_id
   where fo.id = p_id and fo.profesional_id = auth.uid() and fo.estado = 'enviado';
  if f.tipo is null or coalesce(f.email, '') = '' or p_url !~ '^https://[^\s"''<>]+$' or not public.mfa_ok() then return false; end if;
  return privado.correo(f.email, f.prof || ' te envió ' || case when f.tipo = 'prueba' then 'un cuestionario' else 'el consentimiento informado' end,
    '<p>Hola ' || privado.html(split_part(btrim(f.nombres), ' ', 1)) || ',</p><p><b>' || privado.html(f.prof) || '</b> te pide '
    || case when f.tipo = 'prueba' then 'responder un cuestionario corto antes de tu sesión.' else 'leer y firmar el consentimiento informado para tu atención psicológica.' end || '</p>'
    || '<p><a href="' || privado.html(p_url) || '" style="background:#0e7490;color:#fff;padding:11px 16px;border-radius:10px;text-decoration:none;font-weight:bold">'
    || case when f.tipo = 'prueba' then 'Responder cuestionario' else 'Leer y firmar' end || '</a></p><p style="font-size:13px;color:#64748b">Tus respuestas viajan cifradas: solo tu profesional puede verlas. El enlace vence en 14 días.</p>');
end $$;
revoke execute on function public.enviar_formulario_correo(uuid, text) from public, anon;
grant execute on function public.enviar_formulario_correo(uuid, text) to authenticated;

-- ---------- 3) VIDEOLLAMADA AUTOMÁTICA ----------
create or replace function public.enlace_video() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.enlace_virtual, '') = '' and exists (select 1 from public.servicios s where s.id = new.servicio_id and s.modalidad = 'virtual') then
    new.enlace_virtual := 'https://meet.jit.si/ConsultaLV-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16);
  end if;
  return new;
end $$;
drop trigger if exists trg_enlace_video on public.citas;
create trigger trg_enlace_video before insert on public.citas for each row execute function public.enlace_video();

-- ---------- 4) EL PACIENTE GESTIONA SU CITA ----------
create or replace function public.cita_paciente(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('estado', c.estado, 'inicio', c.inicio, 'fin', c.fin, 'enlace', c.enlace_virtual,
    'servicio', s.nombre, 'servicio_id', c.servicio_id, 'modalidad', s.modalidad, 'confirmada', c.confirmada_paciente_at is not null,
    'profesional', p.nombre, 'titulo', p.titulo, 'foto', p.foto_url, 'slug', p.slug, 'whatsapp', p.whatsapp, 'direccion', p.direccion, 'color', p.color_marca,
    'paciente', split_part(btrim(pa.nombres), ' ', 1),
    'puede_cancelar', c.estado in ('pendiente', 'confirmada') and c.inicio > now(),
    'puede_reprogramar', c.estado in ('pendiente', 'confirmada') and c.inicio > now() + interval '12 hours' and s.id is not null and s.activo and p.slug is not null)
  from public.citas c join public.profesionales p on p.id = c.profesional_id join public.pacientes pa on pa.id = c.paciente_id
  left join public.servicios s on s.id = c.servicio_id
  where c.token_paciente = p_token;
$$;

create or replace function privado.avisar_cambio(p_cita uuid, p_que text) returns void
language plpgsql security definer set search_path = public, privado as $$
declare r record;
begin
  select p.email, pa.nombres, c.inicio into r from public.citas c join public.profesionales p on p.id = c.profesional_id
    join public.pacientes pa on pa.id = c.paciente_id where c.id = p_cita;
  perform privado.correo(r.email, '📅 ' || r.nombres || ' ' || p_que,
    '<p><b>' || privado.html(r.nombres) || '</b> ' || privado.html(p_que) || '.</p><p>Cita: <b>' || privado.fecha_es(r.inicio) || '</b></p><p>Revisa tu agenda en Consulta LV.</p>');
end $$;

create or replace function public.cita_paciente_accion(p_token uuid, p_accion text, p_motivo text default '') returns boolean
language plpgsql security definer set search_path = public, privado as $$
declare c record;
begin
  select * into c from public.citas where token_paciente = p_token for update;
  if c.id is null or c.estado not in ('pendiente', 'confirmada') or c.inicio <= now() then raise exception 'Esta cita ya no se puede modificar'; end if;
  if p_accion = 'confirmar' then
    update public.citas set estado = 'confirmada', confirmada_paciente_at = now() where id = c.id;
    perform privado.avisar_cambio(c.id, 'confirmó su asistencia');
  elsif p_accion = 'cancelar' then
    update public.citas set estado = 'cancelada', cambio_paciente = left('Cancelada por el paciente' || case when btrim(coalesce(p_motivo, '')) <> '' then ': ' || btrim(p_motivo) else '' end, 300) where id = c.id;
    perform privado.avisar_cambio(c.id, 'canceló su cita' || case when btrim(coalesce(p_motivo, '')) <> '' then ' (' || left(btrim(p_motivo), 200) || ')' else '' end);
  else raise exception 'Acción no válida'; end if;
  return true;
end $$;

create or replace function public.cita_reprogramar(p_token uuid, p_inicio timestamptz) returns boolean
language plpgsql security definer set search_path = public, privado as $$
declare c record; v_slug text; v_ant timestamptz;
begin
  select ci.*, p.slug into c from public.citas ci join public.profesionales p on p.id = ci.profesional_id where ci.token_paciente = p_token for update of ci;
  if c.id is null or c.estado not in ('pendiente', 'confirmada') or c.inicio <= now() + interval '12 hours' or c.servicio_id is null or c.slug is null then
    raise exception 'Esta cita ya no se puede reprogramar en línea. Escríbele a tu profesional';
  end if;
  if not exists (select 1 from public.horarios_libres(c.slug, c.servicio_id, (p_inicio at time zone 'America/Bogota')::date) h where h.hora = p_inicio) then
    raise exception 'Ese horario ya no está disponible';
  end if;
  v_ant := c.inicio;
  update public.citas set inicio = p_inicio, fin = p_inicio + (c.fin - c.inicio), recordatorio_at = null, estado = 'confirmada',
    confirmada_paciente_at = now(), cambio_paciente = 'Reprogramada por el paciente (antes: ' || privado.fecha_es(v_ant) || ')' where id = c.id;
  perform privado.avisar_cambio(c.id, 'reprogramó su cita (antes: ' || privado.fecha_es(v_ant) || ')');
  return true;
exception when exclusion_violation then
  raise exception 'Ese horario ya no está disponible';
end $$;
revoke execute on function public.cita_paciente(uuid) from public;
revoke execute on function public.cita_paciente_accion(uuid, text, text) from public;
revoke execute on function public.cita_reprogramar(uuid, timestamptz) from public;
grant execute on function public.cita_paciente(uuid) to anon, authenticated;
grant execute on function public.cita_paciente_accion(uuid, text, text) to anon, authenticated;
grant execute on function public.cita_reprogramar(uuid, timestamptz) to anon, authenticated;

-- ---------- 5) CORREOS DE LA CITA ----------
create or replace function privado.correo_cita(p_cita uuid, p_tipo text) returns boolean
language plpgsql security definer set search_path = public, privado, extensions as $$
declare r record; v_key text; v_from text; v_nom text; v_html text; v_cal text; v_wa text; v_pago text; v_url text; v_tit text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'brevo_api_key';
  select valor into v_from from privado.config where clave = 'remitente_email';
  select valor into v_nom from privado.config where clave = 'remitente_nombre';
  if v_key is null or v_from is null then return false; end if;
  select c.id, c.inicio, c.fin, c.enlace_virtual, c.valor, c.pagado, c.token_paciente,
         pa.nombres, pa.email, s.nombre servicio, s.modalidad,
         p.nombre prof, p.email prof_email, p.whatsapp, p.direccion, p.nequi, p.datos_pago, p.enlace_pago
    into r
    from public.citas c join public.pacientes pa on pa.id = c.paciente_id join public.profesionales p on p.id = c.profesional_id
    left join public.servicios s on s.id = c.servicio_id where c.id = p_cita;
  if r.id is null or coalesce(r.email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return false; end if;
  v_url := 'https://luisvanegas15-wq.github.io/Consulta-LV/?c=' || r.token_paciente;
  v_cal := 'https://calendar.google.com/calendar/render?action=TEMPLATE'
    || '&text=' || privado.urlenc('Cita con ' || r.prof)
    || '&details=' || privado.urlenc(coalesce(r.servicio, 'Cita') || case when r.enlace_virtual ~ '^https://' then ' - Videollamada: ' || r.enlace_virtual else '' end || ' - Gestionar: ' || v_url)
    || '&dates=' || to_char(r.inicio at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"') || '/' || to_char(r.fin at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"');
  v_wa := case when length(regexp_replace(r.whatsapp, '\D', '', 'g')) >= 10
               then 'https://wa.me/' || case when length(regexp_replace(r.whatsapp, '\D', '', 'g')) = 10 then '57' else '' end || regexp_replace(r.whatsapp, '\D', '', 'g') end;
  v_pago := case when r.valor > 0 and not r.pagado and (r.nequi <> '' or r.datos_pago <> '' or r.enlace_pago ~ '^https://')
    then '<table width="100%" cellpadding="0" cellspacing="0" style="margin:14px 0"><tr><td bgcolor="#f1f5f9" style="background-color:#f1f5f9;border-radius:12px;padding:12px 14px;font-size:14px;color:#0f172a"><b>💳 Valor: $' || replace(to_char(r.valor, 'FM999,999,999'), ',', '.') || '</b><br>'
      || case when r.nequi <> '' then 'Nequi: <b>' || privado.html(r.nequi) || '</b><br>' else '' end
      || case when r.datos_pago <> '' then privado.html(r.datos_pago) || '<br>' else '' end
      || case when r.enlace_pago ~ '^https://[^\s"''<>]+$' then '<a href="' || privado.html(r.enlace_pago) || '" style="color:#0e7490;font-weight:bold">Pagar en línea</a>' else '' end
      || '</td></tr></table>' else '' end;
  v_tit := case when p_tipo = 'confirmacion' then 'Tu cita quedó reservada ✅'
                when (r.inicio at time zone 'America/Bogota')::date = (now() at time zone 'America/Bogota')::date then 'Hoy tienes cita 📅' else 'Mañana tienes cita 📅' end;
  v_html := '<div style="font-family:Arial,sans-serif;max-width:520px;margin:auto;color:#0f172a">'
    || '<table width="100%" cellpadding="0" cellspacing="0"><tr><td bgcolor="#3730a3" style="background-color:#3730a3;border-radius:16px;padding:20px;color:#ffffff">'
    || '<div style="font-size:13px;color:#e0e7ff">' || case when p_tipo = 'confirmacion' then 'Confirmación de tu reserva' else 'Recordatorio de tu cita' end || '</div>'
    || '<div style="font-size:22px;font-weight:bold;margin-top:4px;color:#ffffff">' || v_tit || '</div></td></tr></table>'
    || '<p style="font-size:15px;line-height:1.6">Hola ' || privado.html(split_part(btrim(r.nombres), ' ', 1)) || ', ' || case when p_tipo = 'confirmacion' then 'reservaste una cita' else 'te recordamos tu cita' end || ' con <b>' || privado.html(r.prof) || '</b>:</p>'
    || '<div style="border:1px solid #e2e8f0;border-radius:12px;padding:14px;font-size:15px;line-height:1.8">'
    || '🗓️ <b>' || privado.fecha_es(r.inicio) || '</b><br>💼 ' || privado.html(coalesce(r.servicio, 'Cita')) || '<br>'
    || case when r.enlace_virtual ~ '^https://[^\s"''<>]+$' then '🎥 <a href="' || privado.html(r.enlace_virtual) || '" style="color:#0e7490;font-weight:bold">Entrar a la videollamada</a> <span style="font-size:12px;color:#64748b">(ábrelo a la hora de la cita)</span><br>'
            when r.modalidad <> 'virtual' and r.direccion <> '' then '📍 ' || privado.html(r.direccion) || '<br>' else '' end
    || '</div>' || v_pago
    || '<p style="margin:16px 0"><a href="' || v_url || '" style="background:#0e7490;color:#ffffff;padding:11px 16px;border-radius:10px;text-decoration:none;font-weight:bold;font-size:14px;display:inline-block;margin:0 6px 8px 0">' || case when p_tipo = 'confirmacion' then 'Ver o cambiar mi cita' else 'Confirmar, cancelar o reprogramar' end || '</a>'
    || '<a href="' || v_cal || '" style="background:#e0f2fe;color:#075985;padding:11px 16px;border-radius:10px;text-decoration:none;font-weight:bold;font-size:14px;display:inline-block">Agregar a mi calendario</a></p>'
    || '<p style="font-size:14px;line-height:1.6">Si no puedes asistir, cancela o reprograma con anticipación desde el botón' || case when v_wa is not null then ' o escribe por <a href="' || v_wa || '" style="color:#0e7490">WhatsApp</a>' else '' end || '.</p>'
    || '<p style="font-size:12px;color:#64748b;line-height:1.5;border-top:1px solid #e2e8f0;padding-top:12px">¿Estás en crisis? Llama a la Línea 106 o al 123.<br>'
    || 'Recibes este correo porque reservaste o autorizaste recordatorios de tus citas. Enviado por Consulta LV (LV Studio) a nombre de ' || privado.html(r.prof) || '.</p></div>';
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', v_key, 'Content-Type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object(
      'sender', jsonb_build_object('email', v_from, 'name', left(r.prof, 40) || ' · ' || coalesce(v_nom, 'Consulta LV')),
      'to', jsonb_build_array(jsonb_build_object('email', r.email, 'name', r.nombres)),
      'subject', case when p_tipo = 'confirmacion' then 'Cita reservada con ' || r.prof || ': ' else 'Recordatorio: tu cita con ' || r.prof || ' es ' end || privado.fecha_es(r.inicio),
      'htmlContent', v_html, 'tags', jsonb_build_array(p_tipo))
      || case when coalesce(r.prof_email, '') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then jsonb_build_object('replyTo', jsonb_build_object('email', r.prof_email, 'name', r.prof)) else '{}'::jsonb end);
  return true;
end $$;
revoke all on function privado.correo_cita(uuid, text) from public, anon, authenticated;

create or replace function privado.enviar_recordatorios() returns int
language plpgsql security definer set search_path = public, privado as $$
declare r record; v_n int := 0;
begin
  for r in
    select c.id from public.citas c join public.pacientes pa on pa.id = c.paciente_id join public.profesionales p on p.id = c.profesional_id
    where c.estado in ('pendiente', 'confirmada') and c.recordatorio_at is null
      and c.inicio > now() + interval '1 hour' and c.inicio <= now() + interval '24 hours'
      and pa.email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
      and p.recordatorios_email and p.activo_hasta >= current_date and p.nombre <> ''
    order by c.inicio limit 250
  loop
    if privado.correo_cita(r.id, 'recordatorio') then
      update public.citas set recordatorio_at = now() where id = r.id; v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- Al reservar en línea: correo de confirmación al paciente y aviso al profesional
create or replace function privado.al_reservar() returns trigger
language plpgsql security definer set search_path = public, privado as $$
declare v_pac text; v_email text; v_serv text;
begin
  if new.origen = 'online' then
    perform privado.correo_cita(new.id, 'confirmacion');
    select pa.nombres into v_pac from public.pacientes pa where pa.id = new.paciente_id;
    select p.email into v_email from public.profesionales p where p.id = new.profesional_id;
    select s.nombre into v_serv from public.servicios s where s.id = new.servicio_id;
    perform privado.correo(v_email, '🆕 Nueva cita: ' || v_pac || ' · ' || privado.fecha_es(new.inicio),
      '<p><b>' || privado.html(v_pac) || '</b> reservó <b>' || privado.html(coalesce(v_serv, 'una cita')) || '</b> para el <b>' || privado.fecha_es(new.inicio) || '</b>.</p><p>Revísala en tu agenda de Consulta LV.</p>');
  end if;
  return new;
end $$;
drop trigger if exists trg_al_reservar on public.citas;
create trigger trg_al_reservar after insert on public.citas for each row execute function privado.al_reservar();

-- Reservar ahora devuelve el enlace para gestionar la cita
create or replace function public.reservar(
  p_slug text, p_servicio uuid, p_inicio timestamptz,
  p_nombres text, p_documento text, p_telefono text, p_email text,
  p_acepta_datos boolean, p_acepta_consentimiento boolean)
returns json
language plpgsql security definer set search_path = public as $$
declare v_prof uuid; v_dur int; v_precio int; v_pac uuid; v_cita uuid; v_n int; v_tok uuid; v_link text;
begin
  if not coalesce(p_acepta_datos, false) or not coalesce(p_acepta_consentimiento, false) then
    raise exception 'Debes aceptar la autorización de datos y el consentimiento informado';
  end if;
  p_nombres := btrim(coalesce(p_nombres, ''));
  p_documento := regexp_replace(coalesce(p_documento, ''), '[^0-9A-Za-z]', '', 'g');
  p_telefono := regexp_replace(coalesce(p_telefono, ''), '[^0-9+]', '', 'g');
  p_email := lower(btrim(coalesce(p_email, '')));
  if char_length(p_nombres) not between 3 and 120 or char_length(p_documento) not between 4 and 20 or char_length(p_telefono) not between 7 and 15 then
    raise exception 'Revisa tus datos: nombre, documento y teléfono son obligatorios';
  end if;
  if p_email <> '' and p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El correo no es válido'; end if;
  select p.id into v_prof from public.profesionales p where p.slug = lower(btrim(p_slug)) and p.activo_hasta >= current_date;
  if v_prof is null then raise exception 'Profesional no disponible'; end if;
  select s.duracion_min, s.precio into v_dur, v_precio from public.servicios s where s.id = p_servicio and s.profesional_id = v_prof and s.activo;
  if v_dur is null then raise exception 'Servicio no disponible'; end if;
  if not exists (select 1 from public.horarios_libres(p_slug, p_servicio, (p_inicio at time zone 'America/Bogota')::date) h where h.hora = p_inicio) then
    raise exception 'Ese horario ya no está disponible';
  end if;
  select count(*) into v_n from public.citas c join public.pacientes pa on pa.id = c.paciente_id
   where c.profesional_id = v_prof and pa.documento = p_documento and c.origen = 'online' and c.estado = 'pendiente' and c.inicio > now();
  if v_n >= 2 then raise exception 'Ya tienes reservas pendientes con este profesional'; end if;
  insert into public.pacientes (profesional_id, nombres, documento, telefono, email, autorizacion_datos_at, consentimiento_at)
  values (v_prof, p_nombres, p_documento, p_telefono, p_email, now(), now())
  on conflict (profesional_id, documento) do update
     set autorizacion_datos_at = now(), consentimiento_at = now(),
         email = case when excluded.email <> '' then excluded.email else public.pacientes.email end,
         telefono = case when excluded.telefono <> '' then excluded.telefono else public.pacientes.telefono end
  returning id into v_pac;
  insert into public.citas (profesional_id, paciente_id, servicio_id, inicio, fin, estado, origen, valor)
  values (v_prof, v_pac, p_servicio, p_inicio, p_inicio + make_interval(mins => v_dur), 'pendiente', 'online', v_precio)
  returning id, token_paciente, enlace_virtual into v_cita, v_tok, v_link;
  return json_build_object('ok', true, 'cita', v_cita, 'token', v_tok, 'enlace', v_link);
exception when exclusion_violation then
  raise exception 'Ese horario ya no está disponible';
end $$;

-- Limpieza diaria de sesiones verificadas viejas (más de 30 días)
select cron.schedule('limpiar-2fa-consulta-lv', '30 8 * * *', $$delete from privado.sesiones_ok where verificada_at < now() - interval '30 days'; delete from privado.codigos where expira < now() - interval '1 day'$$);
