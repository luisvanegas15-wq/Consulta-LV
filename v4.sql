-- =====================================================
-- CONSULTA LV · Actualización v4: recordatorios automáticos por correo
-- Envía un correo al paciente ~24 horas antes de su cita (gratis con Brevo: 300 correos/día)
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- ---------- COLUMNAS NUEVAS ----------
alter table public.citas add column if not exists recordatorio_at timestamptz;
alter table public.profesionales add column if not exists recordatorios_email boolean not null default true;

-- ---------- ZONA PRIVADA (no accesible desde la app ni desde internet) ----------
create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;
create table if not exists privado.config (clave text primary key, valor text not null);
revoke all on privado.config from public, anon, authenticated;

-- Guarda la llave de Brevo cifrada en Vault y el remitente. Se ejecuta una sola vez (ver paso 2).
create or replace function privado.configurar_correo(p_api_key text, p_remitente text, p_nombre text default 'Consulta LV')
returns text language plpgsql security definer set search_path = public, privado, vault as $$
declare v_id uuid;
begin
  if coalesce(p_api_key, '') !~ '^xkeysib-' then raise exception 'La llave de Brevo debe empezar por xkeysib-'; end if;
  if coalesce(p_remitente, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El correo remitente no es válido'; end if;
  select id into v_id from vault.secrets where name = 'brevo_api_key';
  if v_id is null then perform vault.create_secret(p_api_key, 'brevo_api_key', 'Llave API de Brevo para recordatorios');
  else perform vault.update_secret(v_id, p_api_key); end if;
  insert into privado.config values ('remitente_email', lower(btrim(p_remitente)))
    on conflict (clave) do update set valor = excluded.valor;
  insert into privado.config values ('remitente_nombre', left(btrim(p_nombre), 60))
    on conflict (clave) do update set valor = excluded.valor;
  return 'Correo configurado ✅';
end $$;
revoke all on function privado.configurar_correo(text, text, text) from public, anon, authenticated;

create or replace function privado.html(t text) returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

create or replace function privado.urlenc(t text) returns text language plpgsql immutable as $$
declare r text := ''; c text; b bytea; i int;
begin
  foreach c in array regexp_split_to_array(coalesce(t, ''), '') loop
    if c ~ '^[A-Za-z0-9._~-]$' then r := r || c;
    else b := convert_to(c, 'UTF8'); for i in 0 .. length(b) - 1 loop r := r || '%' || upper(lpad(to_hex(get_byte(b, i)), 2, '0')); end loop; end if;
  end loop;
  return r;
end $$;

-- Fecha en español, hora de Colombia
create or replace function privado.fecha_es(t timestamptz) returns text language sql stable as $$
  select (array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])[extract(dow from l)::int + 1] || ' ' ||
         extract(day from l)::int || ' de ' ||
         (array['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'])[extract(month from l)::int] ||
         ' a las ' || ltrim(to_char(l, 'HH12:MI'), '0') || case when extract(hour from l) < 12 then ' a. m.' else ' p. m.' end
  from (select t at time zone 'America/Bogota' as l) x;
$$;

-- ---------- ENVÍO DE RECORDATORIOS (se ejecuta cada hora) ----------
create or replace function privado.enviar_recordatorios() returns int
language plpgsql security definer set search_path = public, privado, extensions as $$
declare
  v_key text; v_from text; v_nom text; r record; v_html text; v_cal text; v_n int := 0; v_wa text; v_pago text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'brevo_api_key';
  select valor into v_from from privado.config where clave = 'remitente_email';
  select valor into v_nom from privado.config where clave = 'remitente_nombre';
  if v_key is null or v_from is null then return 0; end if;

  for r in
    select c.id, c.inicio, c.fin, c.enlace_virtual, c.valor, c.pagado,
           pa.nombres, pa.email, s.nombre servicio, s.modalidad,
           p.nombre prof, p.titulo, p.email prof_email, p.whatsapp, p.direccion, p.nequi, p.datos_pago, p.enlace_pago
    from public.citas c
    join public.pacientes pa on pa.id = c.paciente_id
    join public.profesionales p on p.id = c.profesional_id
    left join public.servicios s on s.id = c.servicio_id
    where c.estado in ('pendiente', 'confirmada')
      and c.recordatorio_at is null
      and c.inicio > now() + interval '1 hour' and c.inicio <= now() + interval '24 hours'
      and pa.email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
      and p.recordatorios_email and p.activo_hasta >= current_date and p.nombre <> ''
    order by c.inicio
    limit 250
  loop
    v_cal := 'https://calendar.google.com/calendar/render?action=TEMPLATE'
      || '&text=' || privado.urlenc('Cita con ' || r.prof)
      || '&details=' || privado.urlenc(coalesce(r.servicio, 'Cita') || case when r.enlace_virtual ~ '^https://' then ' - Videollamada: ' || r.enlace_virtual else '' end)
      || '&dates=' || to_char(r.inicio at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"') || '/' || to_char(r.fin at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"');
    v_wa := case when length(regexp_replace(r.whatsapp, '\D', '', 'g')) >= 10
                 then 'https://wa.me/' || case when length(regexp_replace(r.whatsapp, '\D', '', 'g')) = 10 then '57' else '' end || regexp_replace(r.whatsapp, '\D', '', 'g') end;
    v_pago := case when r.valor > 0 and not r.pagado and (r.nequi <> '' or r.datos_pago <> '' or r.enlace_pago ~ '^https://')
      then '<div style="background:#f8fafc;border-radius:12px;padding:12px 14px;margin:14px 0;font-size:14px"><b>💳 Valor: $' || replace(to_char(r.valor, 'FM999,999,999'), ',', '.') || '</b><br>'
        || case when r.nequi <> '' then 'Nequi: <b>' || privado.html(r.nequi) || '</b><br>' else '' end
        || case when r.datos_pago <> '' then privado.html(r.datos_pago) || '<br>' else '' end
        || case when r.enlace_pago ~ '^https://[^\s"''<>]+$' then '<a href="' || privado.html(r.enlace_pago) || '" style="color:#0e7490;font-weight:bold">Pagar en línea</a>' else '' end
        || '</div>' else '' end;
    v_html := '<div style="font-family:Arial,sans-serif;max-width:520px;margin:auto;color:#0f172a">'
      || '<div style="background:linear-gradient(135deg,#0e7490,#6d28d9);color:#fff;border-radius:16px;padding:20px">'
      || '<div style="font-size:13px;opacity:.85">Recordatorio de tu cita</div><div style="font-size:22px;font-weight:bold;margin-top:4px">' || case when (r.inicio at time zone 'America/Bogota')::date = (now() at time zone 'America/Bogota')::date then 'Hoy' else 'Mañana' end || ' tienes cita 📅</div></div>'
      || '<p style="font-size:15px;line-height:1.6">Hola ' || privado.html(split_part(btrim(r.nombres), ' ', 1)) || ', te recordamos tu cita con <b>' || privado.html(r.prof) || '</b>:</p>'
      || '<div style="border:1px solid #e2e8f0;border-radius:12px;padding:14px;font-size:15px;line-height:1.8">'
      || '🗓️ <b>' || privado.fecha_es(r.inicio) || '</b><br>'
      || '💼 ' || privado.html(coalesce(r.servicio, 'Cita')) || '<br>'
      || case when r.enlace_virtual ~ '^https://[^\s"''<>]+$' then '🎥 <a href="' || privado.html(r.enlace_virtual) || '" style="color:#0e7490;font-weight:bold">Entrar a la videollamada</a><br>'
              when r.modalidad <> 'virtual' and r.direccion <> '' then '📍 ' || privado.html(r.direccion) || '<br>' else '' end
      || '</div>' || v_pago
      || '<p style="margin:16px 0"><a href="' || v_cal || '" style="background:#0e7490;color:#fff;padding:11px 16px;border-radius:10px;text-decoration:none;font-weight:bold;font-size:14px">Agregar a mi calendario</a></p>'
      || '<p style="font-size:14px;line-height:1.6">Si no puedes asistir, avísale con anticipación' || case when v_wa is not null then ' por <a href="' || v_wa || '" style="color:#0e7490">WhatsApp</a>' else ' respondiendo este correo' end || '.</p>'
      || '<p style="font-size:12px;color:#64748b;line-height:1.5;border-top:1px solid #e2e8f0;padding-top:12px">¿Estás en crisis? Llama a la Línea 106 o al 123.<br>'
      || 'Recibes este correo porque autorizaste recordatorios de tus citas. Enviado por Consulta LV (LV Studio) a nombre de ' || privado.html(r.prof) || '.</p></div>';

    perform net.http_post(
      url := 'https://api.brevo.com/v3/smtp/email',
      headers := jsonb_build_object('api-key', v_key, 'Content-Type', 'application/json', 'accept', 'application/json'),
      body := jsonb_build_object(
        'sender', jsonb_build_object('email', v_from, 'name', left(r.prof, 40) || ' · ' || coalesce(v_nom, 'Consulta LV')),
        'to', jsonb_build_array(jsonb_build_object('email', r.email, 'name', r.nombres)),
        'subject', 'Recordatorio: tu cita con ' || r.prof || ' es ' || privado.fecha_es(r.inicio),
        'htmlContent', v_html,
        'tags', jsonb_build_array('recordatorio'))
        || case when coalesce(r.prof_email, '') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then jsonb_build_object('replyTo', jsonb_build_object('email', r.prof_email, 'name', r.prof)) else '{}'::jsonb end);
    update public.citas set recordatorio_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function privado.enviar_recordatorios() from public, anon, authenticated;

-- ---------- PROGRAMAR: cada hora al minuto 5 ----------
select cron.schedule('recordatorios-consulta-lv', '5 * * * *', 'select privado.enviar_recordatorios()');
