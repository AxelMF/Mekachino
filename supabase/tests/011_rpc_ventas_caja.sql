-- Pruebas manuales de 011_rpc_ventas_caja.sql
-- Simula auth.uid() con set_config('request.jwt.claim.sub', ...).
-- Ejecutar paso a paso contra una base con datos de catálogo/inventario
-- ya creados (ver pruebas de 003 y 010).

-- 1) Abrir caja
select set_config('request.jwt.claim.sub', (select user_id::text from perfiles where rol = 'admin' limit 1), false);
select abrir_caja((select id from cuentas_financieras where tipo = 'caja' limit 1), 2000);
-- Esperado: numero CAJ-xxxxxx, monto_apertura 2000

-- 2) Error: abrir una segunda caja para el mismo usuario
select abrir_caja((select id from cuentas_financieras where tipo = 'caja' limit 1), 0);
-- Esperado: ERROR  Ya tiene una sesión de caja abierta

-- 3) Venta mixta (propia + consignación) contado, pagada completa
-- (sustituir los uuids de producto_id/lote_id/cuenta_id por los reales del entorno)
-- select registrar_venta(null, 'mostrador',
--   jsonb_build_array(
--     jsonb_build_object('producto_id','<propia>','lote_id','<lote propia>','cantidad',2,'precio_unitario',1200),
--     jsonb_build_object('producto_id','<consig>','lote_id','<lote consignacion>','cantidad',1,'precio_unitario',1200)
--   ),
--   jsonb_build_array(jsonb_build_object('cuenta_id','<caja>','metodo','efectivo','monto',3600)),
--   'contado'
-- );
-- Verificar: lotes descontados, movimientos_inventario con costo_unitario solo en la línea propia,
-- consignacion_cxp creado para la línea de consignación (comision + monto_consignador = precio_venta_neto),
-- ventas_pagos + movimientos_financieros con sesion_id = la caja abierta.

-- 4) Error: vender sin caja abierta (en otra sesión / otro usuario)
-- 5) Error: cantidad mayor a la disponible en el lote
-- 6) Venta a crédito sin pagos -> saldo = total; registrar_cobro parcial -> saldo disminuye
-- 7) cerrar_caja: monto_esperado = apertura + sum(movimientos_financieros); diferencia = contado - esperado

-- Limpieza: anular o eliminar manualmente los registros de prueba creados
-- (ventas, ventas_lineas, ventas_pagos, movimientos_financieros, consignacion_cxp,
-- cobros, cobros_aplicaciones, sesiones_caja) si se usó contra un entorno compartido.
