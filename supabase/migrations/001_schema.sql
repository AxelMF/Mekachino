-- =====================================================================
-- 001_schema.sql — Plataforma de repuestos (vehículos chinos) — RD
-- Esquema base: maestros, inventario por lotes (propia/consignación),
-- compras/importaciones, ventas, consignación, caja, contabilidad,
-- fiscal, auditoría. RLS de lectura incluida. Las RPC de escritura
-- se implementan en migraciones posteriores (ver SPEC.md §7).
-- Idempotente donde es posible. Postgres 15+ / Supabase.
-- =====================================================================

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------
do $$ begin
  create type rol_usuario      as enum ('admin','vendedor','almacen','contador');
  create type tipo_propiedad   as enum ('propia','consignacion');
  create type estado_doc       as enum ('borrador','confirmado','anulado');
  create type tipo_movimiento  as enum ('entrada_compra','entrada_consignacion','entrada_devolucion_cliente',
                                        'salida_venta','salida_devolucion_consignador','salida_devolucion_proveedor',
                                        'ajuste_positivo','ajuste_negativo','transferencia_salida','transferencia_entrada');
  create type canal_venta      as enum ('mostrador','whatsapp','instagram','marketplace','otro');
  create type metodo_pago      as enum ('efectivo','transferencia','tarjeta','cheque','otro');
  create type naturaleza_cta   as enum ('deudora','acreedora');
  create type tipo_cta         as enum ('activo','pasivo','patrimonio','ingreso','costo','gasto','orden');
  create type estado_ecf       as enum ('no_aplica','pendiente','aceptado','aceptado_condicional','rechazado');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Seguridad: perfiles y rol actual
-- ---------------------------------------------------------------------
create table if not exists perfiles (
  user_id     uuid primary key,              -- = auth.users.id
  nombre      text not null,
  rol         rol_usuario not null default 'vendedor',
  activo      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- Supabase expone auth.uid(); en Postgres local se emula si no existe.
do $$ begin
  if not exists (select 1 from pg_namespace where nspname = 'auth') then
    execute 'create schema auth';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'auth' and p.proname = 'uid') then
    execute $f$create function auth.uid() returns uuid language sql stable as
      $b$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $b$ $f$;
  end if;
end $$;

create or replace function rol_actual() returns rol_usuario
language sql stable security definer set search_path = public as $$
  select rol from perfiles where user_id = auth.uid() and activo
$$;

-- ---------------------------------------------------------------------
-- Configuración
-- ---------------------------------------------------------------------
create table if not exists configuracion (
  id                    smallint primary key default 1 check (id = 1),
  nombre_empresa        text not null default 'Mi Empresa de Repuestos',
  rnc                   text,
  direccion             text,
  telefono              text,
  logo_url              text,
  moneda                char(3) not null default 'DOP',
  tasa_itbis            numeric(5,2) not null default 18.00,
  precios_incluyen_itbis boolean not null default true,
  modo_fiscal           text not null default 'informal' check (modo_fiscal in ('informal','ncf','ecf')),
  modo_consignacion     text not null default 'compra_venta' check (modo_consignacion in ('compra_venta','comision_neta')),
  capitalizar_itbis_aduana boolean not null default true,  -- mientras sea informal
  dias_alerta_consignacion int not null default 90,
  dias_inventario_lento int not null default 120,
  updated_at            timestamptz not null default now()
);
insert into configuracion (id) values (1) on conflict do nothing;

-- Secuencias de documentos (VTA, REC, LIQ, COT, OC, IMP, DEV, AJU, COB, PAG, AS)
create table if not exists secuencias_documento (
  prefijo   text primary key,
  siguiente bigint not null default 1,
  relleno   int not null default 6
);
insert into secuencias_documento (prefijo) values
  ('VTA'),('COT'),('REC'),('DVC'),('LIQ'),('OC'),('RCP'),('IMP'),('DEV'),('AJU'),('COB'),('PAG'),('AS'),('CAJ')
on conflict do nothing;

create or replace function siguiente_numero(p_prefijo text) returns text
language plpgsql security definer set search_path = public as $$
declare v bigint; r int;
begin
  update secuencias_documento set siguiente = siguiente + 1
   where prefijo = p_prefijo returning siguiente - 1, relleno into v, r;
  if v is null then raise exception 'Prefijo de documento desconocido: %', p_prefijo; end if;
  return p_prefijo || '-' || lpad(v::text, r, '0');
end $$;

-- ---------------------------------------------------------------------
-- Catálogo
-- ---------------------------------------------------------------------
create table if not exists marcas_vehiculo (
  id      uuid primary key default gen_random_uuid(),
  nombre  text not null unique,
  activo  boolean not null default true
);

create table if not exists modelos_vehiculo (
  id          uuid primary key default gen_random_uuid(),
  marca_id    uuid not null references marcas_vehiculo(id),
  nombre      text not null,
  anio_desde  int,
  anio_hasta  int,
  motor       text,
  version     text,
  activo      boolean not null default true,
  unique (marca_id, nombre, version)
);

create table if not exists categorias (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null unique,
  padre_id  uuid references categorias(id),
  margen_objetivo_pct numeric(6,2)       -- usado por la calculadora de precio
);

create table if not exists productos (
  id                 uuid primary key default gen_random_uuid(),
  sku                text not null unique,
  descripcion        text not null,
  numero_oem         text,
  numeros_alternos   text[] not null default '{}',
  categoria_id       uuid references categorias(id),
  calidad            text check (calidad in ('genuina','oem','aftermarket','usada')),
  marca_pieza        text,
  unidad             text not null default 'UND',
  precio_venta       numeric(14,2) not null default 0 check (precio_venta >= 0),
  precio_minimo      numeric(14,2) not null default 0 check (precio_minimo >= 0),
  aplica_itbis       boolean not null default true,
  es_servicio        boolean not null default false,   -- instalación / mano de obra
  stock_minimo       numeric(12,3) not null default 0,
  stock_maximo       numeric(12,3),
  costo_promedio     numeric(14,4) not null default 0, -- solo existencias propias
  fotos              text[] not null default '{}',
  activo             boolean not null default true,
  created_at         timestamptz not null default now(),
  created_by         uuid
);
create index if not exists productos_desc_trgm on productos using gin (descripcion gin_trgm_ops);
create index if not exists productos_oem_idx   on productos (numero_oem);

create table if not exists compatibilidades (
  producto_id  uuid not null references productos(id) on delete cascade,
  modelo_id    uuid not null references modelos_vehiculo(id),
  anio_desde   int,
  anio_hasta   int,
  notas        text,
  primary key (producto_id, modelo_id)
);

create table if not exists busquedas_sin_resultado (
  id         bigserial primary key,
  texto      text not null,
  usuario    uuid,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Terceros
-- ---------------------------------------------------------------------
create table if not exists clientes (
  id              uuid primary key default gen_random_uuid(),
  nombre          text not null,
  tipo_doc        text check (tipo_doc in ('cedula','rnc','pasaporte')),
  documento       text,
  telefono        text,
  email           text,
  direccion       text,
  es_taller       boolean not null default false,
  descuento_pct   numeric(5,2) not null default 0,
  limite_credito  numeric(14,2) not null default 0,
  dias_credito    int not null default 0,
  activo          boolean not null default true,
  created_at      timestamptz not null default now()
);

create table if not exists proveedores (
  id           uuid primary key default gen_random_uuid(),
  nombre       text not null,
  rnc          text,
  pais         text not null default 'DO',
  moneda       char(3) not null default 'DOP',
  contacto     text,
  telefono     text,
  email        text,
  notas        text,
  activo       boolean not null default true,
  created_at   timestamptz not null default now()
);

create table if not exists consignadores (
  id                     uuid primary key default gen_random_uuid(),
  nombre                 text not null,
  tipo_doc               text check (tipo_doc in ('cedula','rnc','pasaporte')),
  documento              text,
  telefono               text,
  email                  text,
  datos_pago             text,          -- banco / cuenta (texto libre)
  comision_pct_default   numeric(5,2) not null check (comision_pct_default between 0 and 100),
  frecuencia_liquidacion text not null default 'quincenal' check (frecuencia_liquidacion in ('semanal','quincenal','mensual')),
  es_contribuyente       boolean not null default false,
  activo                 boolean not null default true,
  created_at             timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Almacenes e inventario por lotes
-- ---------------------------------------------------------------------
create table if not exists almacenes (
  id      uuid primary key default gen_random_uuid(),
  nombre  text not null unique,
  activo  boolean not null default true
);

create table if not exists ubicaciones (
  id          uuid primary key default gen_random_uuid(),
  almacen_id  uuid not null references almacenes(id),
  codigo      text not null,
  unique (almacen_id, codigo)
);

create table if not exists lotes (
  id                 uuid primary key default gen_random_uuid(),
  producto_id        uuid not null references productos(id),
  almacen_id         uuid not null references almacenes(id),
  ubicacion_id       uuid references ubicaciones(id),
  propiedad          tipo_propiedad not null,
  consignador_id     uuid references consignadores(id),
  costo_unitario     numeric(14,4),            -- propia: costo de entrada
  precio_pactado     numeric(14,2),            -- consignación: precio de venta acordado
  comision_pct       numeric(5,2),             -- consignación
  cantidad_inicial   numeric(12,3) not null check (cantidad_inicial > 0),
  cantidad_disponible numeric(12,3) not null check (cantidad_disponible >= 0),
  estado_fisico      text,
  doc_origen_tipo    text not null,            -- 'recepcion_compra' | 'recepcion_consignacion' | 'ajuste' ...
  doc_origen_id      uuid not null,
  fecha_entrada      date not null default current_date,
  created_at         timestamptz not null default now(),
  constraint lote_propiedad_ok check (
    (propiedad = 'propia'       and consignador_id is null     and costo_unitario is not null) or
    (propiedad = 'consignacion' and consignador_id is not null and comision_pct is not null)
  )
);
create index if not exists lotes_producto_idx on lotes (producto_id) where cantidad_disponible > 0;
create index if not exists lotes_consignador_idx on lotes (consignador_id) where consignador_id is not null;

create table if not exists movimientos_inventario (
  id               bigserial primary key,
  fecha            timestamptz not null default now(),
  lote_id          uuid not null references lotes(id),
  producto_id      uuid not null references productos(id),
  almacen_id       uuid not null references almacenes(id),
  tipo             tipo_movimiento not null,
  cantidad         numeric(12,3) not null check (cantidad <> 0),  -- + entrada / − salida
  costo_unitario   numeric(14,4),     -- costo aplicado (propia) para el kardex valorizado
  doc_tipo         text not null,
  doc_id           uuid not null,
  usuario          uuid,
  notas            text
);
create index if not exists mov_producto_fecha_idx on movimientos_inventario (producto_id, fecha);

create table if not exists conteos_fisicos (
  id          uuid primary key default gen_random_uuid(),
  numero      text not null unique,
  almacen_id  uuid not null references almacenes(id),
  fecha       date not null default current_date,
  estado      estado_doc not null default 'borrador',
  notas       text,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create table if not exists conteos_fisicos_lineas (
  id               uuid primary key default gen_random_uuid(),
  conteo_id        uuid not null references conteos_fisicos(id) on delete cascade,
  lote_id          uuid not null references lotes(id),
  cantidad_sistema numeric(12,3) not null,
  cantidad_contada numeric(12,3) not null check (cantidad_contada >= 0)
);

-- ---------------------------------------------------------------------
-- Compras e importaciones
-- ---------------------------------------------------------------------
create table if not exists ordenes_compra (
  id             uuid primary key default gen_random_uuid(),
  numero         text not null unique,
  proveedor_id   uuid not null references proveedores(id),
  fecha          date not null default current_date,
  moneda         char(3) not null default 'DOP',
  tasa_cambio    numeric(12,4) not null default 1 check (tasa_cambio > 0),
  importacion_id uuid,
  estado         text not null default 'borrador' check (estado in ('borrador','enviada','parcial','recibida','anulada')),
  notas          text,
  created_by     uuid,
  created_at     timestamptz not null default now()
);
create table if not exists ordenes_compra_lineas (
  id                uuid primary key default gen_random_uuid(),
  orden_id          uuid not null references ordenes_compra(id) on delete cascade,
  producto_id       uuid not null references productos(id),
  cantidad          numeric(12,3) not null check (cantidad > 0),
  precio_unitario   numeric(14,4) not null check (precio_unitario >= 0), -- en moneda de la orden (FOB si importación)
  peso_kg           numeric(12,3),
  cantidad_recibida numeric(12,3) not null default 0
);

create table if not exists importaciones (
  id                 uuid primary key default gen_random_uuid(),
  numero             text not null unique,
  descripcion        text,
  fecha_llegada      date,
  tasa_cambio        numeric(12,4) not null check (tasa_cambio > 0),
  metodo_prorrateo   text not null default 'valor' check (metodo_prorrateo in ('valor','peso','cantidad')),
  estado             estado_doc not null default 'borrador',
  created_by         uuid,
  created_at         timestamptz not null default now()
);
alter table ordenes_compra drop constraint if exists ordenes_compra_importacion_fk;
alter table ordenes_compra add constraint ordenes_compra_importacion_fk
  foreign key (importacion_id) references importaciones(id);

create table if not exists importaciones_gastos (
  id               uuid primary key default gen_random_uuid(),
  importacion_id   uuid not null references importaciones(id) on delete cascade,
  concepto         text not null check (concepto in ('flete','seguro','arancel','itbis_aduana','agente_aduanal',
                                                     'transporte_local','manejo','otro')),
  proveedor_id     uuid references proveedores(id),
  moneda           char(3) not null default 'DOP',
  monto            numeric(14,2) not null check (monto >= 0),
  tasa_cambio      numeric(12,4) not null default 1,
  ncf              text,
  es_costo         boolean not null default true   -- itbis_aduana = false cuando la empresa es formal
);

create table if not exists recepciones_compra (
  id           uuid primary key default gen_random_uuid(),
  numero       text not null unique,
  orden_id     uuid not null references ordenes_compra(id),
  almacen_id   uuid not null references almacenes(id),
  fecha        date not null default current_date,
  estado       estado_doc not null default 'confirmado',
  created_by   uuid,
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Consignación
-- ---------------------------------------------------------------------
create table if not exists recepciones_consignacion (
  id              uuid primary key default gen_random_uuid(),
  numero          text not null unique,
  consignador_id  uuid not null references consignadores(id),
  almacen_id      uuid not null references almacenes(id),
  fecha           date not null default current_date,
  estado          estado_doc not null default 'confirmado',
  notas           text,
  created_by      uuid,
  created_at      timestamptz not null default now()
);

create table if not exists devoluciones_consignador (
  id              uuid primary key default gen_random_uuid(),
  numero          text not null unique,
  consignador_id  uuid not null references consignadores(id),
  fecha           date not null default current_date,
  estado          estado_doc not null default 'confirmado',
  notas           text,
  created_by      uuid,
  created_at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Caja y bancos
-- ---------------------------------------------------------------------
create table if not exists cuentas_contables (
  id                 uuid primary key default gen_random_uuid(),
  codigo             text not null unique,
  nombre             text not null,
  tipo               tipo_cta not null,
  naturaleza         naturaleza_cta not null,
  padre_codigo       text references cuentas_contables(codigo),
  acepta_movimientos boolean not null default false,
  activo             boolean not null default true
);

create table if not exists cuentas_financieras (   -- cajas y bancos
  id                 uuid primary key default gen_random_uuid(),
  nombre             text not null unique,
  tipo               text not null check (tipo in ('caja','banco')),
  banco              text,
  numero_ref         text,                       -- últimos dígitos, nunca el número completo
  moneda             char(3) not null default 'DOP',
  cuenta_contable_id uuid not null references cuentas_contables(id),
  activo             boolean not null default true
);

create table if not exists sesiones_caja (
  id                 uuid primary key default gen_random_uuid(),
  numero             text not null unique,
  cuenta_id          uuid not null references cuentas_financieras(id),
  usuario            uuid not null,
  apertura           timestamptz not null default now(),
  monto_apertura     numeric(14,2) not null default 0,
  cierre             timestamptz,
  monto_contado      numeric(14,2),
  monto_esperado     numeric(14,2),
  diferencia         numeric(14,2),
  estado             text not null default 'abierta' check (estado in ('abierta','cerrada'))
);
create unique index if not exists una_caja_abierta_por_usuario
  on sesiones_caja (usuario) where estado = 'abierta';

create table if not exists movimientos_financieros (
  id            bigserial primary key,
  cuenta_id     uuid not null references cuentas_financieras(id),
  sesion_id     uuid references sesiones_caja(id),
  fecha         timestamptz not null default now(),
  monto         numeric(14,2) not null check (monto <> 0),   -- + ingreso / − egreso
  metodo        metodo_pago not null,
  referencia    text,
  doc_tipo      text not null,
  doc_id        uuid not null,
  conciliado    boolean not null default false,
  usuario       uuid
);

-- ---------------------------------------------------------------------
-- Ventas
-- ---------------------------------------------------------------------
create table if not exists cotizaciones (
  id           uuid primary key default gen_random_uuid(),
  numero       text not null unique,
  cliente_id   uuid references clientes(id),
  fecha        date not null default current_date,
  validez_dias int not null default 7,
  lineas       jsonb not null default '[]',
  total        numeric(14,2) not null default 0,
  venta_id     uuid,
  estado       text not null default 'abierta' check (estado in ('abierta','convertida','vencida','anulada')),
  created_by   uuid,
  created_at   timestamptz not null default now()
);

create table if not exists ventas (
  id               uuid primary key default gen_random_uuid(),
  numero           text not null unique,
  fecha            timestamptz not null default now(),
  cliente_id       uuid references clientes(id),
  canal            canal_venta not null default 'mostrador',
  condicion        text not null default 'contado' check (condicion in ('contado','credito')),
  fecha_vencimiento date,
  subtotal         numeric(14,2) not null default 0,
  descuento        numeric(14,2) not null default 0,
  itbis            numeric(14,2) not null default 0,
  total            numeric(14,2) not null default 0,
  saldo            numeric(14,2) not null default 0,     -- pendiente de cobro
  estado           estado_doc not null default 'confirmado',
  sesion_caja_id   uuid references sesiones_caja(id),
  comprobante_id   uuid,
  motivo_anulacion text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  constraint credito_requiere_cliente check (condicion = 'contado' or cliente_id is not null)
);

create table if not exists ventas_lineas (
  id                uuid primary key default gen_random_uuid(),
  venta_id          uuid not null references ventas(id) on delete cascade,
  producto_id       uuid not null references productos(id),
  lote_id           uuid references lotes(id),          -- null solo para servicios
  propiedad         tipo_propiedad,                      -- copia del lote al momento de vender
  cantidad          numeric(12,3) not null check (cantidad > 0),
  precio_unitario   numeric(14,2) not null check (precio_unitario >= 0),  -- sin ITBIS
  descuento         numeric(14,2) not null default 0,
  itbis_pct         numeric(5,2) not null default 0,
  itbis             numeric(14,2) not null default 0,
  total_linea       numeric(14,2) not null,
  costo_unitario    numeric(14,4),                       -- propia: costo promedio aplicado
  comision_pct      numeric(5,2),                        -- consignación
  cantidad_devuelta numeric(12,3) not null default 0
);

create table if not exists ventas_pagos (
  id         uuid primary key default gen_random_uuid(),
  venta_id   uuid not null references ventas(id) on delete cascade,
  cuenta_id  uuid not null references cuentas_financieras(id),
  metodo     metodo_pago not null,
  monto      numeric(14,2) not null check (monto > 0),
  referencia text
);

create table if not exists devoluciones_venta (
  id            uuid primary key default gen_random_uuid(),
  numero        text not null unique,
  venta_id      uuid not null references ventas(id),
  fecha         timestamptz not null default now(),
  total         numeric(14,2) not null default 0,
  reembolso     text not null default 'efectivo' check (reembolso in ('efectivo','credito_cliente','transferencia')),
  motivo        text,
  comprobante_id uuid,
  estado        estado_doc not null default 'confirmado',
  created_by    uuid,
  created_at    timestamptz not null default now()
);
create table if not exists devoluciones_venta_lineas (
  id              uuid primary key default gen_random_uuid(),
  devolucion_id   uuid not null references devoluciones_venta(id) on delete cascade,
  venta_linea_id  uuid not null references ventas_lineas(id),
  cantidad        numeric(12,3) not null check (cantidad > 0),
  monto           numeric(14,2) not null
);

-- Cuentas por pagar a consignadores (una fila por línea vendida/devuelta)
create table if not exists liquidaciones_consignacion (
  id              uuid primary key default gen_random_uuid(),
  numero          text not null unique,
  consignador_id  uuid not null references consignadores(id),
  desde           date not null,
  hasta           date not null,
  total_ventas    numeric(14,2) not null default 0,
  total_comision  numeric(14,2) not null default 0,
  ajustes         numeric(14,2) not null default 0,
  total_a_pagar   numeric(14,2) not null default 0,
  estado          text not null default 'borrador' check (estado in ('borrador','pagada','anulada')),
  fecha_pago      timestamptz,
  notas           text,
  created_by      uuid,
  created_at      timestamptz not null default now()
);

create table if not exists consignacion_cxp (
  id                 uuid primary key default gen_random_uuid(),
  consignador_id     uuid not null references consignadores(id),
  venta_linea_id     uuid references ventas_lineas(id),
  devolucion_linea_id uuid references devoluciones_venta_lineas(id),
  fecha              timestamptz not null default now(),
  precio_venta_neto  numeric(14,2) not null,       -- negativo si es reverso por devolución
  comision_pct       numeric(5,2) not null,
  comision           numeric(14,2) not null,
  monto_consignador  numeric(14,2) not null,
  liquidacion_id     uuid references liquidaciones_consignacion(id),
  estado             text not null default 'pendiente' check (estado in ('pendiente','liquidado','anulado')),
  constraint cxp_origen check (num_nonnulls(venta_linea_id, devolucion_linea_id) = 1),
  constraint cxp_cuadra check (comision + monto_consignador = precio_venta_neto)
);
create index if not exists cxp_consignador_pend_idx on consignacion_cxp (consignador_id) where estado = 'pendiente';

-- Cobros a clientes (CxC)
create table if not exists cobros (
  id          uuid primary key default gen_random_uuid(),
  numero      text not null unique,
  cliente_id  uuid not null references clientes(id),
  fecha       timestamptz not null default now(),
  cuenta_id   uuid not null references cuentas_financieras(id),
  metodo      metodo_pago not null,
  monto       numeric(14,2) not null check (monto > 0),
  estado      estado_doc not null default 'confirmado',
  created_by  uuid
);
create table if not exists cobros_aplicaciones (
  cobro_id  uuid not null references cobros(id) on delete cascade,
  venta_id  uuid not null references ventas(id),
  monto     numeric(14,2) not null check (monto > 0),
  primary key (cobro_id, venta_id)
);

-- CxP proveedores
create table if not exists facturas_proveedor (
  id              uuid primary key default gen_random_uuid(),
  proveedor_id    uuid not null references proveedores(id),
  numero_factura  text not null,
  ncf             text,
  fecha           date not null,
  fecha_vencimiento date,
  tipo_bien_servicio text,                      -- clasificación 606
  monto_bienes    numeric(14,2) not null default 0,
  monto_servicios numeric(14,2) not null default 0,
  itbis           numeric(14,2) not null default 0,
  itbis_retenido  numeric(14,2) not null default 0,
  isr_retenido    numeric(14,2) not null default 0,
  total           numeric(14,2) not null,
  saldo           numeric(14,2) not null,
  doc_origen_tipo text,
  doc_origen_id   uuid,
  estado          estado_doc not null default 'confirmado',
  created_at      timestamptz not null default now(),
  unique (proveedor_id, numero_factura)
);

create table if not exists gastos (
  id                uuid primary key default gen_random_uuid(),
  numero            text not null unique,
  fecha             date not null default current_date,
  cuenta_gasto_id   uuid not null references cuentas_contables(id),
  proveedor_id      uuid references proveedores(id),
  descripcion       text not null,
  ncf               text,
  monto             numeric(14,2) not null check (monto > 0),
  itbis             numeric(14,2) not null default 0,
  cuenta_pago_id    uuid references cuentas_financieras(id),
  soporte_url       text,
  estado            estado_doc not null default 'confirmado',
  created_by        uuid,
  created_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Contabilidad
-- ---------------------------------------------------------------------
create table if not exists periodos_contables (
  anio    int not null,
  mes     int not null check (mes between 1 and 12),
  estado  text not null default 'abierto' check (estado in ('abierto','cerrado')),
  cerrado_por uuid,
  cerrado_en  timestamptz,
  primary key (anio, mes)
);

create table if not exists asientos (
  id           uuid primary key default gen_random_uuid(),
  numero       text not null unique,
  fecha        date not null,
  descripcion  text not null,
  origen_tipo  text,           -- 'venta','recepcion_compra','manual',...
  origen_id    uuid,
  es_reverso_de uuid references asientos(id),
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index if not exists asientos_origen_idx on asientos (origen_tipo, origen_id);

create table if not exists asientos_lineas (
  id          bigserial primary key,
  asiento_id  uuid not null references asientos(id) on delete cascade,
  cuenta_id   uuid not null references cuentas_contables(id),
  debito      numeric(14,2) not null default 0 check (debito  >= 0),
  credito     numeric(14,2) not null default 0 check (credito >= 0),
  tercero_tipo text,           -- 'cliente','proveedor','consignador'
  tercero_id   uuid,
  descripcion text,
  constraint una_columna check ((debito > 0) <> (credito > 0))
);

-- Validaciones contables: cuadre (diferido), cuenta de detalle, período abierto
create or replace function trg_validar_asiento() returns trigger
language plpgsql as $$
declare v_id uuid := coalesce(new.asiento_id, old.asiento_id);
        d numeric; c numeric;
begin
  select coalesce(sum(debito),0), coalesce(sum(credito),0) into d, c
    from asientos_lineas where asiento_id = v_id;
  if exists (select 1 from asientos where id = v_id) and d <> c then
    raise exception 'Asiento % descuadrado: débitos % ≠ créditos %', v_id, d, c;
  end if;
  return null;
end $$;
drop trigger if exists asiento_cuadre on asientos_lineas;
create constraint trigger asiento_cuadre after insert or update or delete on asientos_lineas
  deferrable initially deferred for each row execute function trg_validar_asiento();

create or replace function trg_validar_linea_asiento() returns trigger
language plpgsql as $$
begin
  if not exists (select 1 from cuentas_contables where id = new.cuenta_id and acepta_movimientos and activo) then
    raise exception 'La cuenta contable no acepta movimientos (no es de detalle o está inactiva)';
  end if;
  return new;
end $$;
drop trigger if exists asiento_linea_cuenta on asientos_lineas;
create trigger asiento_linea_cuenta before insert or update on asientos_lineas
  for each row execute function trg_validar_linea_asiento();

create or replace function trg_validar_periodo() returns trigger
language plpgsql as $$
begin
  if exists (select 1 from periodos_contables
             where anio = extract(year from new.fecha)::int and mes = extract(month from new.fecha)::int
               and estado = 'cerrado') then
    raise exception 'El período %/% está cerrado', extract(month from new.fecha), extract(year from new.fecha);
  end if;
  return new;
end $$;
drop trigger if exists asiento_periodo on asientos;
create trigger asiento_periodo before insert or update on asientos
  for each row execute function trg_validar_periodo();

-- Mapeo evento → cuenta (las RPC leen de aquí; nunca códigos fijos en el frontend)
create table if not exists configuracion_cuentas (
  clave      text primary key,
  cuenta_codigo text not null references cuentas_contables(codigo),
  descripcion text
);

-- ---------------------------------------------------------------------
-- Fiscal
-- ---------------------------------------------------------------------
create table if not exists tipos_comprobante (
  codigo       text primary key,          -- '31','32','33','34','41','43','44','45'
  nombre       text not null,
  activo       boolean not null default true
);
insert into tipos_comprobante (codigo, nombre) values
  ('31','Factura de Crédito Fiscal'),('32','Factura de Consumo'),('33','Nota de Débito'),
  ('34','Nota de Crédito'),('41','Comprobante de Compras'),('43','Gastos Menores'),
  ('44','Regímenes Especiales'),('45','Gubernamental')
on conflict do nothing;

create table if not exists comprobantes_fiscales (
  id                uuid primary key default gen_random_uuid(),
  tipo_codigo       text not null references tipos_comprobante(codigo),
  encf              text unique,              -- e-NCF asignado (E31…)
  doc_tipo          text not null,            -- 'venta','devolucion_venta','pago_consignador','gasto'
  doc_id            uuid not null,
  comprobante_ref_id uuid references comprobantes_fiscales(id),   -- para notas de crédito
  estado            estado_ecf not null default 'pendiente',
  codigo_seguridad  text,
  url_consulta      text,
  proveedor_fe      text,                      -- nombre del proveedor autorizado
  respuesta         jsonb,
  intentos          int not null default 0,
  ultimo_error      text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table if not exists reglas_retencion (
  id            uuid primary key default gen_random_uuid(),
  descripcion   text not null,
  aplica_a      text not null check (aplica_a in ('persona_fisica','persona_juridica','todos')),
  tipo_bien_servicio text,
  isr_pct       numeric(5,2) not null default 0,
  itbis_ret_pct numeric(5,2) not null default 0,
  activo        boolean not null default false     -- se activan tras validar con el contador
);

-- ---------------------------------------------------------------------
-- Auditoría
-- ---------------------------------------------------------------------
create table if not exists auditoria (
  id         bigserial primary key,
  tabla      text not null,
  registro_id text,
  accion     text not null,
  antes      jsonb,
  despues    jsonb,
  usuario    uuid,
  fecha      timestamptz not null default now()
);

create or replace function trg_auditar() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into auditoria (tabla, registro_id, accion, antes, despues, usuario)
  values (tg_table_name,
          coalesce((to_jsonb(new)->>'id'), (to_jsonb(old)->>'id')),
          tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end,
          auth.uid());
  return coalesce(new, old);
end $$;

do $$ declare t text; begin
  foreach t in array array['productos','clientes','proveedores','consignadores','cuentas_contables',
                           'configuracion','configuracion_cuentas','perfiles','ventas','periodos_contables']
  loop
    execute format('drop trigger if exists auditar on %I', t);
    execute format('create trigger auditar after insert or update or delete on %I
                    for each row execute function trg_auditar()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Vistas base
-- ---------------------------------------------------------------------
create or replace view v_existencias as
select l.id as lote_id, p.id as producto_id, p.sku, p.descripcion, p.numero_oem,
       l.propiedad, l.consignador_id, c.nombre as consignador,
       l.almacen_id, a.nombre as almacen, l.cantidad_disponible,
       case when l.propiedad = 'propia' then p.costo_promedio end as costo_unitario,
       coalesce(l.precio_pactado, p.precio_venta) as precio_venta,
       l.comision_pct, l.fecha_entrada,
       (current_date - l.fecha_entrada) as dias_en_inventario
from lotes l
join productos p on p.id = l.producto_id
join almacenes a on a.id = l.almacen_id
left join consignadores c on c.id = l.consignador_id
where l.cantidad_disponible > 0;

create or replace view v_kardex as
select m.id, m.fecha, p.sku, p.descripcion, l.propiedad, m.tipo, m.cantidad,
       m.costo_unitario, m.cantidad * coalesce(m.costo_unitario,0) as valor,
       sum(m.cantidad) over (partition by m.producto_id, l.propiedad, l.consignador_id
                             order by m.fecha, m.id) as saldo,
       m.doc_tipo, m.doc_id, m.producto_id, m.lote_id, m.almacen_id
from movimientos_inventario m
join productos p on p.id = m.producto_id
join lotes l on l.id = m.lote_id;

create or replace view v_consignacion_pendiente as
select c.id as consignador_id, c.nombre,
       count(x.id) as lineas,
       coalesce(sum(x.precio_venta_neto),0) as ventas,
       coalesce(sum(x.comision),0) as comision,
       coalesce(sum(x.monto_consignador),0) as a_pagar
from consignadores c
left join consignacion_cxp x on x.consignador_id = c.id and x.estado = 'pendiente'
group by c.id, c.nombre;

create or replace view v_cxc_antiguedad as
select v.cliente_id, cl.nombre,
       sum(v.saldo) filter (where current_date - coalesce(v.fecha_vencimiento, v.fecha::date) <= 30) as d0_30,
       sum(v.saldo) filter (where current_date - coalesce(v.fecha_vencimiento, v.fecha::date) between 31 and 60) as d31_60,
       sum(v.saldo) filter (where current_date - coalesce(v.fecha_vencimiento, v.fecha::date) between 61 and 90) as d61_90,
       sum(v.saldo) filter (where current_date - coalesce(v.fecha_vencimiento, v.fecha::date) > 90) as d90_mas,
       sum(v.saldo) as total
from ventas v join clientes cl on cl.id = v.cliente_id
where v.estado = 'confirmado' and v.saldo > 0
group by v.cliente_id, cl.nombre;

create or replace view v_balanza as
select cc.codigo, cc.nombre, cc.tipo, cc.naturaleza,
       coalesce(sum(al.debito),0)  as debitos,
       coalesce(sum(al.credito),0) as creditos,
       case when cc.naturaleza = 'deudora'
            then coalesce(sum(al.debito),0) - coalesce(sum(al.credito),0)
            else coalesce(sum(al.credito),0) - coalesce(sum(al.debito),0) end as saldo
from cuentas_contables cc
left join asientos_lineas al on al.cuenta_id = cc.id
where cc.acepta_movimientos
group by cc.codigo, cc.nombre, cc.tipo, cc.naturaleza;
-- Nota: v_balanza es acumulada; los reportes por rango de fechas se hacen con
-- funciones parametrizadas (balanza(p_desde, p_hasta)) en migraciones siguientes.

-- ---------------------------------------------------------------------
-- RLS: lectura para usuarios activos; escritura de maestros por rol;
-- tablas transaccionales SOLO vía RPC (security definer).
-- Una política por operación (no usar CREATE POLICY IF NOT EXISTS).
-- ---------------------------------------------------------------------
do $$
declare
  t text;
  maestros text[] := array['marcas_vehiculo','modelos_vehiculo','categorias','productos','compatibilidades',
                           'clientes','proveedores','consignadores','almacenes','ubicaciones'];
  transaccionales text[] := array['lotes','movimientos_inventario','conteos_fisicos','conteos_fisicos_lineas',
     'ordenes_compra','ordenes_compra_lineas','importaciones','importaciones_gastos','recepciones_compra',
     'recepciones_consignacion','devoluciones_consignador','sesiones_caja','movimientos_financieros',
     'cotizaciones','ventas','ventas_lineas','ventas_pagos','devoluciones_venta','devoluciones_venta_lineas',
     'liquidaciones_consignacion','consignacion_cxp','cobros','cobros_aplicaciones','facturas_proveedor',
     'gastos','asientos','asientos_lineas','comprobantes_fiscales','busquedas_sin_resultado'];
  admin_contador text[] := array['configuracion','configuracion_cuentas','cuentas_contables','cuentas_financieras',
     'periodos_contables','secuencias_documento','tipos_comprobante','reglas_retencion','perfiles','auditoria'];
begin
  foreach t in array maestros || transaccionales || admin_contador loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists sel on %I', t);
    execute format('create policy sel on %I for select to authenticated using (rol_actual() is not null)', t);
  end loop;

  foreach t in array maestros loop
    execute format('drop policy if exists ins on %I', t);
    execute format('drop policy if exists upd on %I', t);
    execute format($p$create policy ins on %I for insert to authenticated
                      with check (rol_actual() in ('admin','almacen','vendedor'))$p$, t);
    execute format($p$create policy upd on %I for update to authenticated
                      using (rol_actual() in ('admin','almacen'))
                      with check (rol_actual() in ('admin','almacen'))$p$, t);
  end loop;

  foreach t in array array['configuracion','configuracion_cuentas','cuentas_contables','cuentas_financieras',
                           'reglas_retencion','tipos_comprobante'] loop
    execute format('drop policy if exists ins on %I', t);
    execute format('drop policy if exists upd on %I', t);
    execute format($p$create policy ins on %I for insert to authenticated
                      with check (rol_actual() in ('admin','contador'))$p$, t);
    execute format($p$create policy upd on %I for update to authenticated
                      using (rol_actual() in ('admin','contador'))
                      with check (rol_actual() in ('admin','contador'))$p$, t);
  end loop;

  -- perfiles: solo admin administra; auditoría: solo admin/contador la leen
  drop policy if exists ins on perfiles;  drop policy if exists upd on perfiles;
  create policy ins on perfiles for insert to authenticated with check (rol_actual() = 'admin');
  create policy upd on perfiles for update to authenticated using (rol_actual() = 'admin') with check (rol_actual() = 'admin');
  drop policy if exists sel on auditoria;
  create policy sel on auditoria for select to authenticated using (rol_actual() in ('admin','contador'));
end $$;

do $$ declare v text; begin
  foreach v in array array['v_existencias','v_kardex','v_consignacion_pendiente','v_cxc_antiguedad','v_balanza'] loop
    execute format('alter view %I set (security_invoker = on)', v);
    execute format('grant select on %I to authenticated', v);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Semillas: catálogo de cuentas (estructura RD, ajustar con el contador)
-- ---------------------------------------------------------------------
insert into cuentas_contables (codigo, nombre, tipo, naturaleza, padre_codigo, acepta_movimientos) values
 ('1',        'ACTIVOS',                                   'activo','deudora',  null, false),
 ('1.1',      'Activos corrientes',                        'activo','deudora',  '1', false),
 ('1.1.1',    'Efectivo y equivalentes',                   'activo','deudora',  '1.1', false),
 ('1.1.1.01', 'Caja general',                              'activo','deudora',  '1.1.1', true),
 ('1.1.1.02', 'Caja chica',                                'activo','deudora',  '1.1.1', true),
 ('1.1.1.03', 'Banco cuenta corriente DOP',                'activo','deudora',  '1.1.1', true),
 ('1.1.1.04', 'Banco cuenta USD',                          'activo','deudora',  '1.1.1', true),
 ('1.1.3',    'Cuentas por cobrar',                        'activo','deudora',  '1.1', false),
 ('1.1.3.01', 'Cuentas por cobrar clientes',               'activo','deudora',  '1.1.3', true),
 ('1.1.3.02', 'Cuentas por cobrar consignadores',          'activo','deudora',  '1.1.3', true),
 ('1.1.4',    'Inventarios',                               'activo','deudora',  '1.1', false),
 ('1.1.4.01', 'Inventario de mercancías (propias)',        'activo','deudora',  '1.1.4', true),
 ('1.1.4.02', 'Mercancía en tránsito (importaciones)',     'activo','deudora',  '1.1.4', true),
 ('1.1.5',    'Impuestos anticipados',                     'activo','deudora',  '1.1', false),
 ('1.1.5.01', 'ITBIS adelantado (crédito fiscal)',         'activo','deudora',  '1.1.5', true),
 ('1.1.5.02', 'Anticipos de ISR',                          'activo','deudora',  '1.1.5', true),
 ('1.1.5.03', 'Retenciones que nos realizaron',            'activo','deudora',  '1.1.5', true),
 ('1.2',      'Activos no corrientes',                     'activo','deudora',  '1', false),
 ('1.2.1.01', 'Mobiliario y equipos',                      'activo','deudora',  '1.2', true),
 ('1.2.1.02', 'Vehículos',                                 'activo','deudora',  '1.2', true),
 ('1.2.1.09', 'Depreciación acumulada',                    'activo','acreedora','1.2', true),
 ('2',        'PASIVOS',                                   'pasivo','acreedora',null, false),
 ('2.1',      'Pasivos corrientes',                        'pasivo','acreedora','2', false),
 ('2.1.1',    'Cuentas por pagar',                         'pasivo','acreedora','2.1', false),
 ('2.1.1.01', 'Cuentas por pagar proveedores locales',     'pasivo','acreedora','2.1.1', true),
 ('2.1.1.02', 'Cuentas por pagar proveedores exterior',    'pasivo','acreedora','2.1.1', true),
 ('2.1.1.03', 'Cuentas por pagar consignadores',           'pasivo','acreedora','2.1.1', true),
 ('2.1.1.04', 'Cuentas por pagar agentes aduanales',       'pasivo','acreedora','2.1.1', true),
 ('2.1.2.01', 'Anticipos de clientes',                     'pasivo','acreedora','2.1', true),
 ('2.1.3',    'Impuestos por pagar',                       'pasivo','acreedora','2.1', false),
 ('2.1.3.01', 'ITBIS por pagar',                           'pasivo','acreedora','2.1.3', true),
 ('2.1.3.02', 'ISR por pagar',                             'pasivo','acreedora','2.1.3', true),
 ('2.1.3.03', 'Retenciones ISR por pagar (IR-17)',         'pasivo','acreedora','2.1.3', true),
 ('2.1.3.04', 'ITBIS retenido por pagar',                  'pasivo','acreedora','2.1.3', true),
 ('2.2.1.01', 'Préstamos por pagar largo plazo',           'pasivo','acreedora','2', true),
 ('3',        'PATRIMONIO',                                'patrimonio','acreedora',null, false),
 ('3.1.1.01', 'Capital aportado',                          'patrimonio','acreedora','3', true),
 ('3.1.2.01', 'Resultados acumulados',                     'patrimonio','acreedora','3', true),
 ('3.1.3.01', 'Resultado del ejercicio',                   'patrimonio','acreedora','3', true),
 ('3.1.4.01', 'Retiros del propietario',                   'patrimonio','deudora',  '3', true),
 ('4',        'INGRESOS',                                  'ingreso','acreedora',null, false),
 ('4.1',      'Ingresos operacionales',                    'ingreso','acreedora','4', false),
 ('4.1.1.01', 'Ventas de mercancías propias',              'ingreso','acreedora','4.1', true),
 ('4.1.1.02', 'Ventas de mercancía consignada',            'ingreso','acreedora','4.1', true),
 ('4.1.1.09', 'Devoluciones y descuentos en ventas',       'ingreso','deudora',  '4.1', true),
 ('4.1.2.01', 'Ingresos por comisiones de consignación',   'ingreso','acreedora','4.1', true),
 ('4.1.3.01', 'Ingresos por servicios de instalación',     'ingreso','acreedora','4.1', true),
 ('4.2.1.01', 'Otros ingresos (sobrantes, diferencias)',   'ingreso','acreedora','4', true),
 ('4.2.1.02', 'Ganancia cambiaria',                        'ingreso','acreedora','4', true),
 ('5',        'COSTOS',                                    'costo','deudora',   null, false),
 ('5.1.1.01', 'Costo de ventas mercancías propias',        'costo','deudora',   '5', true),
 ('5.1.1.02', 'Costo de mercancía consignada vendida',     'costo','deudora',   '5', true),
 ('6',        'GASTOS',                                    'gasto','deudora',   null, false),
 ('6.1',      'Gastos operacionales',                      'gasto','deudora',   '6', false),
 ('6.1.1.01', 'Sueldos y salarios',                        'gasto','deudora',   '6.1', true),
 ('6.1.2.01', 'Alquiler',                                  'gasto','deudora',   '6.1', true),
 ('6.1.2.02', 'Energía eléctrica, agua, internet',         'gasto','deudora',   '6.1', true),
 ('6.1.3.01', 'Publicidad y redes sociales',               'gasto','deudora',   '6.1', true),
 ('6.1.4.01', 'Combustible y transporte',                  'gasto','deudora',   '6.1', true),
 ('6.1.5.01', 'Comisiones bancarias y de tarjetas',        'gasto','deudora',   '6.1', true),
 ('6.1.6.01', 'Honorarios profesionales',                  'gasto','deudora',   '6.1', true),
 ('6.1.7.01', 'Depreciación',                              'gasto','deudora',   '6.1', true),
 ('6.1.8.01', 'Gastos de importación no capitalizables',   'gasto','deudora',   '6.1', true),
 ('6.1.9.01', 'Pérdida por faltante de inventario',        'gasto','deudora',   '6.1', true),
 ('6.1.9.02', 'Pérdida cambiaria',                         'gasto','deudora',   '6.1', true),
 ('6.1.9.99', 'Otros gastos',                              'gasto','deudora',   '6.1', true),
 ('9',        'CUENTAS DE ORDEN',                          'orden','deudora',   null, false),
 ('9.1.1.01', 'Mercancía recibida en consignación',        'orden','deudora',   '9', true),
 ('9.2.1.01', 'Consignadores por mercancía recibida',      'orden','acreedora', '9', true)
on conflict (codigo) do nothing;

insert into configuracion_cuentas (clave, cuenta_codigo, descripcion) values
 ('caja_default',              '1.1.1.01', 'Caja principal'),
 ('cxc_clientes',              '1.1.3.01', null),
 ('inventario',                '1.1.4.01', null),
 ('inventario_transito',       '1.1.4.02', null),
 ('itbis_adelantado',          '1.1.5.01', null),
 ('cxp_proveedores',           '2.1.1.01', null),
 ('cxp_proveedores_exterior',  '2.1.1.02', null),
 ('cxp_consignadores',         '2.1.1.03', null),
 ('cxp_agente_aduanal',        '2.1.1.04', null),
 ('itbis_por_pagar',           '2.1.3.01', null),
 ('ventas_propias',            '4.1.1.01', null),
 ('ventas_consignadas',        '4.1.1.02', null),
 ('devoluciones_ventas',       '4.1.1.09', null),
 ('ingreso_comisiones',        '4.1.2.01', null),
 ('ingreso_servicios',         '4.1.3.01', null),
 ('otros_ingresos',            '4.2.1.01', null),
 ('costo_ventas_propias',      '5.1.1.01', null),
 ('costo_consignadas',         '5.1.1.02', null),
 ('perdida_inventario',        '6.1.9.01', null),
 ('orden_consignacion_deb',    '9.1.1.01', null),
 ('orden_consignacion_cred',   '9.2.1.01', null)
on conflict (clave) do nothing;

insert into marcas_vehiculo (nombre) values
 ('Changan'),('KYC'),('Shineray'),('Jetour'),('GAC'),('Jaecoo'),('Maxus'),('Hino')
on conflict (nombre) do nothing;

insert into categorias (nombre, margen_objetivo_pct) values
 ('Motor',40),('Frenos',40),('Suspensión y dirección',45),('Carrocería',60),('Eléctrico',50),
 ('Filtros y lubricación',35),('Enfriamiento',45),('Transmisión y embrague',50),('Iluminación',60),('Servicios',null)
on conflict (nombre) do nothing;

insert into almacenes (nombre) values ('Almacén principal') on conflict (nombre) do nothing;

insert into cuentas_financieras (nombre, tipo, cuenta_contable_id)
select 'Caja general', 'caja', id from cuentas_contables where codigo = '1.1.1.01'
on conflict (nombre) do nothing;
