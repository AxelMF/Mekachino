# CLAUDE.md — Plataforma de repuestos (vehículos chinos, RD)

Lee `SPEC.md` antes de cualquier tarea. El modelo de datos vive en `supabase/migrations/`.
Idioma de la UI, mensajes de error y comentarios de negocio: **español**.

## Estructura del repo
```
SPEC.md                         especificación funcional (fuente de verdad del negocio)
supabase/migrations/NNN_*.sql   migraciones numeradas; nunca editar una ya aplicada, crear una nueva
supabase/tests/*.sql            pruebas SQL por RPC (caso feliz + errores esperados)
supabase/functions/             Edge Functions (adaptador e-CF en fase 8)
web/                            frontend Vite → web/dist
```

## Reglas no negociables
1. **Escrituras transaccionales solo por RPC** (`plpgsql`, `security definer`, `set search_path = public`). El frontend nunca inserta en lotes, movimientos, ventas, asientos, cxp, etc.
2. Toda RPC: valida `rol_actual()`, valida período abierto, usa `siguiente_numero()`, hace todo en una transacción y devuelve `jsonb` con `id`, `numero` y totales. Errores con `raise exception` en español.
3. Cuentas contables: leerlas de `configuracion_cuentas` por `clave`; nunca códigos fijos en código.
4. Dinero `numeric(14,2)`, cantidades `numeric(12,3)`, costos `numeric(14,4)`. Redondear con `round(x, 2)` al final de cada línea, no en pasos intermedios.
5. Nada se borra: se anula con documento/asiento de reverso.
6. Cada RPC nueva va con su archivo en `supabase/tests/` y debe pasar antes de tocar la UI.
7. Avanzar **por fases** (SPEC §10). No empezar una fase sin cumplir el criterio de aceptación de la anterior.
8. Lo marcado en SPEC §13 como "validar con el contador" queda configurable, nunca fijo.

## Supabase — gotchas conocidos
- Verificar nombres reales de columnas antes de escribir queries: `select column_name from information_schema.columns where table_schema='public' and table_name='X'`.
- RLS: **una política por operación** (select/insert/update/delete). **No usar `CREATE POLICY IF NOT EXISTS`** (falla); usar `drop policy if exists` + `create policy`.
- Vistas: `create or replace view` + `alter view ... set (security_invoker = on)` + `grant select on <vista> to authenticated`.
- `auth.uid()` en Supabase es nativo; la migración 001 solo lo emula si no existe (para pruebas en Postgres local).
- En Postgres local, otorgar `grant usage on schema public to authenticated; grant select on all tables in schema public to authenticated;` para probar RLS (Supabase ya lo hace).
- Nunca exponer la `service_role` key en el frontend; solo la publishable/anon key.
- Si aparece error de verificación JWT: revisar que el cliente use la URL y la key del mismo proyecto y que la sesión se refresque (`supabase.auth.onAuthStateChange`).

## Cloudflare Pages — gotchas conocidos
- Desplegar con **Pages → Upload static files** del contenido de `web/dist`.
- **No** crear `wrangler.toml` con `[assets] directory = "."` (activa modo Worker con CSP estricta que bloquea scripts inline).
- **No** crear `_redirects` con `/* /index.html 200` (bucle, error 100324). Usar enrutado por hash (`#/ventas`) en la SPA.
- Preferir scripts como módulos empaquetados por Vite, no inline.

## JavaScript
- Cuidado con `async async function` (SyntaxError silencioso que tumba todo el script). Correr `npm run build` y revisar consola tras cada cambio.
- Un solo wrapper de llamadas a Supabase (`api.rpc(nombre, params)` / `api.select(...)`) con try/catch y toast de error en español.

## Comandos
```
supabase start                    # stack local
supabase db reset                 # aplica todas las migraciones desde cero
psql "$DB_URL" -f supabase/tests/<archivo>.sql
cd web && npm run dev | npm run build
```

## Definición de "terminado" por tarea
Migración aplicada desde cero sin errores · pruebas SQL pasan · asientos generados cuadran (`v_balanza`) · UI probada en ancho de celular · sin errores en consola · commit con mensaje descriptivo.
