-- =====================================================================
-- 011_rpc_ventas_caja.sql — Fase 3: caja, venta (POS) y cobros a
-- clientes. Ver SPEC.md §5.5, §5.6, §5.8, §7.
--
-- Alcance: esta RPC NO genera asientos contables todavía (eso llega en
-- Fase 6, que extiende estas mismas funciones vía una migración nueva,
-- por regla de CLAUDE.md de no editar migraciones ya aplicadas). Sí
-- resuelve: kardex, costo promedio (solo lectura/snapshot), caja,
-- consignacion_cxp y CxC — que es exactamente el criterio de
-- aceptación de Fase 3 en SPEC §10.
-- =====================================================================

-- ---------------------------------------------------------------------
-- abrir_caja / cerrar_caja
-- ---------------------------------------------------------------------
create or replace function abrir_caja(
  p_cuenta_id uuid,
  p_monto_apertura numeric default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol rol_usuario := rol_actual();
  v_id uuid;
  v_numero text;
begin
  if v_rol is null or v_rol not in ('admin','vendedor') then
    raise exception 'No tiene permiso para abrir caja';
  end if;
  if not exists (select 1 from cuentas_financieras where id = p_cuenta_id and activo and tipo = 'caja') then
    raise exception 'Cuenta de caja no encontrada o inactiva';
  end if;
  if exists (select 1 from sesiones_caja where usuario = auth.uid() and estado = 'abierta') then
    raise exception 'Ya tiene una sesión de caja abierta';
  end if;
  if p_monto_apertura is null or p_monto_apertura < 0 then
    raise exception 'El monto de apertura no puede ser negativo';
  end if;

  v_numero := siguiente_numero('CAJ');

  insert into sesiones_caja (numero, cuenta_id, usuario, monto_apertura)
  values (v_numero, p_cuenta_id, auth.uid(), p_monto_apertura)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'numero', v_numero, 'monto_apertura', p_monto_apertura);
end $$;

create or replace function cerrar_caja(
  p_sesion_id uuid,
  p_monto_contado numeric
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol rol_usuario := rol_actual();
  v_sesion sesiones_caja;
  v_movimientos numeric;
  v_esperado numeric;
  v_diferencia numeric;
begin
  if v_rol is null or v_rol not in ('admin','vendedor') then
    raise exception 'No tiene permiso para cerrar caja';
  end if;

  select * into v_sesion from sesiones_caja where id = p_sesion_id for update;
  if v_sesion is null then
    raise exception 'Sesión de caja no encontrada';
  end if;
  if v_sesion.estado <> 'abierta' then
    raise exception 'Esta sesión de caja ya está cerrada';
  end if;
  if v_sesion.usuario <> auth.uid() and v_rol <> 'admin' then
    raise exception 'Solo el usuario que abrió la caja (o un admin) puede cerrarla';
  end if;
  if p_monto_contado is null or p_monto_contado < 0 then
    raise exception 'El monto contado no puede ser negativo';
  end if;

  select coalesce(sum(monto), 0) into v_movimientos
    from movimientos_financieros where sesion_id = p_sesion_id;

  v_esperado := v_sesion.monto_apertura + v_movimientos;
  v_diferencia := round(p_monto_contado - v_esperado, 2);

  update sesiones_caja
     set cierre = now(), monto_contado = p_monto_contado, monto_esperado = v_esperado,
         diferencia = v_diferencia, estado = 'cerrada'
   where id = p_sesion_id;

  return jsonb_build_object(
    'id', p_sesion_id, 'numero', v_sesion.numero,
    'monto_esperado', v_esperado, 'monto_contado', p_monto_contado, 'diferencia', v_diferencia
  );
end $$;

-- ---------------------------------------------------------------------
-- registrar_venta: venta mixta (propia / consignada / servicio) en una
-- sola transacción. p_lineas:
--   [{ "producto_id": uuid, "lote_id": uuid|null, "cantidad": numeric,
--      "precio_unitario": numeric, "descuento": numeric|null }]
-- p_pagos: [{ "cuenta_id": uuid, "metodo": metodo_pago, "monto": numeric,
--             "referencia": text|null }]
-- p_tipo_pago: 'contado' | 'credito'
-- ---------------------------------------------------------------------
create or replace function registrar_venta(
  p_cliente_id uuid,
  p_canal canal_venta,
  p_lineas jsonb,
  p_pagos jsonb,
  p_tipo_pago text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol rol_usuario := rol_actual();
  v_config configuracion;
  v_sesion_id uuid;
  v_venta_id uuid;
  v_numero text;
  v_linea jsonb;
  v_pago jsonb;
  v_producto productos;
  v_lote lotes;
  v_cantidad numeric;
  v_descuento numeric;
  v_precio_unit numeric;
  v_itbis_pct numeric;
  v_subtotal_linea numeric;
  v_base_linea numeric;
  v_itbis_linea numeric;
  v_total_linea numeric;
  v_venta_linea_id uuid;
  v_precio_neto_cxp numeric;
  v_comision numeric;
  v_subtotal numeric := 0;
  v_descuento_total numeric := 0;
  v_itbis_total numeric := 0;
  v_total numeric := 0;
  v_pagado numeric := 0;
begin
  if v_rol is null or v_rol not in ('admin','vendedor') then
    raise exception 'No tiene permiso para registrar ventas';
  end if;

  if exists (select 1 from periodos_contables
             where anio = extract(year from current_date)::int and mes = extract(month from current_date)::int
               and estado = 'cerrado') then
    raise exception 'El período contable actual está cerrado';
  end if;

  if p_tipo_pago not in ('contado','credito') then
    raise exception 'Tipo de pago inválido: debe ser contado o crédito';
  end if;
  if p_tipo_pago = 'credito' and p_cliente_id is null then
    raise exception 'Una venta a crédito requiere cliente';
  end if;
  if jsonb_array_length(coalesce(p_lineas, '[]'::jsonb)) = 0 then
    raise exception 'La venta debe tener al menos una línea';
  end if;

  select * into v_config from configuracion where id = 1;

  select id into v_sesion_id from sesiones_caja where usuario = auth.uid() and estado = 'abierta';
  if v_sesion_id is null then
    raise exception 'Debe abrir su caja antes de registrar una venta';
  end if;

  v_numero := siguiente_numero('VTA');

  insert into ventas (numero, cliente_id, canal, condicion, sesion_caja_id, created_by)
  values (v_numero, p_cliente_id, p_canal, p_tipo_pago, v_sesion_id, auth.uid())
  returning id into v_venta_id;

  for v_linea in select * from jsonb_array_elements(p_lineas)
  loop
    select * into v_producto from productos where id = (v_linea->>'producto_id')::uuid and activo;
    if v_producto is null then
      raise exception 'Pieza no encontrada o inactiva';
    end if;

    v_cantidad := (v_linea->>'cantidad')::numeric;
    v_precio_unit := (v_linea->>'precio_unitario')::numeric;
    v_descuento := coalesce((v_linea->>'descuento')::numeric, 0);

    if v_cantidad is null or v_cantidad <= 0 then
      raise exception 'Cada línea debe tener una cantidad mayor a cero';
    end if;
    if v_precio_unit is null or v_precio_unit < 0 then
      raise exception 'El precio unitario no puede ser negativo';
    end if;
    if v_descuento < 0 then
      raise exception 'El descuento no puede ser negativo';
    end if;

    v_itbis_pct := case when v_config.modo_fiscal <> 'informal' and v_producto.aplica_itbis
                        then v_config.tasa_itbis else 0 end;

    -- precio_unitario de entrada puede venir con ITBIS incluido según configuración
    if v_config.precios_incluyen_itbis and v_itbis_pct > 0 then
      v_precio_unit := round(v_precio_unit / (1 + v_itbis_pct / 100), 4);
    end if;

    v_subtotal_linea := v_precio_unit * v_cantidad;
    if v_descuento > v_subtotal_linea then
      raise exception 'El descuento no puede ser mayor al subtotal de la línea';
    end if;
    v_base_linea := v_subtotal_linea - v_descuento;
    v_itbis_linea := round(v_base_linea * v_itbis_pct / 100, 2);
    v_total_linea := round(v_base_linea + v_itbis_linea, 2);

    v_lote := null;
    if not v_producto.es_servicio then
      if v_linea->>'lote_id' is null then
        raise exception 'Debe indicar el lote para una pieza (no es servicio)';
      end if;
      select * into v_lote from lotes where id = (v_linea->>'lote_id')::uuid for update;
      if v_lote is null or v_lote.producto_id <> v_producto.id then
        raise exception 'Lote no encontrado para la pieza indicada';
      end if;
      if v_lote.cantidad_disponible < v_cantidad then
        raise exception 'No hay suficiente existencia en el lote % (disponible: %)', v_lote.id, v_lote.cantidad_disponible;
      end if;

      update lotes set cantidad_disponible = cantidad_disponible - v_cantidad where id = v_lote.id;

      insert into movimientos_inventario (lote_id, producto_id, almacen_id, tipo, cantidad,
                                           costo_unitario, doc_tipo, doc_id, usuario)
      values (v_lote.id, v_producto.id, v_lote.almacen_id, 'salida_venta', -v_cantidad,
              case when v_lote.propiedad = 'propia' then v_producto.costo_promedio else null end,
              'venta', v_venta_id, auth.uid());
    end if;

    insert into ventas_lineas (venta_id, producto_id, lote_id, propiedad, cantidad, precio_unitario,
                                descuento, itbis_pct, itbis, total_linea, costo_unitario, comision_pct)
    values (v_venta_id, v_producto.id, v_lote.id,
            case when v_producto.es_servicio then null else v_lote.propiedad end,
            v_cantidad, round(v_precio_unit, 2), round(v_descuento, 2), v_itbis_pct, v_itbis_linea, v_total_linea,
            case when v_lote.propiedad = 'propia' then v_producto.costo_promedio else null end,
            case when v_lote.propiedad = 'consignacion' then v_lote.comision_pct else null end)
    returning id into v_venta_linea_id;

    if not v_producto.es_servicio and v_lote.propiedad = 'consignacion' then
      v_precio_neto_cxp := v_base_linea; -- neto de descuento, sin ITBIS (el ITBIS no es ingreso del consignador)
      v_comision := round(v_precio_neto_cxp * v_lote.comision_pct / 100, 2);
      insert into consignacion_cxp (consignador_id, venta_linea_id, precio_venta_neto, comision_pct,
                                     comision, monto_consignador)
      values (v_lote.consignador_id, v_venta_linea_id, round(v_precio_neto_cxp, 2), v_lote.comision_pct,
              v_comision, round(v_precio_neto_cxp - v_comision, 2));
    end if;

    v_subtotal := v_subtotal + v_subtotal_linea;
    v_descuento_total := v_descuento_total + v_descuento;
    v_itbis_total := v_itbis_total + v_itbis_linea;
    v_total := v_total + v_total_linea;
  end loop;

  for v_pago in select * from jsonb_array_elements(coalesce(p_pagos, '[]'::jsonb))
  loop
    if (v_pago->>'monto')::numeric <= 0 then
      raise exception 'El monto de un pago debe ser mayor a cero';
    end if;
    if not exists (select 1 from cuentas_financieras where id = (v_pago->>'cuenta_id')::uuid and activo) then
      raise exception 'Cuenta financiera no encontrada o inactiva';
    end if;

    insert into ventas_pagos (venta_id, cuenta_id, metodo, monto, referencia)
    values (v_venta_id, (v_pago->>'cuenta_id')::uuid, (v_pago->>'metodo')::metodo_pago,
            (v_pago->>'monto')::numeric, v_pago->>'referencia');

    insert into movimientos_financieros (cuenta_id, sesion_id, monto, metodo, referencia, doc_tipo, doc_id, usuario)
    values ((v_pago->>'cuenta_id')::uuid, v_sesion_id, (v_pago->>'monto')::numeric,
            (v_pago->>'metodo')::metodo_pago, v_pago->>'referencia', 'venta', v_venta_id, auth.uid());

    v_pagado := v_pagado + (v_pago->>'monto')::numeric;
  end loop;

  if p_tipo_pago = 'contado' and v_pagado < v_total then
    raise exception 'Los pagos (RD$%) no cubren el total de la venta (RD$%)', round(v_pagado,2), round(v_total,2);
  end if;
  if v_pagado > v_total then
    raise exception 'Los pagos no pueden superar el total de la venta';
  end if;

  update ventas set
    subtotal = round(v_subtotal, 2),
    descuento = round(v_descuento_total, 2),
    itbis = round(v_itbis_total, 2),
    total = round(v_total, 2),
    saldo = round(v_total - v_pagado, 2),
    fecha_vencimiento = case when p_tipo_pago = 'credito' then
      (current_date + (coalesce((select dias_credito from clientes where id = p_cliente_id), 0) || ' days')::interval)::date
      else null end
  where id = v_venta_id;

  return jsonb_build_object(
    'id', v_venta_id, 'numero', v_numero,
    'subtotal', round(v_subtotal,2), 'descuento', round(v_descuento_total,2),
    'itbis', round(v_itbis_total,2), 'total', round(v_total,2), 'saldo', round(v_total - v_pagado, 2)
  );
end $$;

-- ---------------------------------------------------------------------
-- registrar_cobro: aplica un pago recibido a una o varias ventas a
-- crédito del mismo cliente.
-- p_aplicaciones: [{ "venta_id": uuid, "monto": numeric }]
-- ---------------------------------------------------------------------
create or replace function registrar_cobro(
  p_cliente_id uuid,
  p_monto numeric,
  p_aplicaciones jsonb,
  p_cuenta_id uuid,
  p_metodo metodo_pago,
  p_referencia text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol rol_usuario := rol_actual();
  v_cobro_id uuid;
  v_numero text;
  v_aplicacion jsonb;
  v_venta ventas;
  v_suma_aplicaciones numeric := 0;
begin
  if v_rol is null or v_rol not in ('admin','vendedor') then
    raise exception 'No tiene permiso para registrar cobros';
  end if;
  if not exists (select 1 from clientes where id = p_cliente_id and activo) then
    raise exception 'Cliente no encontrado o inactivo';
  end if;
  if p_monto is null or p_monto <= 0 then
    raise exception 'El monto cobrado debe ser mayor a cero';
  end if;
  if not exists (select 1 from cuentas_financieras where id = p_cuenta_id and activo) then
    raise exception 'Cuenta financiera no encontrada o inactiva';
  end if;
  if jsonb_array_length(coalesce(p_aplicaciones, '[]'::jsonb)) = 0 then
    raise exception 'Debe aplicar el cobro a al menos una venta';
  end if;

  for v_aplicacion in select * from jsonb_array_elements(p_aplicaciones)
  loop
    v_suma_aplicaciones := v_suma_aplicaciones + (v_aplicacion->>'monto')::numeric;
  end loop;
  if round(v_suma_aplicaciones, 2) <> round(p_monto, 2) then
    raise exception 'La suma de las aplicaciones (RD$%) no coincide con el monto cobrado (RD$%)', round(v_suma_aplicaciones,2), round(p_monto,2);
  end if;

  v_numero := siguiente_numero('COB');

  insert into cobros (numero, cliente_id, cuenta_id, metodo, monto, created_by)
  values (v_numero, p_cliente_id, p_cuenta_id, p_metodo, p_monto, auth.uid())
  returning id into v_cobro_id;

  for v_aplicacion in select * from jsonb_array_elements(p_aplicaciones)
  loop
    select * into v_venta from ventas where id = (v_aplicacion->>'venta_id')::uuid for update;
    if v_venta is null or v_venta.cliente_id <> p_cliente_id then
      raise exception 'Venta no encontrada para este cliente';
    end if;
    if (v_aplicacion->>'monto')::numeric > v_venta.saldo then
      raise exception 'El monto aplicado a la venta % supera su saldo pendiente (RD$%)', v_venta.numero, v_venta.saldo;
    end if;

    update ventas set saldo = round(saldo - (v_aplicacion->>'monto')::numeric, 2) where id = v_venta.id;

    insert into cobros_aplicaciones (cobro_id, venta_id, monto)
    values (v_cobro_id, v_venta.id, (v_aplicacion->>'monto')::numeric);
  end loop;

  return jsonb_build_object('id', v_cobro_id, 'numero', v_numero, 'monto', round(p_monto, 2));
end $$;

revoke execute on function abrir_caja(uuid, numeric) from public, anon;
revoke execute on function cerrar_caja(uuid, numeric) from public, anon;
revoke execute on function registrar_venta(uuid, canal_venta, jsonb, jsonb, text) from public, anon;
revoke execute on function registrar_cobro(uuid, numeric, jsonb, uuid, metodo_pago, text) from public, anon;

grant execute on function abrir_caja(uuid, numeric) to authenticated;
grant execute on function cerrar_caja(uuid, numeric) to authenticated;
grant execute on function registrar_venta(uuid, canal_venta, jsonb, jsonb, text) to authenticated;
grant execute on function registrar_cobro(uuid, numeric, jsonb, uuid, metodo_pago, text) to authenticated;
