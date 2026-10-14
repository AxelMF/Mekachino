# Especificación — Plataforma de Gestión de Repuestos para Vehículos Chinos

> Documento de entrada para Claude Code. Describe QUÉ construir y CÓMO debe comportarse.
> Fuente de verdad del modelo de datos: `supabase/migrations/001_schema.sql`.
> Reglas de trabajo del repo: `CLAUDE.md`.

---

## 1. Contexto del negocio

- Empresa en República Dominicana que vende **repuestos para marcas chinas**: KYC, Changan, Shineray, Jetour, GAC, Jaecoo, Maxus, Hino y otras que se agreguen.
- Dos tipos de mercancía:
  1. **Piezas propias**: compradas (local o importación directa desde China). Son activo de la empresa.
  2. **Piezas a consignación**: pertenecen a un tercero (consignador). La empresa las exhibe y vende, y **gana un % de comisión sobre el precio de venta**. No son activo de la empresa.
- Canales de venta: mostrador/almacén, WhatsApp Business, Instagram, Facebook Marketplace. Algunas ventas incluyen **instalación** (servicio).
- Operación actual: almacén en casa, expansión a un punto de despacho. Pocos usuarios (1–5).
- Moneda funcional: **DOP**. Compras de importación en **USD** (u otra) con tasa de cambio registrada.
- Zona horaria: `America/Santo_Domingo`.
- Situación fiscal: **aún no factura formalmente**. La plataforma debe funcionar desde ya con recibos internos y quedar lista para activar comprobantes fiscales (ver §8).

## 2. Objetivos

1. Saber en todo momento qué hay, dónde está, cuánto costó y de quién es (propia vs. consignación).
2. Vender rápido (búsqueda por modelo/año/código OEM) y registrar cada venta una sola vez: inventario, caja, comisión del consignador y contabilidad se actualizan solos.
3. Liquidar a los consignadores sin hojas de cálculo: estado de cuenta claro, pagos y devoluciones.
4. Calcular el **costo real puesto en almacén** (landed cost) de cada importación y el margen real por pieza.
5. Contabilidad de partida doble generada automáticamente, con catálogo de cuentas y reportes al estilo dominicano (ITBIS, 606/607/608), revisable por un contador.

## 3. Stack y arquitectura

| Capa | Decisión |
|---|---|
| Base de datos / Auth / Storage | **Supabase** (Postgres 15+, Auth con email, Storage para fotos de piezas y documentos) |
| Lógica de negocio crítica | **Funciones Postgres (RPC, `plpgsql`, `SECURITY DEFINER` donde aplique)** — toda operación que toque inventario + dinero + asientos va en UNA transacción dentro de la BD |
| Frontend | SPA estática: **Vite + JavaScript (o TypeScript) sin framework pesado**, o React si el módulo lo justifica. Build → carpeta `dist/` |
| Despliegue | **Cloudflare Pages, carga directa de archivos estáticos** (ver gotchas en `CLAUDE.md`) |
| PDFs (recibos, facturas, estados de cuenta) | Generación en cliente (ej. `pdfmake` o `jspdf`) |
| Integración fiscal futura | Edge Function de Supabase que habla con un **proveedor autorizado de facturación electrónica** (adaptador, §8) |

Principios:
- **El frontend nunca calcula ni escribe asientos contables ni existencias directamente.** Llama RPCs (`registrar_venta`, `recibir_consignacion`, etc.). Las tablas transaccionales solo admiten `SELECT` vía RLS para usuarios normales; las escrituras pasan por funciones.
- Dinero siempre `numeric(14,2)`; cantidades `numeric(12,3)`; costos unitarios `numeric(14,4)`. Nunca `float`.
- Todo documento tiene número correlativo propio (`VTA-000123`, `REC-…`, `LIQ-…`), estado y auditoría (`created_by`, `created_at`).
- Nada se borra: se **anula** (estado `anulado` + asiento de reverso + movimiento inverso de inventario).

## 4. Roles y permisos

| Rol | Puede |
|---|---|
| `admin` | Todo, incluida configuración, catálogo de cuentas, cierre de períodos |
| `vendedor` | Buscar piezas, cotizar, vender, cobrar, abrir/cerrar caja propia |
| `almacen` | Recepciones (compras, consignación), transferencias, conteos, devoluciones a consignador |
| `contador` | Lectura total, asientos manuales, conciliaciones, reportes fiscales, cierre de período |

Implementar con tabla `perfiles(user_id, rol)` + función `rol_actual()` usada en políticas RLS.

## 5. Módulos

### 5.1 Catálogo de piezas
- **Marcas** (Changan, KYC, Shineray, Jetour…), **modelos** (con rango de años, motor, versión) y **categorías** (Motor, Frenos, Suspensión, Carrocería, Eléctrico, Filtros, etc.).
- **Pieza** (`productos`): SKU interno, descripción, número OEM, números alternos/equivalencias, marca de la pieza (genuina, OEM, aftermarket), unidad, foto(s), precio de venta sugerido, precio mínimo, `aplica_itbis` (bool), estado.
- **Compatibilidad** muchos-a-muchos pieza ↔ modelo/año. Búsqueda principal: "Changan CS35 2021 pastillas" → resultados.
- Una misma pieza (SKU) puede tener existencias **propias y de varios consignadores** a la vez; se distinguen por **lote de propiedad** (ver 5.2).

### 5.2 Inventario
- **Almacenes y ubicaciones** (ej. "Casa – Estante A3", "Local – Mostrador").
- **Lotes de existencia** (`lotes`): cada recepción crea un lote con `propiedad = 'propia' | 'consignacion'`, `consignador_id` (si aplica), `costo_unitario` (propias) o `precio_acordado` / `% comision` (consignación), almacén, cantidad disponible.
- **Kardex** (`movimientos_inventario`): toda entrada/salida/ajuste/transferencia queda registrada con documento origen. La existencia = suma de movimientos (con tabla/columna de saldo mantenida por la RPC para rendimiento).
- Costeo de piezas propias: **costo promedio ponderado por SKU** (estándar y aceptado en RD). Consignación no tiene costo para la empresa.
- Al vender un SKU con lotes propios y de consignación, el vendedor elige el lote (por defecto: FIFO dentro de la propiedad que tenga mejor margen; mostrar el origen claramente).
- Mínimos/máximos por SKU, alerta de reposición, **conteo físico** con ajuste (asiento de pérdida/sobrante), reporte de **inventario lento** (sin venta en X días).

### 5.3 Compras e importaciones
- **Proveedores** (locales y extranjeros; RNC, país, moneda, contacto, métodos de pago).
- **Orden de compra** → **recepción** (total o parcial) → genera lotes propios.
- **Liquidación de importación** (landed cost): una importación agrupa una o varias órdenes y registra:
  - FOB (moneda extranjera) × tasa de cambio
  - Flete internacional, seguro
  - Gravámenes/aranceles DGA
  - ITBIS pagado en aduana → **no es costo**, va a ITBIS adelantado (crédito fiscal) cuando la empresa sea formal; mientras sea informal, configurable para capitalizarlo al costo
  - Agente aduanal, transporte local, manejo y otros
  - **Prorrateo** de los gastos a cada línea por valor FOB (por defecto) o por peso/volumen
  - Resultado: costo unitario puesto en almacén por SKU → alimenta el costo promedio
- **Calculadora de precio**: a partir del costo puesto en almacén y un % de margen objetivo por categoría (ej. 30–50 % alta rotación; 60–100 % piezas escasas) sugiere precio de venta y muestra ganancia neta.

### 5.4 Consignación (comisión % sobre venta)
Flujo:
1. **Alta de consignador**: persona o empresa, cédula/RNC, teléfono, cuenta para pagos, `% comisión por defecto`, frecuencia de liquidación (semanal/quincenal/mensual), si es contribuyente formal o no.
2. **Recepción en consignación** (`REC-`): lista de piezas, cantidad, estado físico, fotos, **precio de venta pactado** (o precio mínimo), `% comisión` (hereda el default, editable por línea). Genera lotes `consignacion`. Imprime **acta de recepción** firmada.
3. **Venta**: al vender una línea de un lote en consignación, la RPC calcula:
   - `comision = precio_venta_neto × %`
   - `monto_consignador = precio_venta_neto − comision`
   - Crea una línea en `consignacion_cxp` (pendiente de liquidar).
4. **Liquidación** (`LIQ-`): por consignador y rango de fechas, agrupa ventas pendientes, muestra estado de cuenta (pieza, fecha, precio, comisión, neto), permite descuentos acordados (ej. reparaciones) y registra el **pago** (efectivo/transferencia). Genera PDF del estado de cuenta.
5. **Devolución al consignador**: piezas no vendidas regresan; movimiento de salida del lote, acta de devolución.
6. **Antigüedad**: alertas de piezas consignadas > N días sin vender (para devolver o renegociar precio).
- Las devoluciones de clientes sobre una pieza consignada revierten la línea en `consignacion_cxp` (si no está liquidada) o crean un cargo al consignador en la siguiente liquidación (si ya se liquidó).

**Tratamiento contable de la consignación** (configurable en `configuracion.modo_consignacion`; **validar con el contador antes de activar facturación formal**):
- **Modo A – `compra_venta` (por defecto):** la venta completa es ingreso de la empresa; el monto del consignador es el **costo de venta** (como si se le comprara la pieza en el momento de venderla). Margen bruto comparable con piezas propias. Cuando la empresa sea formal y el consignador sea persona física no contribuyente, ese costo se respalda con **comprobante de compras (tipo 41 / E41)**.
- **Modo B – `comision_neta`:** solo la comisión es ingreso; el monto del consignador es un pasivo puro (dinero de terceros).
- En ambos modos, la mercancía consignada **no** entra en el activo; se puede llevar en **cuentas de orden** (grupo 9) para control.

### 5.5 Ventas y punto de venta
- **Cotización** (convertible en venta), **venta** (contado / crédito), **canal** (mostrador, WhatsApp, Instagram, Marketplace, otro), cliente (opcional en contado; obligatorio en crédito).
- Líneas: pieza + lote + cantidad + precio + descuento; línea de **servicio** (instalación, mano de obra) sin inventario.
- ITBIS 18 % por línea según `aplica_itbis`; precios configurables como "ITBIS incluido" o "más ITBIS".
- **Pagos** múltiples por venta: efectivo, transferencia, tarjeta, otros. **Caja**: apertura, ventas, retiros, cierre con cuadre.
- **Devoluciones / notas de crédito** parciales o totales, con reingreso al lote original.
- Comprobante impreso/PDF/enlace para WhatsApp: recibo interno ahora; factura fiscal cuando se active §8.

### 5.6 Clientes y cuentas por cobrar
- Clientes (persona/empresa, cédula/RNC, teléfono, talleres mecánicos con precio especial), límite de crédito, plazo.
- Estado de cuenta, antigüedad de saldos (0–30, 31–60, 61–90, +90), registro de cobros.

### 5.7 Cuentas por pagar
- Facturas de proveedores, pagos, antigüedad. Los saldos a consignadores se ven aparte (módulo 5.4).

### 5.8 Caja y bancos
- Cuentas bancarias y cajas, depósitos, transferencias entre cuentas, **conciliación bancaria** simple (marcar movimientos conciliados contra extracto).

### 5.9 Contabilidad (partida doble)
- **Catálogo de cuentas** jerárquico estilo RD (sembrado en la migración): 1 Activos · 2 Pasivos · 3 Patrimonio · 4 Ingresos · 5 Costos · 6 Gastos · 9 Cuentas de orden. Editable por `admin`/`contador`; solo cuentas de detalle (`acepta_movimientos = true`) reciben asientos.
- **Asientos automáticos** generados por las RPCs (ver §6). Cada asiento referencia su documento origen. Validación en BD: débitos = créditos (trigger/constraint diferida).
- **Asientos manuales** (rol contador) para gastos, depreciación, ajustes.
- **Períodos** mensuales con estado `abierto` / `cerrado`; no se registra en períodos cerrados.
- **Gastos** operativos (alquiler, combustible, publicidad en redes, internet, etc.) con soporte (foto del recibo) y NCF del suplidor si lo tiene.
- Reportes: Libro diario, Libro mayor, **Balanza de comprobación**, **Estado de situación financiera**, **Estado de resultados**, todos por rango de fechas y exportables a Excel/PDF.

### 5.10 Impuestos y reportes fiscales (RD)
Se generan como **apoyo al contador**; la plataforma no presenta declaraciones.
- **ITBIS**: cobrado en ventas vs. adelantado en compras/importaciones → base para el **IT-1** mensual.
- **Formato 606** (compras de bienes y servicios), **607** (ventas), **608** (comprobantes anulados): exportación en el layout vigente de la DGII (el layout exacto se carga como configuración para poder actualizarlo sin redeploy).
- **Retenciones**: estructura para registrar retenciones de ISR/ITBIS a personas físicas cuando aplique (ej. pagos de servicios), con reporte base para **IR-17**. Reglas de cuándo retener: tabla configurable, definida con el contador.
- **Anticipos ISR** y base para la declaración anual (IR-1/IR-2): solo reportes de soporte (ingresos, costos, gastos por período).

### 5.11 Reportes y tablero
- Ventas por día/semana/mes, por canal, por marca de vehículo, por categoría.
- **Margen** por SKU, marca y tipo de propiedad (propia vs. comisión de consignación).
- Rotación de inventario, inventario lento, valor del inventario propio a costo.
- Pendiente a consignadores, CxC vencida, flujo de caja.
- Top piezas más buscadas sin existencia (registrar búsquedas sin resultado → inteligencia de compra).

### 5.12 Configuración y auditoría
- Datos de la empresa (nombre, RNC cuando exista, dirección, logo), tasa de ITBIS (18 %), modo de precios, `modo_consignacion`, `modo_fiscal` (`informal` | `ncf` | `ecf`), secuencias de documentos, días para alertas.
- **Bitácora de auditoría**: trigger genérico que registra cambios en tablas maestras y anulaciones (quién, cuándo, antes/después).

## 6. Asientos automáticos (reglas)

Códigos de cuenta de referencia según el catálogo sembrado (ajustables vía `configuracion_cuentas`, nunca hardcodeados en el frontend).

| Evento (RPC) | Débito | Crédito |
|---|---|---|
| Compra local de piezas propias | Inventario de mercancías (1.1.4.01); ITBIS adelantado (1.1.5.01) si formal | CxP proveedores (2.1.1.01) o Banco/Caja |
| Liquidación de importación | Inventario (1.1.4.01) por costo puesto en almacén; ITBIS pagado en aduana (1.1.5.01) | Banco / CxP proveedores / CxP agente aduanal |
| Venta pieza propia | Caja/Banco (1.1.1.x) o CxC (1.1.3.01) | Ventas de mercancías (4.1.1.01); ITBIS por pagar (2.1.3.01) |
| Costo de venta pieza propia | Costo de ventas (5.1.1.01) | Inventario (1.1.4.01) — a costo promedio |
| Venta pieza consignada — Modo A | Caja/Banco o CxC | Ventas mercancía consignada (4.1.1.02); ITBIS por pagar |
| Costo consignación — Modo A | Costo mercancía consignada (5.1.1.02) | CxP consignadores (2.1.1.03) |
| Venta pieza consignada — Modo B | Caja/Banco o CxC | CxP consignadores (monto consignador); Ingreso por comisiones (4.1.2.01); ITBIS por pagar (según criterio del contador) |
| Servicio de instalación | Caja/Banco o CxC | Ingresos por servicios (4.1.3.01); ITBIS por pagar |
| Liquidación pagada al consignador | CxP consignadores (2.1.1.03) | Caja/Banco |
| Cobro a cliente | Caja/Banco | CxC clientes |
| Devolución de cliente | Reverso proporcional de la venta y del costo | — |
| Ajuste de inventario (faltante) | Pérdida por faltante de inventario (6.1.9.01) | Inventario |
| Ajuste de inventario (sobrante) | Inventario | Otros ingresos (4.2.1.01) |
| Recepción/devolución en consignación (opcional) | Mercancía recibida en consignación (9.1.1.01) | Consignadores por mercancía recibida (9.2.1.01) — y su reverso |
| Anulación de cualquier documento | Asiento espejo con signos invertidos, misma fecha de anulación | — |

Mientras `modo_fiscal = 'informal'`, ITBIS se puede desactivar globalmente (precios sin ITBIS y sin cuentas de impuesto). Al cambiar a formal, las ventas nuevas aplican ITBIS; las históricas no se recalculan.

## 7. RPCs requeridas (contratos)

Todas: transacción única, validan rol, validan período abierto, devuelven el documento creado (`id`, `numero`, totales). Errores con `RAISE EXCEPTION` y mensajes en español.

- `registrar_recepcion_compra(p_orden_id, p_lineas jsonb)`
- `registrar_liquidacion_importacion(p_importacion_id, p_gastos jsonb, p_metodo_prorrateo text)`
- `registrar_recepcion_consignacion(p_consignador_id, p_lineas jsonb, p_notas text)`
- `devolver_a_consignador(p_consignador_id, p_lineas jsonb)`
- `registrar_venta(p_cliente_id, p_canal, p_lineas jsonb, p_pagos jsonb, p_tipo_pago text)` — líneas con `lote_id` o `servicio`; maneja costo promedio, `consignacion_cxp`, asientos, caja
- `registrar_devolucion_venta(p_venta_id, p_lineas jsonb)`
- `generar_liquidacion_consignador(p_consignador_id, p_desde, p_hasta)` → borrador
- `pagar_liquidacion(p_liquidacion_id, p_pagos jsonb)`
- `registrar_cobro(p_cliente_id, p_monto, p_aplicaciones jsonb, p_cuenta_id)`
- `registrar_ajuste_inventario(p_conteo_id)`
- `anular_documento(p_tipo text, p_id uuid, p_motivo text)`
- `abrir_caja(...)`, `cerrar_caja(...)`
- `cerrar_periodo(p_anio int, p_mes int)`
- Vistas: `v_existencias` (por SKU, lote, propiedad, almacén), `v_kardex`, `v_cxc_antiguedad`, `v_consignacion_pendiente`, `v_balanza`, `v_estado_resultados`, `v_balance_general`, `v_606`, `v_607`, `v_608`.

## 8. Facturación fiscal (activación futura)

Hechos verificados (oct-2026):
- La **Ley 32-23** obliga a todas las personas físicas y jurídicas que vendan bienes o servicios a usar **facturación electrónica (e-CF)**.
- Para **pequeños, micro y no clasificados** el plazo final fue prorrogado al **15 de noviembre de 2026** (Aviso DGII 06-26). Al formalizarse, la empresa entra directamente en e-CF; los NCF en papel (serie B) quedan solo como referencia histórica.
- La DGII tiene ~190 **proveedores autorizados** de facturación electrónica.

Diseño:
- `modo_fiscal = 'informal'` (hoy): recibo interno numerado, sin validez fiscal, claramente rotulado.
- `modo_fiscal = 'ecf'`: **no desarrollar emisión propia certificada ante DGII** (requiere certificación, firma digital y homologación). En su lugar, una **interfaz de adaptador** (`fiscal_provider`) implementada en una Edge Function que envía la venta al proveedor autorizado elegido (vía su API), recibe el **e-NCF**, código de seguridad, URL/QR de consulta y estado, y los guarda en `comprobantes_fiscales`.
- Tipos a soportar (catálogo configurable): 31 Crédito Fiscal, 32 Consumo, 33 Nota de Débito, 34 Nota de Crédito, 41 Compras, 43 Gastos Menores, 44 Regímenes Especiales, 45 Gubernamental (prefijo `E` en electrónico).
- Reglas: venta a cliente con RNC → 31; consumidor final → 32; devolución → 34 referenciando el comprobante original; pago a consignador/suplidor informal → 41.
- Manejo de estados: `pendiente`, `aceptado`, `aceptado_condicional`, `rechazado`; reintentos; la venta queda registrada aunque el envío falle (cola de reintento) — nunca bloquear la caja.

## 9. Pantallas (UI)

Diseño limpio, rápido, usable en **tablet y celular** (el almacén y la venta por WhatsApp pasan en el teléfono). Español. Atajos de teclado en el POS.

1. Login
2. Tablero (KPIs del día/mes, alertas: reposición, consignación vieja, CxC vencida)
3. POS / Nueva venta (buscador por modelo/año/OEM/descripción, carrito, selección de lote propio/consignado con badge visible, pagos)
4. Cotizaciones
5. Ventas (listado, detalle, devolución, anulación, reimpresión, enlace WhatsApp)
6. Catálogo (piezas, marcas, modelos, compatibilidades, fotos)
7. Inventario (existencias, kardex, transferencias, conteo físico)
8. Compras (proveedores, órdenes, recepciones, importaciones + liquidación)
9. Consignación (consignadores, recepciones, existencias por consignador, liquidaciones, devoluciones)
10. Clientes y CxC
11. CxP
12. Caja y bancos
13. Contabilidad (catálogo, asientos, períodos, gastos)
14. Reportes (financieros, fiscales 606/607/608, ventas/márgenes)
15. Configuración y usuarios

## 10. Plan de construcción por fases

Cada fase termina con: migración aplicada, RLS probada, RPCs con pruebas SQL (casos felices + errores), UI funcional y desplegada en Cloudflare Pages.

| Fase | Alcance | Criterio de aceptación |
|---|---|---|
| 0 | Repo, Vite, cliente Supabase, auth, roles, layout, despliegue | Login funciona en producción; cada rol ve su menú |
| 1 | Catálogo + inventario (lotes, kardex, almacenes, ajustes) | Crear pieza con compatibilidades; recibir stock propio; kardex cuadra con existencia |
| 2 | Consignación (consignadores, recepción, devolución) | Una pieza puede tener stock propio y de 2 consignadores a la vez y se ven separados |
| 3 | Ventas/POS + caja + clientes/CxC | Venta mixta (propia + consignada + instalación) genera kardex, `consignacion_cxp` y cobro en una sola transacción |
| 4 | Liquidación a consignadores | Estado de cuenta PDF cuadra con ventas; pago marca líneas liquidadas |
| 5 | Compras e importaciones con landed cost + calculadora de precio | Costo unitario prorrateado correcto (prueba con importación de ejemplo); costo promedio actualizado |
| 6 | Contabilidad automática + reportes financieros | Toda operación de fases 1–5 genera asiento balanceado; balanza cuadra; estados financieros correctos con datos de prueba |
| 7 | Impuestos (ITBIS, 606/607/608, retenciones base) | Exportes con layout DGII configurable; revisión del contador |
| 8 | Adaptador e-CF con proveedor autorizado | Venta de prueba obtiene e-NCF en ambiente de pruebas del proveedor |
| 9 | Extras: catálogo público/compartible por WhatsApp, registro de búsquedas sin resultado, alertas | — |

## 11. Datos semilla para pruebas
- Marcas: Changan, KYC, Shineray, Jetour, GAC, Jaecoo, Maxus, Hino.
- 10 modelos de ejemplo, 30 piezas comunes de desgaste/choque (pastillas, discos, filtros, amortiguadores, faros, bumpers, retrovisores, bombas de agua, correas, bujías).
- 2 consignadores (uno con 15 %, otro con 20 %), 3 clientes (1 taller), 1 proveedor local, 1 proveedor chino (USD).
- Una importación de ejemplo con 5 líneas y gastos para validar el prorrateo.

## 12. Fuera de alcance (por ahora)
Nómina, activos fijos con depreciación automática, multi-empresa, tienda en línea con pago, app nativa.

## 13. Pendientes a validar con el contador
1. `modo_consignacion` (A `compra_venta` vs. B `comision_neta`) y tratamiento del ITBIS en ventas consignadas.
2. Si el ITBIS de aduana se capitaliza al costo mientras la empresa sea informal.
3. Reglas de retención (ISR/ITBIS) a consignadores y suplidores personas físicas.
4. Catálogo de cuentas final y layout vigente de 606/607/608.
5. Proveedor autorizado de e-CF a contratar (antes del plazo del 15-nov-2026 si se formaliza).
