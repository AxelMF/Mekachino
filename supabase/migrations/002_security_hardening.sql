-- Fija search_path en funciones de trigger (evita search_path mutable)
alter function trg_validar_asiento() set search_path = public;
alter function trg_validar_linea_asiento() set search_path = public;
alter function trg_validar_periodo() set search_path = public;

-- trg_auditar y siguiente_numero son de uso interno (triggers / RPCs futuras);
-- no deben ser invocables directamente por anon/authenticated vía REST.
revoke execute on function trg_auditar() from public;
revoke execute on function siguiente_numero(text) from public;
