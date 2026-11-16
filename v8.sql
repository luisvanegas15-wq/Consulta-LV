-- =====================================================
-- CONSULTA LV · Actualización v8
-- Verificación en dos pasos (también exigida por el servidor), color de marca,
-- contrato de encargado del tratamiento y bienvenida inicial
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
alter table public.profesionales add column if not exists color_marca text not null default '#0e7490';
alter table public.profesionales add column if not exists contrato_encargado_at timestamptz;
alter table public.profesionales add column if not exists bienvenida_vista boolean not null default false;
alter table public.profesionales drop constraint if exists color_valido;
alter table public.profesionales add constraint color_valido check (color_marca ~ '^#[0-9a-fA-F]{6}$');

-- Si el profesional activó la verificación en dos pasos, el servidor exige que la sesión la haya superado
create or replace function public.mfa_ok() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
      or not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified');
$$;
revoke execute on function public.mfa_ok() from public, anon;
grant execute on function public.mfa_ok() to authenticated;

do $$
declare t text;
begin
  foreach t in array array['pacientes','citas','notas_clinicas','escalas','adjuntos','llaves','solicitudes_habeas','lista_espera','gastos','plantillas','resenas'] loop
    execute format('drop policy if exists mfa_exigido on public.%I', t);
    execute format('create policy mfa_exigido on public.%I as restrictive for all to authenticated using (public.mfa_ok()) with check (public.mfa_ok())', t);
  end loop;
end $$;

drop policy if exists adj_mfa on storage.objects;
create policy adj_mfa on storage.objects as restrictive for all to authenticated
  using (bucket_id <> 'adjuntos' or public.mfa_ok()) with check (bucket_id <> 'adjuntos' or public.mfa_ok());

-- Perfil público con el color de marca
create or replace function public.perfil_publico(p_slug text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'nombre', p.nombre, 'titulo', p.titulo, 'tarjeta', p.tarjeta_profesional, 'ciudad', p.ciudad,
    'bio', p.bio, 'foto', p.foto_url, 'direccion', p.direccion, 'whatsapp', p.whatsapp,
    'enfoque', p.enfoque, 'especialidades', p.especialidades, 'formacion', p.formacion,
    'experiencia', p.experiencia_anios, 'poblacion', p.poblacion, 'idiomas', p.idiomas,
    'nequi', p.nequi, 'datos_pago', p.datos_pago, 'enlace_pago', p.enlace_pago, 'color', p.color_marca,
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
revoke execute on function public.perfil_publico(text) from public;
grant execute on function public.perfil_publico(text) to anon, authenticated;
