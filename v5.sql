-- =====================================================
-- CONSULTA LV · Actualización v5: calendario de reservas para el paciente
-- Muestra qué días tienen horario libre y qué horas están ocupadas (sin datos de otros pacientes)
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================

-- Todas las horas del día con su estado: libre u ocupada
create or replace function public.horarios_dia(p_slug text, p_servicio uuid, p_fecha date)
returns table (hora timestamptz, libre boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_prof uuid; v_dur int; v_paso int; r record; t timestamp; v_ini timestamptz;
  v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  select p.id into v_prof from public.profesionales p
   where p.slug = lower(btrim(p_slug)) and p.activo_hasta >= current_date;
  if v_prof is null or p_fecha is null or p_fecha < v_hoy or p_fecha > v_hoy + 60 then return; end if;
  select s.duracion_min into v_dur from public.servicios s
   where s.id = p_servicio and s.profesional_id = v_prof and s.activo;
  if v_dur is null then return; end if;
  v_paso := (ceil(v_dur / 30.0) * 30)::int;
  for r in select d.hora_inicio, d.hora_fin from public.disponibilidad d
            where d.profesional_id = v_prof and d.dia = extract(dow from p_fecha)::int
            order by d.hora_inicio loop
    t := p_fecha + r.hora_inicio;
    while t + make_interval(mins => v_dur) <= p_fecha + r.hora_fin loop
      v_ini := t at time zone 'America/Bogota';
      if v_ini > now() + interval '1 hour' then
        hora := v_ini;
        libre := not exists (select 1 from public.citas c
                              where c.profesional_id = v_prof and c.estado <> 'cancelada'
                                and tstzrange(c.inicio, c.fin) && tstzrange(v_ini, v_ini + make_interval(mins => v_dur)))
             and not exists (select 1 from public.bloqueos b
                              where b.profesional_id = v_prof
                                and tstzrange(b.inicio, b.fin) && tstzrange(v_ini, v_ini + make_interval(mins => v_dur)));
        return next;
      end if;
      t := t + make_interval(mins => v_paso);
    end loop;
  end loop;
end $$;

-- Días (dentro del rango) que tienen al menos una hora libre
create or replace function public.dias_disponibles(p_slug text, p_servicio uuid, p_desde date, p_hasta date)
returns setof date
language plpgsql stable security definer set search_path = public as $$
declare
  d date; v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  if p_desde is null or p_hasta is null then return; end if;
  d := greatest(p_desde, v_hoy);
  while d <= least(p_hasta, v_hoy + 60, p_desde + 45) loop
    if exists (select 1 from public.horarios_libres(p_slug, p_servicio, d)) then return next d; end if;
    d := d + 1;
  end loop;
end $$;

revoke execute on function public.horarios_dia(text, uuid, date) from public;
revoke execute on function public.dias_disponibles(text, uuid, date, date) from public;
grant execute on function public.horarios_dia(text, uuid, date) to anon, authenticated;
grant execute on function public.dias_disponibles(text, uuid, date, date) to anon, authenticated;
