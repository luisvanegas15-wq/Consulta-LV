-- =====================================================
-- CONSULTA LV · Actualización v3
-- Finanzas, reseñas verificadas, lista de espera, directorio,
-- plantillas de notas, adjuntos cifrados, citas recurrentes y pagos
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================

-- ---------- PERFIL: pagos y directorio ----------
alter table public.profesionales add column if not exists datos_pago text not null default '';
alter table public.profesionales add column if not exists enlace_pago text not null default '';
alter table public.profesionales add column if not exists en_directorio boolean not null default false;
alter table public.profesionales drop constraint if exists pago_valido;
alter table public.profesionales add constraint pago_valido check (
  char_length(datos_pago) <= 300 and char_length(enlace_pago) <= 300
  and (enlace_pago = '' or enlace_pago ~ '^https://[^\s"''<>]+$'));

-- ---------- CITAS RECURRENTES ----------
alter table public.citas add column if not exists serie uuid;
create index if not exists citas_serie on public.citas (serie) where serie is not null;

-- ---------- GASTOS (panel de finanzas) ----------
create table if not exists public.gastos (
  id uuid primary key default gen_random_uuid(),
  profesional_id uuid not null default auth.uid() references public.profesionales(id) on delete cascade,
  fecha date not null default current_date,
  concepto text not null check (char_length(concepto) between 2 and 120),
  categoria text not null default 'otro' check (categoria in ('arriendo','servicios','software','publicidad','formacion','transporte','impuestos','materiales','otro')),
  valor int not null check (valor between 1 and 100000000),
  created_at timestamptz not null default now()
);

-- ---------- PLANTILLAS DE NOTA (solo títulos de campos, sin datos de pacientes) ----------
create table if not exists public.plantillas (
  id uuid primary key default gen_random_uuid(),
  profesional_id uuid not null default auth.uid() references public.profesionales(id) on delete cascade,
  nombre text not null check (char_length(nombre) between 2 and 60),
  campos jsonb not null check (jsonb_typeof(campos) = 'array' and jsonb_array_length(campos) between 1 and 15),
  created_at timestamptz not null default now()
);

-- ---------- ADJUNTOS CIFRADOS (el archivo se cifra en el celular antes de subir) ----------
create table if not exists public.adjuntos (
  id uuid primary key default gen_random_uuid(),
  profesional_id uuid not null default auth.uid() references public.profesionales(id) on delete restrict,
  paciente_id uuid not null references public.pacientes(id) on delete restrict,
  ruta text not null unique,
  iv text not null,
  meta_cifrada text not null,
  iv_meta text not null,
  created_at timestamptz not null default now()
);

-- ---------- RESEÑAS VERIFICADAS (solo pacientes que asistieron) ----------
create table if not exists public.resenas (
  id uuid primary key default gen_random_uuid(),
  profesional_id uuid not null references public.profesionales(id) on delete cascade,
  cita_id uuid not null unique references public.citas(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  estrellas smallint check (estrellas between 1 and 5),
  comentario text not null default '' check (char_length(comentario) <= 600),
  alias text not null default '',
  publicada_at timestamptz,
  respuesta text not null default '' check (char_length(respuesta) <= 600),
  created_at timestamptz not null default now()
);

-- ---------- LISTA DE ESPERA ----------
create table if not exists public.lista_espera (
  id uuid primary key default gen_random_uuid(),
  profesional_id uuid not null default auth.uid() references public.profesionales(id) on delete cascade,
  servicio_id uuid references public.servicios(id) on delete set null,
  nombres text not null check (char_length(nombres) between 3 and 120),
  telefono text not null check (char_length(telefono) between 7 and 15),
  email text not null default '',
  preferencia text not null default '' check (char_length(preferencia) <= 300),
  estado text not null default 'esperando' check (estado in ('esperando','contactado','agendado','descartado')),
  autorizacion_datos_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------- SEGURIDAD POR FILA ----------
alter table public.gastos enable row level security;
alter table public.plantillas enable row level security;
alter table public.adjuntos enable row level security;
alter table public.resenas enable row level security;
alter table public.lista_espera enable row level security;

drop policy if exists gasto_todo on public.gastos;
create policy gasto_todo on public.gastos for all to authenticated
  using (profesional_id = (select auth.uid())) with check (profesional_id = (select auth.uid()));
drop policy if exists plant_todo on public.plantillas;
create policy plant_todo on public.plantillas for all to authenticated
  using (profesional_id = (select auth.uid())) with check (profesional_id = (select auth.uid()));
drop policy if exists adj_ver on public.adjuntos;
create policy adj_ver on public.adjuntos for select to authenticated using (profesional_id = (select auth.uid()));
drop policy if exists adj_crear on public.adjuntos;
create policy adj_crear on public.adjuntos for insert to authenticated with check (
  profesional_id = (select auth.uid())
  and exists (select 1 from public.pacientes p where p.id = paciente_id and p.profesional_id = (select auth.uid()))
  and split_part(ruta, '/', 1) = (select auth.uid())::text);
drop policy if exists res_ver on public.resenas;
create policy res_ver on public.resenas for select to authenticated using (profesional_id = (select auth.uid()));
drop policy if exists res_responder on public.resenas;
create policy res_responder on public.resenas for update to authenticated
  using (profesional_id = (select auth.uid())) with check (profesional_id = (select auth.uid()));
drop policy if exists esp_todo on public.lista_espera;
create policy esp_todo on public.lista_espera for all to authenticated
  using (profesional_id = (select auth.uid())) with check (profesional_id = (select auth.uid()));

-- ---------- PERMISOS ----------
revoke all on public.gastos, public.plantillas, public.adjuntos, public.resenas, public.lista_espera from anon, authenticated;
grant select, insert, update, delete on public.gastos, public.plantillas to authenticated;
grant select, insert on public.adjuntos to authenticated;
grant select on public.resenas to authenticated;
grant update (respuesta) on public.resenas to authenticated;
grant select, insert, update on public.lista_espera to authenticated;

drop trigger if exists aud_adjuntos on public.adjuntos;
create trigger aud_adjuntos after insert on public.adjuntos for each row execute function public.auditar();

-- ---------- ARCHIVOS ADJUNTOS (privados, cifrados, cada psicólogo su carpeta) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('adjuntos', 'adjuntos', false, 10485760, array['application/octet-stream'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/octet-stream'];

drop policy if exists adj_subir on storage.objects;
drop policy if exists adj_leer on storage.objects;
create policy adj_subir on storage.objects for insert to authenticated
  with check (bucket_id = 'adjuntos' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy adj_leer on storage.objects for select to authenticated
  using (bucket_id = 'adjuntos' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------- FUNCIONES ----------
-- Perfil público con reseñas y datos de pago
create or replace function public.perfil_publico(p_slug text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'nombre', p.nombre, 'titulo', p.titulo, 'tarjeta', p.tarjeta_profesional, 'ciudad', p.ciudad,
    'bio', p.bio, 'foto', p.foto_url, 'direccion', p.direccion, 'whatsapp', p.whatsapp,
    'enfoque', p.enfoque, 'especialidades', p.especialidades, 'formacion', p.formacion,
    'experiencia', p.experiencia_anios, 'poblacion', p.poblacion, 'idiomas', p.idiomas,
    'nequi', p.nequi, 'datos_pago', p.datos_pago, 'enlace_pago', p.enlace_pago,
    'promedio', (select round(avg(r.estrellas)::numeric, 1) from public.resenas r where r.profesional_id = p.id and r.publicada_at is not null),
    'n_resenas', (select count(*) from public.resenas r where r.profesional_id = p.id and r.publicada_at is not null),
    'resenas', coalesce((
      select json_agg(x order by x.f desc) from (
        select r.estrellas e, r.comentario c, r.alias a, r.respuesta rp, r.publicada_at f
        from public.resenas r where r.profesional_id = p.id and r.publicada_at is not null
        order by r.publicada_at desc limit 20) x), '[]'::json),
    'servicios', coalesce((
      select json_agg(json_build_object('id', s.id, 'nombre', s.nombre, 'duracion', s.duracion_min,
                                        'precio', s.precio, 'modalidad', s.modalidad) order by s.precio)
      from public.servicios s where s.profesional_id = p.id and s.activo), '[]'::json))
  from public.profesionales p
  where p.slug = lower(btrim(p_slug)) and p.activo_hasta >= current_date and p.nombre <> '';
$$;

-- Directorio público de psicólogos (solo quienes lo activan)
create or replace function public.directorio(p_buscar text, p_ciudad text, p_modalidad text) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by x.score desc, x.n desc, x.nombre), '[]'::json) from (
    select p.slug, p.nombre, p.titulo, p.ciudad, p.foto_url foto, p.enfoque, p.especialidades, p.experiencia_anios experiencia,
      (select min(s.precio) from public.servicios s where s.profesional_id = p.id and s.activo and s.precio > 0) precio_desde,
      (select array_agg(distinct s.modalidad) from public.servicios s where s.profesional_id = p.id and s.activo) modalidades,
      (select round(avg(r.estrellas)::numeric, 1) from public.resenas r where r.profesional_id = p.id and r.publicada_at is not null) promedio,
      (select count(*) from public.resenas r where r.profesional_id = p.id and r.publicada_at is not null) n,
      coalesce((select avg(r.estrellas) from public.resenas r where r.profesional_id = p.id and r.publicada_at is not null), 0) score
    from public.profesionales p
    where p.en_directorio and p.slug is not null and p.nombre <> '' and p.activo_hasta >= current_date
      and exists (select 1 from public.servicios s where s.profesional_id = p.id and s.activo)
      and (coalesce(btrim(p_buscar), '') = '' or strpos(lower(concat_ws(' ', p.nombre, p.enfoque, p.especialidades, p.poblacion, p.titulo)), lower(btrim(p_buscar))) > 0)
      and (coalesce(btrim(p_ciudad), '') = '' or strpos(lower(p.ciudad), lower(btrim(p_ciudad))) > 0)
      and (coalesce(p_modalidad, '') = '' or exists (select 1 from public.servicios s where s.profesional_id = p.id and s.activo
             and (s.modalidad = p_modalidad or s.modalidad = 'ambas')))
    limit 60) x;
$$;

-- El psicólogo genera el enlace de reseña (solo para citas a las que el paciente asistió)
create or replace function public.invitar_resena(p_cita uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tok uuid;
begin
  if not exists (select 1 from public.citas c where c.id = p_cita and c.profesional_id = auth.uid() and c.estado = 'asistio') then
    raise exception 'Solo puedes pedir reseña de citas a las que el paciente asistió';
  end if;
  insert into public.resenas (profesional_id, cita_id) values (auth.uid(), p_cita) on conflict (cita_id) do nothing;
  select token into v_tok from public.resenas where cita_id = p_cita;
  return v_tok;
end $$;

create or replace function public.resena_info(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('profesional', p.nombre, 'foto', p.foto_url, 'titulo', p.titulo, 'slug', p.slug,
    'fecha', c.inicio, 'hecha', r.publicada_at is not null)
  from public.resenas r join public.citas c on c.id = r.cita_id join public.profesionales p on p.id = r.profesional_id
  where r.token = p_token;
$$;

create or replace function public.dejar_resena(p_token uuid, p_estrellas int, p_comentario text, p_mostrar_nombre boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_nom text;
begin
  if p_estrellas is null or p_estrellas not between 1 and 5 then raise exception 'Elige de 1 a 5 estrellas'; end if;
  select r.id, pa.nombres into v_id, v_nom from public.resenas r
    join public.citas c on c.id = r.cita_id join public.pacientes pa on pa.id = c.paciente_id
   where r.token = p_token and r.publicada_at is null;
  if v_id is null then raise exception 'Este enlace ya fue usado o no es válido'; end if;
  update public.resenas set estrellas = p_estrellas,
    comentario = left(btrim(coalesce(p_comentario, '')), 600),
    alias = case when coalesce(p_mostrar_nombre, false)
                 then split_part(btrim(v_nom), ' ', 1) || coalesce(' ' || nullif(left(split_part(btrim(v_nom), ' ', 2), 1), '') || '.', '')
                 else 'Paciente verificado' end,
    publicada_at = now()
  where id = v_id;
  return json_build_object('ok', true);
end $$;

-- Lista de espera desde la página pública
create or replace function public.unirse_espera(p_slug text, p_servicio uuid, p_nombres text, p_telefono text,
  p_email text, p_preferencia text, p_acepta_datos boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_prof uuid; v_id uuid;
begin
  if not coalesce(p_acepta_datos, false) then raise exception 'Debes aceptar la autorización de datos'; end if;
  p_nombres := btrim(coalesce(p_nombres, ''));
  p_telefono := regexp_replace(coalesce(p_telefono, ''), '[^0-9+]', '', 'g');
  p_email := lower(btrim(coalesce(p_email, '')));
  if char_length(p_nombres) not between 3 and 120 or char_length(p_telefono) not between 7 and 15 then
    raise exception 'Escribe tu nombre y un celular válido';
  end if;
  if p_email <> '' and p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El correo no es válido'; end if;
  select id into v_prof from public.profesionales where slug = lower(btrim(p_slug)) and activo_hasta >= current_date;
  if v_prof is null then raise exception 'Profesional no disponible'; end if;
  if p_servicio is not null and not exists (select 1 from public.servicios where id = p_servicio and profesional_id = v_prof) then
    p_servicio := null;
  end if;
  select id into v_id from public.lista_espera where profesional_id = v_prof and telefono = p_telefono and estado = 'esperando';
  if v_id is not null then
    update public.lista_espera set preferencia = left(coalesce(p_preferencia, ''), 300), servicio_id = coalesce(p_servicio, servicio_id) where id = v_id;
    return json_build_object('ok', true);
  end if;
  if (select count(*) from public.lista_espera where profesional_id = v_prof and estado = 'esperando') >= 200 then
    raise exception 'La lista de espera está llena. Escribe directamente al profesional';
  end if;
  insert into public.lista_espera (profesional_id, servicio_id, nombres, telefono, email, preferencia, autorizacion_datos_at)
  values (v_prof, p_servicio, left(p_nombres, 120), p_telefono, left(p_email, 120), left(coalesce(p_preferencia, ''), 300), now());
  return json_build_object('ok', true);
end $$;

-- Permisos de funciones
revoke execute on function public.perfil_publico(text) from public;
revoke execute on function public.directorio(text, text, text) from public;
revoke execute on function public.invitar_resena(uuid) from public;
revoke execute on function public.resena_info(uuid) from public;
revoke execute on function public.dejar_resena(uuid, int, text, boolean) from public;
revoke execute on function public.unirse_espera(text, uuid, text, text, text, text, boolean) from public;
grant execute on function public.perfil_publico(text) to anon, authenticated;
grant execute on function public.directorio(text, text, text) to anon, authenticated;
grant execute on function public.resena_info(uuid) to anon, authenticated;
grant execute on function public.dejar_resena(uuid, int, text, boolean) to anon, authenticated;
grant execute on function public.unirse_espera(text, uuid, text, text, text, text, boolean) to anon, authenticated;
grant execute on function public.invitar_resena(uuid) to authenticated;
