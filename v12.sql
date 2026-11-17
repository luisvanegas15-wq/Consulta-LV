-- =====================================================
-- CONSULTA LV · Actualización v12: paquetes de sesiones y política de cancelación
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
alter table public.profesionales add column if not exists horas_cancelacion int not null default 12;
alter table public.profesionales drop constraint if exists horas_cancelacion_valida;
alter table public.profesionales add constraint horas_cancelacion_valida check (horas_cancelacion between 0 and 168);

-- ---------- PAQUETES DE SESIONES ----------
create table if not exists public.paquetes (
  id uuid primary key default gen_random_uuid(),
  profesional_id uuid not null default auth.uid() references public.profesionales(id) on delete cascade,
  paciente_id uuid not null references public.pacientes(id) on delete cascade,
  nombre text not null check (char_length(btrim(nombre)) between 2 and 80),
  sesiones int not null check (sesiones between 1 and 100),
  valor int not null default 0 check (valor between 0 and 100000000),
  pagado boolean not null default false,
  metodo_pago text not null default '' check (char_length(metodo_pago) <= 20),
  fecha date not null default (now() at time zone 'America/Bogota')::date,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists paquetes_paciente on public.paquetes (paciente_id);
alter table public.paquetes enable row level security;
grant select, insert, update, delete on public.paquetes to authenticated;
drop policy if exists paq_ver on public.paquetes;
create policy paq_ver on public.paquetes for select to authenticated using (profesional_id = auth.uid());
drop policy if exists paq_crear on public.paquetes;
create policy paq_crear on public.paquetes for insert to authenticated with check (
  profesional_id = auth.uid() and exists (select 1 from public.pacientes pa where pa.id = paciente_id and pa.profesional_id = auth.uid()));
drop policy if exists paq_editar on public.paquetes;
create policy paq_editar on public.paquetes for update to authenticated using (profesional_id = auth.uid()) with check (
  profesional_id = auth.uid() and exists (select 1 from public.pacientes pa where pa.id = paciente_id and pa.profesional_id = auth.uid()));
drop policy if exists paq_borrar on public.paquetes;
create policy paq_borrar on public.paquetes for delete to authenticated using (profesional_id = auth.uid());
drop policy if exists mfa_exigido on public.paquetes;
create policy mfa_exigido on public.paquetes as restrictive for all to authenticated using (public.mfa_ok()) with check (public.mfa_ok());

alter table public.citas add column if not exists paquete_id uuid references public.paquetes(id) on delete set null;
create or replace function public.validar_paquete_cita() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.paquete_id is not null and not exists (
      select 1 from public.paquetes q where q.id = new.paquete_id and q.profesional_id = new.profesional_id and q.paciente_id = new.paciente_id) then
    raise exception 'El paquete no corresponde a este paciente';
  end if;
  return new;
end $$;
drop trigger if exists trg_paquete_cita on public.citas;
create trigger trg_paquete_cita before insert or update of paquete_id, paciente_id on public.citas for each row execute function public.validar_paquete_cita();

-- ---------- POLÍTICA DE CANCELACIÓN (horas mínimas que elige el profesional) ----------
create or replace function public.cita_paciente(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('estado', c.estado, 'inicio', c.inicio, 'fin', c.fin, 'enlace', c.enlace_virtual,
    'servicio', s.nombre, 'servicio_id', c.servicio_id, 'modalidad', s.modalidad, 'confirmada', c.confirmada_paciente_at is not null,
    'profesional', p.nombre, 'titulo', p.titulo, 'foto', p.foto_url, 'slug', p.slug, 'whatsapp', p.whatsapp, 'direccion', p.direccion, 'color', p.color_marca,
    'paciente', split_part(btrim(pa.nombres), ' ', 1), 'horas', p.horas_cancelacion,
    'puede_cancelar', c.estado in ('pendiente', 'confirmada') and c.inicio > now() + make_interval(hours => p.horas_cancelacion),
    'puede_reprogramar', c.estado in ('pendiente', 'confirmada') and c.inicio > now() + make_interval(hours => greatest(p.horas_cancelacion, 1)) and s.id is not null and s.activo and p.slug is not null,
    'puede_confirmar', c.estado in ('pendiente', 'confirmada') and c.inicio > now())
  from public.citas c join public.profesionales p on p.id = c.profesional_id join public.pacientes pa on pa.id = c.paciente_id
  left join public.servicios s on s.id = c.servicio_id
  where c.token_paciente = p_token;
$$;

create or replace function public.cita_paciente_accion(p_token uuid, p_accion text, p_motivo text default '') returns boolean
language plpgsql security definer set search_path = public, privado as $$
declare c record;
begin
  select ci.*, p.horas_cancelacion horas into c from public.citas ci join public.profesionales p on p.id = ci.profesional_id where ci.token_paciente = p_token for update of ci;
  if c.id is null or c.estado not in ('pendiente', 'confirmada') or c.inicio <= now() then raise exception 'Esta cita ya no se puede modificar'; end if;
  if p_accion = 'confirmar' then
    update public.citas set estado = 'confirmada', confirmada_paciente_at = now() where id = c.id;
    perform privado.avisar_cambio(c.id, 'confirmó su asistencia');
  elsif p_accion = 'cancelar' then
    if c.inicio <= now() + make_interval(hours => c.horas) then
      raise exception 'Ya no se puede cancelar en línea (mínimo % horas antes). Escríbele a tu profesional', c.horas;
    end if;
    update public.citas set estado = 'cancelada', cambio_paciente = left('Cancelada por el paciente' || case when btrim(coalesce(p_motivo, '')) <> '' then ': ' || btrim(p_motivo) else '' end, 300) where id = c.id;
    perform privado.avisar_cambio(c.id, 'canceló su cita' || case when btrim(coalesce(p_motivo, '')) <> '' then ' (' || left(btrim(p_motivo), 200) || ')' else '' end);
  else raise exception 'Acción no válida'; end if;
  return true;
end $$;

create or replace function public.cita_reprogramar(p_token uuid, p_inicio timestamptz) returns boolean
language plpgsql security definer set search_path = public, privado as $$
declare c record; v_ant timestamptz;
begin
  select ci.*, p.slug, p.horas_cancelacion horas into c from public.citas ci join public.profesionales p on p.id = ci.profesional_id where ci.token_paciente = p_token for update of ci;
  if c.id is null or c.estado not in ('pendiente', 'confirmada') or c.inicio <= now() + make_interval(hours => greatest(c.horas, 1)) or c.servicio_id is null or c.slug is null then
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
