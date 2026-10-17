-- =====================================================================
-- 010_rpc_consignacion.sql — Fase 2: recepción y devolución de
-- mercancía en consignación. Ver SPEC.md §5.4, §7.
-- =====================================================================

-- ---------------------------------------------------------------------
-- registrar_recepcion_consignacion: recibe piezas de un consignador.
-- p_lineas: [{ "producto_id": uuid, "cantidad": numeric,
--              "precio_pactado": numeric, "comision_pct": numeric|null,
--              "estado_fisico": text|null }]
-- comision_pct por línea es opcional; si no se da, hereda el default
-- del consignador.
-- ---------------------------------------------------------------------
create or replace function registrar_recepcion_consignacion(
  p_consignador_id uuid,
  p_almacen_id uuid,
  p_lineas jsonb,
  p_notas text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol rol_usuario := rol_actual();
  v_comision_default numeric;
  v_recepcion_id uuid;
  v_numero text;
  v_linea jsonb;
  v_lote_id uuid;
  v_cantidad numeric;
  v_precio numeric;
  v_comision numeric;
  v_total_lineas int := 0;
  v_total_piezas numeric := 0;
begin
  if v_rol is null or v_rol not in ('admin','almacen') then
    raise exception 'No tiene permiso para recibir mercancía en consignación';
  end if;

  if exists (select 1 from periodos_contables
             where anio = extract(year from current_date)::int and mes = extract(month from current_date)::int
               and estado = 'cerrado') then
    raise exception 'El período contable actual está cerrado';
  end if;

  select comision_pct_default into v_comision_default
    from consignadores where id = p_consignador_id and activo;
  if v_comision_default is null then
    raise exception 'Consignador no encontrado o inactivo';
  end if;

  if not exists (select 1 from almacenes where id = p_almacen_id and activo) then
    raise exception 'Almacén no encontrado o inactivo';
  end if;

  if jsonb_array_length(coalesce(p_lineas, '[]'::jsonb)) = 0 then
    raise exception 'La recepción debe tener al menos una línea';
  end if;

  v_numero := siguiente_numero('REC');

  insert into recepciones_consignacion (numero, consignador_id, almacen_id, notas, created_by)
  values (v_numero, p_consignador_id, p_almacen_id, p_notas, auth.uid())
  returning id into v_recepcion_id;

  for v_linea in select * from jsonb_array_elements(p_lineas)
  loop
    v_cantidad := (v_linea->>'cantidad')::numeric;
    v_precio := (v_linea->>'precio_pactado')::numeric;
    v_comision := coalesce((v_linea->>'comision_pct')::numeric, v_comision_default);

    if v_cantidad is null or v_cantidad <= 0 then
      raise exception 'Cada línea debe tener una cantidad mayor a cero';
    end if;
    if v_precio is null or v_precio < 0 then
      raise exception 'El precio pactado no puede ser negativo';
    end if;
    if v_comision is null or v_comision < 0 or v_comision > 100 then
      raise exception 'El %% de comisión debe estar entre 0 y 100';
    end if;
    if not exists (select 1 from productos where id = (v_linea->>'producto_id')::uuid and activo and not es_servicio) then
      raise exception 'Pieza no encontrada, inactiva o es un servicio';
    end if;

    v_lote_id := gen_random_uuid();

    insert into lotes (id, producto_id, almacen_id, propiedad, consignador_id, precio_pactado,
                        comision_pct, cantidad_inicial, cantidad_disponible, estado_fisico,
                        doc_origen_tipo, doc_origen_id)
    values (v_lote_id, (v_linea->>'producto_id')::uuid, p_almacen_id, 'consignacion', p_consignador_id,
            v_precio, v_comision, v_cantidad, v_cantidad, v_linea->>'estado_fisico',
            'recepcion_consignacion', v_recepcion_id);

    insert into movimientos_inventario (lote_id, producto_id, almacen_id, tipo, cantidad,
                                         doc_tipo, doc_id, usuario)
    values (v_lote_id, (v_linea->>'producto_id')::uuid, p_almacen_id, 'entrada_consignacion', v_cantidad,
            'recepcion_consignacion', v_recepcion_id, auth.uid());

    v_total_lineas := v_total_lineas + 1;
    v_total_piezas := v_total_piezas + v_cantidad;
  end loop;

  return jsonb_build_object(
    'id', v_recepcion_id,
    'numero', v_numero,
    'lineas', v_total_lineas,
    'piezas', v_total_piezas
  );
end $$;

-- ---------------------------------------------------------------------
-- devolver_a_consignador: regresa piezas no vendidas al consignador.
-- p_lineas: [{ "lote_id": uuid, "cantidad": numeric }]
-- ---------------------------------------------------------------------
create or replace function devolver_a_consignador(
  p_consignador_id uuid,
  p_lineas jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol rol_usuario := rol_actual();
  v_devolucion_id uuid;
  v_numero text;
  v_linea jsonb;
  v_lote record;
  v_cantidad numeric;
  v_total_lineas int := 0;
  v_total_piezas numeric := 0;
begin
  if v_rol is null or v_rol not in ('admin','almacen') then
    raise exception 'No tiene permiso para devolver mercancía a un consignador';
  end if;

  if exists (select 1 from periodos_contables
             where anio = extract(year from current_date)::int and mes = extract(month from current_date)::int
               and estado = 'cerrado') then
    raise exception 'El período contable actual está cerrado';
  end if;

  if not exists (select 1 from consignadores where id = p_consignador_id and activo) then
    raise exception 'Consignador no encontrado o inactivo';
  end if;

  if jsonb_array_length(coalesce(p_lineas, '[]'::jsonb)) = 0 then
    raise exception 'La devolución debe tener al menos una línea';
  end if;

  v_numero := siguiente_numero('DEV');

  insert into devoluciones_consignador (numero, consignador_id, created_by)
  values (v_numero, p_consignador_id, auth.uid())
  returning id into v_devolucion_id;

  for v_linea in select * from jsonb_array_elements(p_lineas)
  loop
    v_cantidad := (v_linea->>'cantidad')::numeric;

    select * into v_lote from lotes where id = (v_linea->>'lote_id')::uuid for update;
    if v_lote is null then
      raise exception 'Lote no encontrado';
    end if;
    if v_lote.propiedad <> 'consignacion' or v_lote.consignador_id <> p_consignador_id then
      raise exception 'El lote no pertenece a este consignador';
    end if;
    if v_cantidad is null or v_cantidad <= 0 then
      raise exception 'Cada línea debe tener una cantidad mayor a cero';
    end if;
    if v_cantidad > v_lote.cantidad_disponible then
      raise exception 'No hay suficiente cantidad disponible en el lote % (disponible: %)', v_lote.id, v_lote.cantidad_disponible;
    end if;

    update lotes set cantidad_disponible = cantidad_disponible - v_cantidad where id = v_lote.id;

    insert into movimientos_inventario (lote_id, producto_id, almacen_id, tipo, cantidad,
                                         doc_tipo, doc_id, usuario)
    values (v_lote.id, v_lote.producto_id, v_lote.almacen_id, 'salida_devolucion_consignador', -v_cantidad,
            'devolucion_consignador', v_devolucion_id, auth.uid());

    v_total_lineas := v_total_lineas + 1;
    v_total_piezas := v_total_piezas + v_cantidad;
  end loop;

  return jsonb_build_object(
    'id', v_devolucion_id,
    'numero', v_numero,
    'lineas', v_total_lineas,
    'piezas', v_total_piezas
  );
end $$;

revoke execute on function registrar_recepcion_consignacion(uuid, uuid, jsonb, text) from public, anon;
revoke execute on function devolver_a_consignador(uuid, jsonb) from public, anon;
grant execute on function registrar_recepcion_consignacion(uuid, uuid, jsonb, text) to authenticated;
grant execute on function devolver_a_consignador(uuid, jsonb) to authenticated;
