-- =====================================================================
-- 005_fix_rpc_tipo_movimiento_cast.sql
-- registrar_ajuste_inventario: el CASE que arma 'ajuste_positivo' /
-- 'ajuste_negativo' como texto no castea implícitamente al enum
-- tipo_movimiento de la columna destino. Se agrega el cast explícito.
-- =====================================================================

create or replace function registrar_ajuste_inventario(p_conteo_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol rol_usuario := rol_actual();
  v_estado estado_doc;
  v_numero text;
  v_linea record;
  v_diferencia numeric;
  v_diferencias int := 0;
  v_valor_diferencia numeric := 0;
  v_costo numeric;
begin
  if v_rol is null or v_rol not in ('admin','almacen') then
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
            (case when v_diferencia > 0 then 'ajuste_positivo' else 'ajuste_negativo' end)::tipo_movimiento,
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
