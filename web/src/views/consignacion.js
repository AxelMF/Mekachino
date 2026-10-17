import { api } from '../api.js'
import { mostrarToast } from '../toast.js'

export async function renderConsignacion(el) {
  const estado = {
    pestana: 'consignadores',
    consignadores: [],
    productos: [],
    almacenes: [],
    existencias: [],
    diasAlerta: 90,
    consignadorEditando: null,
    lineasRecepcion: [{ producto_id: '', cantidad: '', precio_pactado: '', comision_pct: '' }],
  }

  el.innerHTML = `<p class="cargando">Cargando consignación…</p>`

  try {
    const [consignadores, productos, almacenes, existencias, config] = await Promise.all([
      api.select('consignadores', (q) => q.order('nombre')),
      api.select('productos', (q) => q.eq('activo', true).eq('es_servicio', false).order('sku')),
      api.select('almacenes', (q) => q.eq('activo', true).order('nombre')),
      api.select('v_existencias', (q) => q.eq('propiedad', 'consignacion').order('sku')),
      api.select('configuracion'),
    ])
    estado.consignadores = consignadores
    estado.productos = productos
    estado.almacenes = almacenes
    estado.existencias = existencias
    estado.diasAlerta = config[0]?.dias_alerta_consignacion ?? 90
  } catch {
    el.innerHTML = `<p class="seccion-pendiente">No se pudo cargar la consignación.</p>`
    return
  }

  dibujar()

  function dibujar() {
    el.innerHTML = `
      <div class="pantalla-header"><h2>Consignación</h2></div>
      <div class="tabs">
        <button class="tab ${estado.pestana === 'consignadores' ? 'tab-activo' : ''}" data-tab="consignadores">Consignadores</button>
        <button class="tab ${estado.pestana === 'recepcion' ? 'tab-activo' : ''}" data-tab="recepcion">Recepción</button>
        <button class="tab ${estado.pestana === 'devolucion' ? 'tab-activo' : ''}" data-tab="devolucion">Devolución</button>
        <button class="tab ${estado.pestana === 'existencias' ? 'tab-activo' : ''}" data-tab="existencias">Existencias</button>
      </div>
      <div id="tab-contenido"></div>
    `
    el.querySelectorAll('.tab').forEach((btn) =>
      btn.addEventListener('click', () => {
        estado.pestana = btn.dataset.tab
        dibujar()
      })
    )
    const contenido = el.querySelector('#tab-contenido')
    if (estado.pestana === 'consignadores') dibujarConsignadores(contenido)
    else if (estado.pestana === 'recepcion') dibujarRecepcion(contenido)
    else if (estado.pestana === 'devolucion') dibujarDevolucion(contenido)
    else dibujarExistencias(contenido)
  }

  // ---------- Consignadores ----------
  function dibujarConsignadores(contenido) {
    if (estado.consignadorEditando !== null) {
      dibujarFormularioConsignador(contenido)
      return
    }
    contenido.innerHTML = `
      <div class="pantalla-header"><button class="btn-primario" id="btn-nuevo-consignador">+ Nuevo consignador</button></div>
      <table class="tabla">
        <thead><tr><th>Nombre</th><th>Documento</th><th>Teléfono</th><th>% Comisión</th><th>Frecuencia</th><th>Activo</th></tr></thead>
        <tbody>
          ${estado.consignadores
            .map(
              (c) => `
            <tr data-id="${c.id}" class="fila-click">
              <td>${escaparHtml(c.nombre)}</td>
              <td>${escaparHtml(c.documento || '—')}</td>
              <td>${escaparHtml(c.telefono || '—')}</td>
              <td>${c.comision_pct_default}%</td>
              <td>${escaparHtml(c.frecuencia_liquidacion)}</td>
              <td>${c.activo ? 'Sí' : 'No'}</td>
            </tr>`
            )
            .join('') || `<tr><td colspan="6" class="tabla-vacia">Sin consignadores.</td></tr>`}
        </tbody>
      </table>
    `
    contenido.querySelector('#btn-nuevo-consignador').addEventListener('click', () => {
      estado.consignadorEditando = {}
      dibujar()
    })
    contenido.querySelectorAll('.fila-click').forEach((tr) =>
      tr.addEventListener('click', () => {
        estado.consignadorEditando = estado.consignadores.find((c) => c.id === tr.dataset.id)
        dibujar()
      })
    )
  }

  function dibujarFormularioConsignador(contenido) {
    const c = estado.consignadorEditando
    const esNuevo = !c.id
    contenido.innerHTML = `
      <div class="pantalla-header">
        <h3>${esNuevo ? 'Nuevo consignador' : 'Editar consignador'}</h3>
        <button class="btn-secundario" id="btn-volver-consig">← Volver</button>
      </div>
      <form id="form-consignador" class="tarjeta-form">
        <label>Nombre
          <input name="nombre" required value="${escaparAttr(c.nombre || '')}" />
        </label>
        <div class="form-grid">
          <label>Tipo de documento
            <select name="tipo_doc">
              <option value="">—</option>
              <option value="cedula" ${c.tipo_doc === 'cedula' ? 'selected' : ''}>Cédula</option>
              <option value="rnc" ${c.tipo_doc === 'rnc' ? 'selected' : ''}>RNC</option>
              <option value="pasaporte" ${c.tipo_doc === 'pasaporte' ? 'selected' : ''}>Pasaporte</option>
            </select>
          </label>
          <label>Documento
            <input name="documento" value="${escaparAttr(c.documento || '')}" />
          </label>
        </div>
        <div class="form-grid">
          <label>Teléfono
            <input name="telefono" value="${escaparAttr(c.telefono || '')}" />
          </label>
          <label>Email
            <input name="email" type="email" value="${escaparAttr(c.email || '')}" />
          </label>
        </div>
        <label>Datos de pago (banco / cuenta)
          <input name="datos_pago" value="${escaparAttr(c.datos_pago || '')}" />
        </label>
        <div class="form-grid">
          <label>% Comisión por defecto
            <input name="comision_pct_default" type="number" step="0.01" min="0" max="100" required value="${c.comision_pct_default ?? 15}" />
          </label>
          <label>Frecuencia de liquidación
            <select name="frecuencia_liquidacion">
              <option value="semanal" ${c.frecuencia_liquidacion === 'semanal' ? 'selected' : ''}>Semanal</option>
              <option value="quincenal" ${!c.frecuencia_liquidacion || c.frecuencia_liquidacion === 'quincenal' ? 'selected' : ''}>Quincenal</option>
              <option value="mensual" ${c.frecuencia_liquidacion === 'mensual' ? 'selected' : ''}>Mensual</option>
            </select>
          </label>
        </div>
        <label class="form-check">
          <input name="es_contribuyente" type="checkbox" ${c.es_contribuyente ? 'checked' : ''} />
          Es contribuyente formal (tiene RNC / emite comprobantes)
        </label>
        <div class="form-acciones">
          <button type="submit" class="btn-primario">${esNuevo ? 'Crear consignador' : 'Guardar cambios'}</button>
        </div>
      </form>
    `
    contenido.querySelector('#btn-volver-consig').addEventListener('click', () => {
      estado.consignadorEditando = null
      dibujar()
    })
    contenido.querySelector('#form-consignador').addEventListener('submit', async (ev) => {
      ev.preventDefault()
      const fd = new FormData(ev.target)
      const valores = {
        nombre: fd.get('nombre').trim(),
        tipo_doc: fd.get('tipo_doc') || null,
        documento: fd.get('documento')?.trim() || null,
        telefono: fd.get('telefono')?.trim() || null,
        email: fd.get('email')?.trim() || null,
        datos_pago: fd.get('datos_pago')?.trim() || null,
        comision_pct_default: Number(fd.get('comision_pct_default')),
        frecuencia_liquidacion: fd.get('frecuencia_liquidacion'),
        es_contribuyente: fd.get('es_contribuyente') === 'on',
      }
      const boton = ev.target.querySelector('button[type="submit"]')
      boton.disabled = true
      try {
        if (esNuevo) {
          const [creado] = await api.insert('consignadores', valores)
          estado.consignadores.push(creado)
          estado.consignadores.sort((a, b) => a.nombre.localeCompare(b.nombre))
          mostrarToast('Consignador creado', 'exito')
        } else {
          const [actualizado] = await api.update('consignadores', c.id, valores)
          const idx = estado.consignadores.findIndex((x) => x.id === c.id)
          estado.consignadores[idx] = actualizado
          mostrarToast('Cambios guardados', 'exito')
        }
        estado.consignadorEditando = null
        dibujar()
      } finally {
        boton.disabled = false
      }
    })
  }

  // ---------- Recepción ----------
  function dibujarRecepcion(contenido) {
    contenido.innerHTML = `
      <form id="form-recepcion" class="tarjeta-form" style="max-width:720px">
        <div class="form-grid">
          <label>Consignador
            <select name="consignador_id" id="rec-consignador" required>
              <option value="">— Selecciona —</option>
              ${estado.consignadores.map((c) => `<option value="${c.id}" data-comision="${c.comision_pct_default}">${escaparHtml(c.nombre)}</option>`).join('')}
            </select>
          </label>
          <label>Almacén
            <select name="almacen_id" required>
              <option value="">— Selecciona —</option>
              ${estado.almacenes.map((a) => `<option value="${a.id}">${escaparHtml(a.nombre)}</option>`).join('')}
            </select>
          </label>
        </div>
        <div id="lineas-recepcion"></div>
        <button type="button" class="btn-secundario" id="btn-add-linea">+ Agregar pieza</button>
        <label>Notas
          <input name="notas" />
        </label>
        <div class="form-acciones">
          <button type="submit" class="btn-primario">Registrar recepción</button>
        </div>
      </form>
    `

    const lineasEl = contenido.querySelector('#lineas-recepcion')
    const consignadorSel = contenido.querySelector('#rec-consignador')

    function dibujarLineas() {
      lineasEl.innerHTML = estado.lineasRecepcion
        .map(
          (l, i) => `
        <div class="form-grid form-grid-linea" data-idx="${i}">
          <label>Pieza
            <select class="l-producto">
              <option value="">—</option>
              ${estado.productos.map((p) => `<option value="${p.id}" ${l.producto_id === p.id ? 'selected' : ''}>${escaparHtml(p.sku)}</option>`).join('')}
            </select>
          </label>
          <label>Cantidad
            <input type="number" step="0.001" min="0.001" class="l-cantidad" value="${l.cantidad}" />
          </label>
          <label>Precio pactado
            <input type="number" step="0.01" min="0" class="l-precio" value="${l.precio_pactado}" />
          </label>
          <label>% Comisión
            <input type="number" step="0.01" min="0" max="100" class="l-comision" value="${l.comision_pct}" placeholder="default" />
          </label>
          ${estado.lineasRecepcion.length > 1 ? `<button type="button" class="btn-secundario btn-quitar-linea" data-idx="${i}">Quitar</button>` : ''}
        </div>`
        )
        .join('')

      lineasEl.querySelectorAll('.l-producto').forEach((s, i) => s.addEventListener('change', () => (estado.lineasRecepcion[i].producto_id = s.value)))
      lineasEl.querySelectorAll('.l-cantidad').forEach((s, i) => s.addEventListener('input', () => (estado.lineasRecepcion[i].cantidad = s.value)))
      lineasEl.querySelectorAll('.l-precio').forEach((s, i) => s.addEventListener('input', () => (estado.lineasRecepcion[i].precio_pactado = s.value)))
      lineasEl.querySelectorAll('.l-comision').forEach((s, i) => s.addEventListener('input', () => (estado.lineasRecepcion[i].comision_pct = s.value)))
      lineasEl.querySelectorAll('.btn-quitar-linea').forEach((btn) =>
        btn.addEventListener('click', () => {
          estado.lineasRecepcion.splice(Number(btn.dataset.idx), 1)
          dibujarLineas()
        })
      )
    }
    dibujarLineas()

    contenido.querySelector('#btn-add-linea').addEventListener('click', () => {
      const comisionDefault = consignadorSel.selectedOptions[0]?.dataset.comision || ''
      estado.lineasRecepcion.push({ producto_id: '', cantidad: '', precio_pactado: '', comision_pct: comisionDefault })
      dibujarLineas()
    })

    contenido.querySelector('#form-recepcion').addEventListener('submit', async (ev) => {
      ev.preventDefault()
      const fd = new FormData(ev.target)
      const lineas = estado.lineasRecepcion
        .filter((l) => l.producto_id && l.cantidad)
        .map((l) => ({
          producto_id: l.producto_id,
          cantidad: Number(l.cantidad),
          precio_pactado: Number(l.precio_pactado || 0),
          comision_pct: l.comision_pct === '' ? null : Number(l.comision_pct),
        }))
      if (!lineas.length) {
        mostrarToast('Agrega al menos una pieza')
        return
      }
      const boton = ev.target.querySelector('button[type="submit"]')
      boton.disabled = true
      try {
        const resultado = await api.rpc('registrar_recepcion_consignacion', {
          p_consignador_id: fd.get('consignador_id'),
          p_almacen_id: fd.get('almacen_id'),
          p_lineas: lineas,
          p_notas: fd.get('notas') || null,
        })
        mostrarToast(`Recepción ${resultado.numero} registrada (${resultado.piezas} piezas)`, 'exito')
        ev.target.reset()
        estado.lineasRecepcion = [{ producto_id: '', cantidad: '', precio_pactado: '', comision_pct: '' }]
        estado.existencias = await api.select('v_existencias', (q) => q.eq('propiedad', 'consignacion').order('sku'))
        dibujarRecepcion(contenido)
      } finally {
        boton.disabled = false
      }
    })
  }

  // ---------- Devolución ----------
  function dibujarDevolucion(contenido) {
    contenido.innerHTML = `
      <label class="selector-consignador">Consignador
        <select id="dev-consignador" class="input-buscar" style="max-width:360px">
          <option value="">— Selecciona —</option>
          ${estado.consignadores.map((c) => `<option value="${c.id}">${escaparHtml(c.nombre)}</option>`).join('')}
        </select>
      </label>
      <div id="dev-lotes"></div>
    `
    const lotesEl = contenido.querySelector('#dev-lotes')
    contenido.querySelector('#dev-consignador').addEventListener('change', (ev) => dibujarLotesDevolucion(ev.target.value))

    function dibujarLotesDevolucion(consignadorId) {
      const lotes = estado.existencias.filter((e) => e.consignador_id === consignadorId)
      if (!consignadorId) {
        lotesEl.innerHTML = ''
        return
      }
      if (!lotes.length) {
        lotesEl.innerHTML = `<p class="seccion-pendiente">Este consignador no tiene existencias.</p>`
        return
      }
      lotesEl.innerHTML = `
        <table class="tabla">
          <thead><tr><th>SKU</th><th>Descripción</th><th>Disponible</th><th>A devolver</th></tr></thead>
          <tbody>
            ${lotes
              .map(
                (l) => `
              <tr>
                <td>${escaparHtml(l.sku)}</td>
                <td>${escaparHtml(l.descripcion)}</td>
                <td>${l.cantidad_disponible}</td>
                <td><input type="number" step="0.001" min="0" max="${l.cantidad_disponible}" class="input-conteo dev-cantidad" data-lote="${l.lote_id}" value="0" /></td>
              </tr>`
              )
              .join('')}
          </tbody>
        </table>
        <div class="form-acciones">
          <button type="button" class="btn-primario" id="btn-confirmar-devolucion">Confirmar devolución</button>
        </div>
      `
      lotesEl.querySelector('#btn-confirmar-devolucion').addEventListener('click', async (ev) => {
        const lineas = [...lotesEl.querySelectorAll('.dev-cantidad')]
          .filter((i) => Number(i.value) > 0)
          .map((i) => ({ lote_id: i.dataset.lote, cantidad: Number(i.value) }))
        if (!lineas.length) {
          mostrarToast('Indica la cantidad a devolver en al menos una pieza')
          return
        }
        ev.target.disabled = true
        try {
          const resultado = await api.rpc('devolver_a_consignador', {
            p_consignador_id: consignadorId,
            p_lineas: lineas,
          })
          mostrarToast(`Devolución ${resultado.numero} registrada (${resultado.piezas} piezas)`, 'exito')
          estado.existencias = await api.select('v_existencias', (q) => q.eq('propiedad', 'consignacion').order('sku'))
          dibujarLotesDevolucion(consignadorId)
        } finally {
          ev.target.disabled = false
        }
      })
    }
  }

  // ---------- Existencias por consignador ----------
  function dibujarExistencias(contenido) {
    contenido.innerHTML = `
      <table class="tabla">
        <thead><tr><th>Consignador</th><th>SKU</th><th>Descripción</th><th>Cantidad</th><th>Precio pactado</th><th>% Comisión</th><th>Días</th></tr></thead>
        <tbody>
          ${estado.existencias
            .map(
              (e) => `
            <tr>
              <td>${escaparHtml(e.consignador)}</td>
              <td>${escaparHtml(e.sku)}</td>
              <td>${escaparHtml(e.descripcion)}</td>
              <td>${e.cantidad_disponible}</td>
              <td>${formatoMoneda(e.precio_venta)}</td>
              <td>${e.comision_pct}%</td>
              <td>${e.dias_en_inventario > estado.diasAlerta ? `<span class="badge badge-alerta">${e.dias_en_inventario}</span>` : e.dias_en_inventario}</td>
            </tr>`
            )
            .join('') || `<tr><td colspan="7" class="tabla-vacia">Sin existencias en consignación.</td></tr>`}
        </tbody>
      </table>
      <p class="nota-ayuda">Resaltado: piezas con más de ${estado.diasAlerta} días en inventario sin venderse.</p>
    `
  }
}

function formatoMoneda(valor) {
  return new Intl.NumberFormat('es-DO', { style: 'currency', currency: 'DOP' }).format(valor || 0)
}

function escaparHtml(texto) {
  const div = document.createElement('div')
  div.textContent = texto ?? ''
  return div.innerHTML
}

function escaparAttr(texto) {
  return escaparHtml(texto).replaceAll('"', '&quot;')
}
