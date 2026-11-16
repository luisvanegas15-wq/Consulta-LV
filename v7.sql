-- =====================================================
-- CONSULTA LV · Actualización v7: banco de pruebas
-- Permite guardar PCL-5, AUDIT, Valoración de riesgo suicida y pruebas externas
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
alter table public.escalas drop constraint if exists escalas_tipo_check;
alter table public.escalas add constraint escalas_tipo_check
  check (tipo in ('PHQ-9', 'GAD-7', 'PCL-5', 'AUDIT', 'RIESGO', 'EXT'));
