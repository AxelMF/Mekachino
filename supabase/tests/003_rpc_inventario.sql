-- Pruebas manuales de 003_rpc_inventario.sql
-- Simula auth.uid() con set_config('request.jwt.claim.sub', ...) ya que
-- auth.uid() lee esa variable de sesión (ver emulación en 001_schema.sql).

-- 1) Caso feliz: admin recibe stock propio, costo promedio se actualiza
select set_config('request.jwt.claim.sub', (select user_id::text from perfiles where rol = 'admin' limit 1), false);

with p as (
  insert into productos (sku, descripcion, precio_venta, precio_minimo)
  values ('TEST-SKU-001', 'Pastilla de freno de prueba', 1000, 600)
  returning id
), a as (
  select id from almacenes where nombre = 'Almacén principal'
)
select recibir_stock_propio(p.id, a.id, 10, 500) as recepcion_1
from p, a;
-- Esperado: costo_promedio_nuevo = 500 (stock inicial 0)

select p.sku, p.costo_promedio, l.cantidad_disponible, l.costo_unitario
from productos p join lotes l on l.producto_id = p.id
where p.sku = 'TEST-SKU-001';
-- Esperado: costo_promedio = 500.0000, cantidad_disponible = 10

-- Segunda recepción a costo distinto -> promedio ponderado
with p as (select id from productos where sku = 'TEST-SKU-001'),
     a as (select id from almacenes where nombre = 'Almacén principal')
select recibir_stock_propio(p.id, a.id, 10, 700) as recepcion_2
from p, a;
-- Esperado: costo_promedio_nuevo = (10*500 + 10*700)/20 = 600

select costo_promedio from productos where sku = 'TEST-SKU-001';
-- Esperado: 600.0000

-- 2) Error: cantidad <= 0
with p as (select id from productos where sku = 'TEST-SKU-001'),
     a as (select id from almacenes where nombre = 'Almacén principal')
select recibir_stock_propio(p.id, a.id, 0, 500) from p, a;
-- Esperado: ERROR  La cantidad debe ser mayor a cero

-- 3) Error: rol sin permiso (vendedor)
select set_config('request.jwt.claim.sub', (select user_id::text from perfiles where rol = 'vendedor' limit 1), false);
with p as (select id from productos where sku = 'TEST-SKU-001'),
     a as (select id from almacenes where nombre = 'Almacén principal')
select recibir_stock_propio(p.id, a.id, 5, 500) from p, a;
-- Esperado: ERROR  No tiene permiso para recibir inventario (si no hay usuario vendedor de prueba, omitir)

-- 4) Conteo físico: crear, capturar diferencia, confirmar ajuste
select set_config('request.jwt.claim.sub', (select user_id::text from perfiles where rol = 'admin' limit 1), false);

select crear_conteo_fisico(id, 'Conteo de prueba') as conteo
from almacenes where nombre = 'Almacén principal';

-- (tomar el id devuelto arriba para las siguientes dos consultas)
-- select actualizar_conteo_linea('<linea_id>', 8);          -- simula faltante de 2
-- select registrar_ajuste_inventario('<conteo_id>');        -- aplica el ajuste

-- 5) Kardex cuadra con existencia (criterio de aceptación Fase 1)
select p.sku,
       (select cantidad_disponible from lotes where producto_id = p.id) as existencia_lote,
       (select sum(cantidad) from movimientos_inventario where producto_id = p.id) as suma_kardex
from productos p where p.sku = 'TEST-SKU-001';
-- Esperado: existencia_lote = suma_kardex (antes del ajuste)

-- Limpieza de datos de prueba
delete from movimientos_inventario where producto_id in (select id from productos where sku = 'TEST-SKU-001');
delete from conteos_fisicos_lineas where lote_id in (select id from lotes where producto_id in (select id from productos where sku = 'TEST-SKU-001'));
delete from lotes where producto_id in (select id from productos where sku = 'TEST-SKU-001');
delete from productos where sku = 'TEST-SKU-001';
