-- =====================================================
-- CONSULTA LV · Actualización v6: horario automático
-- Las horas salen disponibles solas (jornada por defecto, sin festivos de Colombia).
-- El profesional solo marca cuándo NO atiende (bloqueos).
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================

alter table public.profesionales add column if not exists horario_auto boolean not null default true;
alter table public.profesionales add column if not exists dias_atencion smallint[] not null default '{1,2,3,4,5,6}';
alter table public.profesionales add column if not exists jornada_ini time not null default '08:00';
alter table public.profesionales add column if not exists jornada_fin time not null default '18:00';
alter table public.profesionales add column if not exists almuerzo_ini time default '12:00';
alter table public.profesionales add column if not exists almuerzo_fin time default '14:00';
alter table public.profesionales add column if not exists sabado_fin time default '12:00';
alter table public.profesionales add column if not exists atiende_festivos boolean not null default false;
alter table public.profesionales drop constraint if exists jornada_valida;
alter table public.profesionales add constraint jornada_valida check (
  jornada_fin > jornada_ini
  and (almuerzo_ini is null) = (almuerzo_fin is null)
  and (almuerzo_ini is null or (almuerzo_fin > almuerzo_ini and almuerzo_ini > jornada_ini and almuerzo_fin < jornada_fin))
  and dias_atencion <@ '{0,1,2,3,4,5,6}'::smallint[]);

-- Festivos de Colombia (Ley 51 de 1983 / Ley Emiliani) para cualquier año
create or replace function public.es_festivo(d date) returns boolean
language plpgsql immutable as $$
declare
  y int := extract(year from d)::int; a int; b int; c int; dd int; e int; f int; g int; h int; i int; k int; l int; m int;
  pascua date; lunes_sig date; fijo date;
begin
  a := y % 19; b := y / 100; c := y % 100; dd := b / 4; e := b % 4; f := (b + 8) / 25; g := (b - f + 1) / 3;
  h := (19 * a + b - dd - g + 15) % 30; i := c / 4; k := c % 4; l := (32 + 2 * e + 2 * i - h - k) % 7; m := (a + 11 * h + 22 * l) / 451;
  pascua := make_date(y, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
  if to_char(d, 'MM-DD') in ('01-01', '05-01', '07-20', '08-07', '12-08', '12-25') then return true; end if;
  if d in (pascua - 3, pascua - 2, pascua + 43, pascua + 64, pascua + 71) then return true; end if;
  foreach fijo in array array[make_date(y,1,6), make_date(y,3,19), make_date(y,6,29), make_date(y,8,15), make_date(y,10,12), make_date(y,11,1), make_date(y,11,11)] loop
    lunes_sig := fijo + ((8 - extract(isodow from fijo)::int) % 7);
    if d = lunes_sig then return true; end if;
  end loop;
  return false;
end $$;

-- Franjas de atención de un día: automáticas o personalizadas
create or replace function public.franjas_dia(p_prof uuid, p_fecha date)
returns table (hora_inicio time, hora_fin time)
language plpgsql stable security definer set search_path = public as $$
declare p record; v_dow int := extract(dow from p_fecha)::int; v_fin time;
begin
  select * into p from public.profesionales where id = p_prof;
  if p is null then return; end if;
  if not p.atiende_festivos and public.es_festivo(p_fecha) then return; end if;
  if not p.horario_auto then
    return query select distinct d.hora_inicio, d.hora_fin from public.disponibilidad d
                  where d.profesional_id = p_prof and d.dia = v_dow order by 1;
    return;
  end if;
  if not (v_dow = any (p.dias_atencion)) then return; end if;
  v_fin := case when v_dow = 6 and p.sabado_fin is not null then least(p.jornada_fin, p.sabado_fin) else p.jornada_fin end;
  if p.almuerzo_ini is not null and p.almuerzo_ini < v_fin then
    hora_inicio := p.jornada_ini; hora_fin := p.almuerzo_ini; return next;
    if p.almuerzo_fin < v_fin then hora_inicio := p.almuerzo_fin; hora_fin := v_fin; return next; end if;
  else
    hora_inicio := p.jornada_ini; hora_fin := v_fin; return next;
  end if;
end $$;

-- Horas de un día con su estado (libre / ocupada)
create or replace function public.horarios_dia(p_slug text, p_servicio uuid, p_fecha date)
returns table (hora timestamptz, libre boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_prof uuid; v_dur int; v_paso int; r record; t timestamp; v_ini timestamptz; v_vistos timestamptz[] := '{}';
  v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  select p.id into v_prof from public.profesionales p
   where p.slug = lower(btrim(p_slug)) and p.activo_hasta >= current_date;
  if v_prof is null or p_fecha is null or p_fecha < v_hoy or p_fecha > v_hoy + 60 then return; end if;
  select s.duracion_min into v_dur from public.servicios s
   where s.id = p_servicio and s.profesional_id = v_prof and s.activo;
  if v_dur is null then return; end if;
  v_paso := (ceil(v_dur / 30.0) * 30)::int;
  for r in select * from public.franjas_dia(v_prof, p_fecha) loop
    t := p_fecha + r.hora_inicio;
    while t + make_interval(mins => v_dur) <= p_fecha + r.hora_fin loop
      v_ini := t at time zone 'America/Bogota';
      if v_ini > now() + interval '1 hour' and not (v_ini = any (v_vistos)) then
        v_vistos := v_vistos || v_ini;
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

-- Solo las horas libres (la usa la reserva para validar)
create or replace function public.horarios_libres(p_slug text, p_servicio uuid, p_fecha date)
returns table (hora timestamptz)
language sql stable security definer set search_path = public as $$
  select h.hora from public.horarios_dia(p_slug, p_servicio, p_fecha) h where h.libre order by h.hora;
$$;

-- Bloqueos: no se pueden crear en el pasado lejano ni de más de 120 días
alter table public.bloqueos drop constraint if exists bloqueo_razonable;
alter table public.bloqueos add constraint bloqueo_razonable check (fin - inicio <= interval '120 days' and char_length(motivo) <= 120) not valid;

revoke execute on function public.es_festivo(date) from public;
revoke execute on function public.franjas_dia(uuid, date) from public, anon, authenticated;
grant execute on function public.es_festivo(date) to anon, authenticated;

grant execute on function public.horarios_dia(text, uuid, date) to anon, authenticated;
grant execute on function public.horarios_libres(text, uuid, date) to anon, authenticated;
