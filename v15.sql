-- =====================================================
-- CONSULTA LV · Actualización v15: meta mensual de ingresos para el tablero de Finanzas
-- No cambia ni borra datos. Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
alter table public.profesionales add column if not exists meta_mensual bigint not null default 0;
alter table public.profesionales drop constraint if exists meta_mensual_rango;
alter table public.profesionales add constraint meta_mensual_rango check (meta_mensual >= 0 and meta_mensual <= 10000000000);
notify pgrst, 'reload schema';
