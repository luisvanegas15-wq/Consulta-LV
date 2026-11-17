-- =====================================================
-- CONSULTA LV · Actualización v14: índices para que la app siga rápida con muchos profesionales y pacientes
-- No cambia ni borra datos. Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
create index if not exists citas_prof_inicio on public.citas (profesional_id, inicio);
create index if not exists citas_paciente on public.citas (paciente_id, inicio desc);
create index if not exists citas_recordatorio on public.citas (inicio) where recordatorio_at is null and estado in ('pendiente', 'confirmada');
create index if not exists pacientes_prof_nombre on public.pacientes (profesional_id, nombres);
create index if not exists notas_paciente on public.notas_clinicas (paciente_id, fecha desc);
create index if not exists notas_prof on public.notas_clinicas (profesional_id);
create index if not exists escalas_paciente on public.escalas (paciente_id, fecha);
create index if not exists escalas_prof on public.escalas (profesional_id);
create index if not exists adjuntos_paciente on public.adjuntos (paciente_id);
create index if not exists adjuntos_prof on public.adjuntos (profesional_id);
create index if not exists documentos_paciente on public.documentos (paciente_id);
create index if not exists formularios_paciente on public.formularios (paciente_id, estado);
create index if not exists formularios_prof on public.formularios (profesional_id);
create index if not exists paquetes_prof on public.paquetes (profesional_id);
create index if not exists bloqueos_prof on public.bloqueos (profesional_id, inicio);
create index if not exists gastos_prof on public.gastos (profesional_id, fecha);
create index if not exists resenas_prof on public.resenas (profesional_id);
create index if not exists espera_prof on public.lista_espera (profesional_id);
create index if not exists habeas_prof on public.solicitudes_habeas (profesional_id);
create index if not exists renovaciones_prof on public.renovaciones (profesional_id);
create index if not exists auditoria_prof_fecha on public.auditoria (profesional_id, fecha desc);
create index if not exists profesionales_directorio on public.profesionales (en_directorio) where en_directorio;
analyze;
