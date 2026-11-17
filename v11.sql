-- =====================================================
-- CONSULTA LV · Actualización v11: medios de pago (Nequi, Daviplata, Bancolombia, otros bancos, Bre-B, PSE, efectivo)
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
alter table public.profesionales add column if not exists medios_pago jsonb not null default '{}'::jsonb;
alter table public.profesionales drop constraint if exists medios_pago_valido;
alter table public.profesionales add constraint medios_pago_valido
  check (jsonb_typeof(medios_pago) = 'object' and length(medios_pago::text) <= 3000);

create or replace function public.perfil_publico(p_slug text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'nombre', p.nombre, 'titulo', p.titulo, 'tarjeta', p.tarjeta_profesional, 'ciudad', p.ciudad,
    'bio', p.bio, 'foto', p.foto_url, 'direccion', p.direccion, 'whatsapp', p.whatsapp,
    'enfoque', p.enfoque, 'especialidades', p.especialidades, 'formacion', p.formacion,
    'experiencia', p.experiencia_anios, 'poblacion', p.poblacion, 'idiomas', p.idiomas,
    'nequi', p.nequi, 'datos_pago', p.datos_pago, 'enlace_pago', p.enlace_pago, 'color', p.color_marca, 'medios', p.medios_pago,
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
