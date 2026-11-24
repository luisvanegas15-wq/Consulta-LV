-- =====================================================
-- CONSULTA LV · Actualización v16: medidor de capacidad del servidor (solo administrador)
-- Muestra espacio usado de base de datos y archivos, y conteos generales. No cambia ni borra datos.
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
create or replace function public.admin_capacidad() returns json
language plpgsql stable security definer set search_path = public, privado, storage as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  return json_build_object(
    'db_bytes', pg_database_size(current_database()),
    'archivos_bytes', (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects),
    'archivos', (select count(*) from storage.objects),
    'plan', coalesce((select valor from privado.config where clave = 'plan_supabase'), 'free'),
    'profesionales', (select count(*) from public.profesionales),
    'pacientes', (select count(*) from public.pacientes),
    'citas', (select count(*) from public.citas),
    'notas', (select count(*) from public.notas_clinicas),
    'tablas', coalesce((select json_agg(x order by x.bytes desc) from (
        select c.relname tabla, pg_total_relation_size(c.oid) bytes
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r' order by 2 desc limit 6) x), '[]'::json),
    'top_archivos', coalesce((select json_agg(x order by x.bytes desc) from (
        select p.nombre, p.email, sum((o.metadata->>'size')::bigint) bytes, count(*) n
        from storage.objects o join public.profesionales p on p.id::text = split_part(o.name, '/', 1)
        group by p.nombre, p.email order by 3 desc limit 5) x), '[]'::json));
end $$;
create or replace function public.admin_plan(p_plan text) returns text
language plpgsql security definer set search_path = public, privado as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  if p_plan not in ('free', 'pro') then raise exception 'Plan no válido'; end if;
  insert into privado.config values ('plan_supabase', p_plan) on conflict (clave) do update set valor = excluded.valor;
  return p_plan;
end $$;
revoke execute on function public.admin_capacidad() from public, anon;
revoke execute on function public.admin_plan(text) from public, anon;
grant execute on function public.admin_capacidad() to authenticated;
grant execute on function public.admin_plan(text) to authenticated;
notify pgrst, 'reload schema';
