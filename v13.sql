-- =====================================================
-- CONSULTA LV · Actualización v13: historia clínica inalterable (Res. 1995 de 1999 y Res. 839 de 2017)
-- Las notas firmadas se pueden corregir solo durante 24 horas; después, solo con una nota aclaratoria.
-- Ninguna nota clínica se puede borrar. Términos del servicio aceptados por el profesional.
-- Pegar completo en Supabase > SQL Editor > Run (se puede repetir sin daño)
-- =====================================================
create schema if not exists privado;
create table if not exists privado.config (clave text primary key, valor text not null);

alter table public.notas_clinicas add column if not exists firmada_at timestamptz;
-- Las notas que ya existían quedan firmadas desde hoy (tienen 24 horas para correcciones). Solo se hace una vez.
do $$
begin
  if not exists (select 1 from privado.config where clave = 'v13_notas_firmadas') then
    update public.notas_clinicas set firmada_at = now() where firmada_at is null;
    insert into privado.config values ('v13_notas_firmadas', now()::text);
  end if;
end $$;

create or replace function public.proteger_nota() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Las notas de la historia clínica no se pueden borrar (Res. 1995 de 1999)';
  end if;
  if tg_op = 'INSERT' then
    if new.firmada_at is not null then new.firmada_at := now(); end if;
    return new;
  end if;
  if old.firmada_at is not null and old.firmada_at < now() - interval '24 hours' then
    raise exception 'Esta nota ya está firmada y no se puede modificar. Agrega una nota aclaratoria';
  end if;
  new.firmada_at := case when old.firmada_at is not null then old.firmada_at when new.firmada_at is not null then now() else null end;
  new.paciente_id := old.paciente_id;
  new.profesional_id := old.profesional_id;
  new.created_at := old.created_at;
  return new;
end $$;
drop trigger if exists trg_proteger_nota on public.notas_clinicas;
create trigger trg_proteger_nota before insert or update or delete on public.notas_clinicas for each row execute function public.proteger_nota();
revoke delete on public.notas_clinicas from authenticated, anon;

-- ---------- TÉRMINOS DEL SERVICIO ----------
alter table public.profesionales add column if not exists terminos_at timestamptz;
alter table public.profesionales add column if not exists terminos_version text not null default '';
