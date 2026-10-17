-- A partir de aquí, las funciones nuevas en public ya NO se otorgan a
-- `anon` por defecto (seguían el patrón estándar de Supabase, que abre
-- EXECUTE a anon en toda rutina nueva salvo que se revoque a mano).
-- Cada RPC deberá otorgar explícitamente a `authenticated` tras crearla.
alter default privileges in schema public revoke execute on routines from anon;
