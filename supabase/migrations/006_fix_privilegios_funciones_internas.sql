-- =====================================================================
-- 006_fix_privilegios_funciones_internas.sql
-- 000_reset_public_schema otorgó `alter default privileges ... grant all
-- on routines to anon, authenticated` (estándar de un proyecto Supabase
-- nuevo). Eso es un GRANT explícito a `anon`, independiente de PUBLIC:
-- `revoke ... from public` (002) no lo quita. Cada `create or replace
-- function` vuelve a aplicar los privilegios por defecto, reabriendo el
-- hueco. Aquí se revoca explícitamente de `anon` (y de paso `public`)
-- para las funciones de uso interno, dejando solo `authenticated`.
-- =====================================================================

revoke execute on function siguiente_numero(text) from public, anon;
revoke execute on function trg_auditar() from public, anon;
revoke execute on function recibir_stock_propio(uuid, uuid, numeric, numeric, uuid, text) from public, anon;
revoke execute on function crear_conteo_fisico(uuid, text) from public, anon;
revoke execute on function actualizar_conteo_linea(uuid, numeric) from public, anon;
revoke execute on function registrar_ajuste_inventario(uuid) from public, anon;

grant execute on function siguiente_numero(text) to authenticated;
grant execute on function trg_auditar() to authenticated;
grant execute on function recibir_stock_propio(uuid, uuid, numeric, numeric, uuid, text) to authenticated;
grant execute on function crear_conteo_fisico(uuid, text) to authenticated;
grant execute on function actualizar_conteo_linea(uuid, numeric) to authenticated;
grant execute on function registrar_ajuste_inventario(uuid) to authenticated;
