-- =====================================================================
-- 003_rpc_inventario.sql — Fase 1: recepción de stock propio, conteo
-- físico y ajuste de inventario. Ver SPEC.md §5.2, §7.
-- =====================================================================

insert into secuencias_documento (prefijo) values ('CNT') on conflict do nothing;

-- ---------------------------------------------------------------------
-- recibir_stock_propio: entrada manual de stock propio (sin orden de
-- compra formal; esa flujo con landed cost llega en fase 5). Crea el
-- lote, actualiza el costo promedio ponderado del producto y registra
-- el movimiento de kardex.
-- ---------------------------------------------------------------------
create or replace function recibir_stock_propio(
  p_producto_id uuid,
  p_almacen_id uuid,
  p_cantidad numeric,
  p_costo_unitario numeric,
  p_ubicacion_id uuid default null,
  p_notas text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol rol_usuario := rol_actual();
  v_lote_id uuid := gen_random_uuid();
  v_numero text;
  v_stock_actual numeric;
  v_costo_actual numeric;
  v_costo_nuevo numeric;
begin
  if v_rol not in ('admin','almacen') then
    raise exception 'No tiene permiso para recibir inventario';
  end if;

  if exists (select 1 from periodos_contables
             where anio = extract(year from current_date)::int and mes = extract(month from current_date)::int
               and estado = 'cerrado') then
    raise exception 'El período contable actual está cerrado';
  end if;

  if p_cantidad is null or p_cantidad <= 0 then
    raise exception 'La cantidad debe ser mayor a cero';
  end if;
  if p_costo_unitario is null or p_costo_unitario < 0 then
    raise exception 'El costo unitario no puede ser negativo';
  end if;

  if not exists (select 1 from productos where id = p_producto_id and activo) then
    raise exception 'Producto no encontrado o inactivo';
  end if;
  if exists (select 1 from productos where id = p_producto_id and es_servicio) then
    raise exception 'No se puede recibir stock de un servicio';
  end if;
  if not exists (select 1 from almacenes where id = p_almacen_id and activo) then
    raise exception 'Almacén no encontrado o inactivo';
  end if;

  select coalesce(sum(cantidad_disponible), 0) into v_stock_actual
    from lotes where producto_id = p_producto_id and propiedad = 'propia';
  select costo_promedio into v_costo_actual from productos where id = p_producto_id;

  v_costo_nuevo := round(
    ((v_stock_actual * coalesce(v_costo_actual, 0)) + (p_cantidad * p_costo_unitario))
    / (v_stock_actual + p_cantidad), 4);

  v_numero := siguiente_numero('RCP');

  insert into lotes (id, producto_id, almacen_id, ubicacion_id, propiedad, costo_unitario,
                      cantidad_inicial, cantidad_disponible, doc_origen_tipo, doc_origen_id)
  values (v_lote_id, p_producto_id, p_almacen_id, p_ubicacion_id, 'propia', p_costo_unitario,
          p_cantidad, p_cantidad, 'recepcion_directa', v_lote_id);

  update productos set costo_promedio = v_costo_nuevo where id = p_producto_id;

  insert into movimientos_inventario (lote_id, producto_id, almacen_id, tipo, cantidad,
                                       costo_unitario, doc_tipo, doc_id, usuario, notas)
  values (v_lote_id, p_producto_id, p_almacen_id, 'entrada_compra', p_cantidad,
          p_costo_unitario, 'recepcion_directa', v_lote_id, auth.uid(), p_notas);

  return jsonb_build_object(
    'id', v_lote_id,
    'numero', v_numero,
    'cantidad', p_cantidad,
    'costo_unitario', p_costo_unitario,
    'costo_promedio_nuevo', v_costo_nuevo
  );
end $$;

-- ---------------------------------------------------------------------
-- Conteo físico: crear_conteo_fisico (toma foto del sistema),
-- actualizar_conteo_linea (captura el conteo real) y
-- registrar_ajuste_inventario (aplica diferencias al kardex).
-- ---------------------------------------------------------------------
create or replace function crear_conteo_fisico(
  p_almacen_id uuid,
  p_notas text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_numero text;
begin
  if rol_actual() not in ('admin','almacen') then
    raise exception 'No tiene permiso para crear conteos físicos';
  end if;
  if not exists (select 1 from almacenes where id = p_almacen_id and activo) then
    raise exception 'Almacén no encontrado o inactivo';
  end if;

  v_numero := siguiente_numero('CNT');

  insert into conteos_fisicos (numero, almacen_id, notas, created_by)
  values (v_numero, p_almacen_id, p_notas, auth.uid())
  returning id into v_id;

  insert into conteos_fisicos_lineas (conteo_id, lote_id, cantidad_sistema, cantidad_contada)
  select v_id, l.id, l.cantidad_disponible, l.cantidad_disponible
  from lotes l
  where l.almacen_id = p_almacen_id and l.cantidad_disponible > 0;

  return jsonb_build_object(
    'id', v_id,
    'numero', v_numero,
    'lineas', (select count(*) from conteos_fisicos_lineas where conteo_id = v_id)
  );
end $$;

create or replace function actualizar_conteo_linea(
  p_linea_id uuid,
  p_cantidad_contada numeric
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_estado estado_doc;
begin
  if rol_actual() not in ('admin','almacen') then
    raise exception 'No tiene permiso para capturar conteos físicos';
  end if;
  if p_cantidad_contada is null or p_cantidad_contada < 0 then
    raise exception 'La cantidad contada no puede ser negativa';
  end if;

  select cf.estado into v_estado
    from conteos_fisicos_lineas cfl join conteos_fisicos cf on cf.id = cfl.conteo_id
    where cfl.id = p_linea_id;

  if v_estado is null then
    raise exception 'Línea de conteo no encontrada';
  end if;
  if v_estado <> 'borrador' then
    raise exception 'El conteo ya fue procesado y no admite cambios';
  end if;

  update conteos_fisicos_lineas set cantidad_contada = p_cantidad_contada where id = p_linea_id;

  return jsonb_build_object('id', p_linea_id, 'cantidad_contada', p_cantidad_contada);
end $$;

create or replace function registrar_ajuste_inventario(p_conteo_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_estado estado_doc;
  v_numero text;
  v_linea record;
  v_diferencia numeric;
  v_diferencias int := 0;
  v_valor_diferencia numeric := 0;
  v_costo numeric;
begin
  if rol_actual() not in ('admin','almacen') then
    raise exception 'No tiene permiso para registrar ajustes de inventario';
  end if;

  select estado into v_estado from conteos_fisicos where id = p_conteo_id;
  if v_estado is null then
    raise exception 'Conteo físico no encontrado';
  end if;
  if v_estado <> 'borrador' then
    raise exception 'El conteo ya fue procesado';
  end if;

  if exists (select 1 from periodos_contables
             where anio = extract(year from current_date)::int and mes = extract(month from current_date)::int
               and estado = 'cerrado') then
    raise exception 'El período contable actual está cerrado';
  end if;

  v_numero := siguiente_numero('AJU');

  for v_linea in
    select cfl.id as linea_id, cfl.lote_id, cfl.cantidad_sistema, cfl.cantidad_contada,
           l.producto_id, l.almacen_id, l.propiedad, l.costo_unitario
    from conteos_fisicos_lineas cfl join lotes l on l.id = cfl.lote_id
    where cfl.conteo_id = p_conteo_id and cfl.cantidad_contada <> cfl.cantidad_sistema
  loop
    v_diferencia := v_linea.cantidad_contada - v_linea.cantidad_sistema;
    v_costo := case when v_linea.propiedad = 'propia' then v_linea.costo_unitario else 0 end;

    insert into movimientos_inventario (lote_id, producto_id, almacen_id, tipo, cantidad,
                                         costo_unitario, doc_tipo, doc_id, usuario)
    values (v_linea.lote_id, v_linea.producto_id, v_linea.almacen_id,
            case when v_diferencia > 0 then 'ajuste_positivo' else 'ajuste_negativo' end,
            v_diferencia, v_costo, 'conteo_fisico', p_conteo_id, auth.uid());

    update lotes set cantidad_disponible = v_linea.cantidad_contada where id = v_linea.lote_id;

    v_diferencias := v_diferencias + 1;
    v_valor_diferencia := v_valor_diferencia + (v_diferencia * coalesce(v_costo, 0));
  end loop;

  update conteos_fisicos set estado = 'confirmado' where id = p_conteo_id;

  return jsonb_build_object(
    'id', p_conteo_id,
    'numero', v_numero,
    'diferencias', v_diferencias,
    'valor_diferencia', round(v_valor_diferencia, 2)
  );
end $$;

revoke execute on function recibir_stock_propio(uuid, uuid, numeric, numeric, uuid, text) from public;
revoke execute on function crear_conteo_fisico(uuid, text) from public;
revoke execute on function actualizar_conteo_linea(uuid, numeric) from public;
revoke execute on function registrar_ajuste_inventario(uuid) from public;

grant execute on function recibir_stock_propio(uuid, uuid, numeric, numeric, uuid, text) to authenticated;
grant execute on function crear_conteo_fisico(uuid, text) to authenticated;
grant execute on function actualizar_conteo_linea(uuid, numeric) to authenticated;
grant execute on function registrar_ajuste_inventario(uuid) to authenticated;
