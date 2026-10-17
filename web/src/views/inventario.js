import { api } from '../api.js'
import { mostrarToast } from '../toast.js'

export async function renderInventario(el) {
  const estado = {
    pestana: 'existencias',
    existencias: [],
    productos: [],
    almacenes: [],
    conteoActivo: null, // { id, numero, lineas: [...] }
    filtroExistencias: '',
  }

  el.innerHTML = `<p class="cargando">Cargando inventario…</p>`

  try {
    const [existencias, productos, almacenes] = await Promise.all([
      api.select('v_existencias', (q) => q.order('sku')),
      api.select('productos', (q) => q.eq('activo', true).eq('es_servicio', false).order('sku')),
      api.select('almacenes', (q) => q.eq('activo', true).order('nombre')),
    ])
    estado.existencias = existencias
    estado.productos = productos
    estado.almacenes = almacenes
  } catch {
    el.innerHTML = `<p class="seccion-pendiente">No se pudo cargar el inventario.</p>`
    return
  }

  dibujar()

  function dibujar() {
    el.innerHTML = `
      <div class="pantalla-header">
        <h2>Inventario</h2>
      </div>
      <div class="tabs">
        <button class="tab ${estado.pestana === 'existencias' ? 'tab-activo' : ''}" data-tab="existencias">Existencias</button>
        <button class="tab ${estado.pestana === 'recibir' ? 'tab-activo' : ''}" data-tab="recibir">Recibir stock</button>
        <button class="tab ${estado.pestana === 'conteo' ? 'tab-activo' : ''}" data-tab="conteo">Conteo físico</button>
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
    if (estado.pestana === 'existencias') dibujarExistencias(contenido)
    else if (estado.pestana === 'recibir') dibujarRecibir(contenido)
    else dibujarConteo(contenido)
  }

  function dibujarExistencias(contenido) {
    const filtro = estado.filtroExistencias.trim().toLowerCase()
    const filas = estado.existencias.filter((e) => {
      if (!filtro) return true
      return (
        e.sku.toLowerCase().includes(filtro) ||
        e.descripcion.toLowerCase().includes(filtro) ||
        (e.numero_oem || '').toLowerCase().includes(filtro)
      )
    })

    contenido.innerHTML = `
      <input type="search" id="buscador-existencias" class="input-buscar" placeholder="Buscar por SKU, descripción o número OEM…" value="${escaparAttr(estado.filtroExistencias)}" />
      <table class="tabla">
        <thead>
          <tr><th>SKU</th><th>Descripción</th><th>Propiedad</th><th>Almacén</th><th>Cantidad</th><th>Precio</th><th>Días en inventario</th></tr>
        </thead>
        <tbody>
          ${filas
            .map(
              (e) => `
            <tr>
              <td>${escaparHtml(e.sku)}</td>
              <td>${escaparHtml(e.descripcion)}</td>
              <td><span class="badge badge-${e.propiedad}">${e.propiedad === 'propia' ? 'Propia' : escaparHtml(e.consignador || 'Consignación')}</span></td>
              <td>${escaparHtml(e.almacen)}</td>
              <td>${e.cantidad_disponible}</td>
              <td>${formatoMoneda(e.precio_venta)}</td>
              <td>${e.dias_en_inventario}</td>
            </tr>`
            )
            .join('') ||
          `<tr><td colspan="7" class="tabla-vacia">${estado.existencias.length ? 'Sin existencias que coincidan.' : 'Sin existencias.'}</td></tr>`}
        </tbody>
      </table>
    `

    const buscador = contenido.querySelector('#buscador-existencias')
    buscador.addEventListener('input', (ev) => {
      estado.filtroExistencias = ev.target.value
      dibujarExistencias(contenido)
      contenido.querySelector('#buscador-existencias').focus()
      const valor = contenido.querySelector('#buscador-existencias').value
      contenido.querySelector('#buscador-existencias').setSelectionRange(valor.length, valor.length)
    })
  }

  function dibujarRecibir(contenido) {
    contenido.innerHTML = `
      <form id="form-recibir" class="tarjeta-form">
        <label>Pieza
          <select name="producto_id" required>
            <option value="">— Selecciona —</option>
            ${estado.productos.map((p) => `<option value="${p.id}">${escaparHtml(p.sku)} — ${escaparHtml(p.descripcion)}</option>`).join('')}
          </select>
        </label>
        <label>Almacén
          <select name="almacen_id" required>
            <option value="">— Selecciona —</option>
            ${estado.almacenes.map((a) => `<option value="${a.id}">${escaparHtml(a.nombre)}</option>`).join('')}
          </select>
        </label>
        <div class="form-grid">
          <label>Cantidad
            <input name="cantidad" type="number" step="0.001" min="0.001" required />
          </label>
          <label>Costo unitario
            <input name="costo_unitario" type="number" step="0.0001" min="0" required />
          </label>
        </div>
        <label>Notas
          <input name="notas" />
        </label>
        <div class="form-acciones">
          <button type="submit" class="btn-primario">Recibir stock</button>
        </div>
      </form>
    `
    contenido.querySelector('#form-recibir').addEventListener('submit', async (ev) => {
      ev.preventDefault()
      const fd = new FormData(ev.target)
      const boton = ev.target.querySelector('button[type="submit"]')
      boton.disabled = true
      try {
        const resultado = await api.rpc('recibir_stock_propio', {
          p_producto_id: fd.get('producto_id'),
          p_almacen_id: fd.get('almacen_id'),
          p_cantidad: Number(fd.get('cantidad')),
          p_costo_unitario: Number(fd.get('costo_unitario')),
          p_notas: fd.get('notas') || null,
        })
        mostrarToast(`Recepción ${resultado.numero} registrada`, 'exito')
        ev.target.reset()
        estado.existencias = await api.select('v_existencias', (q) => q.order('sku'))
      } finally {
        boton.disabled = false
      }
    })
  }

  function dibujarConteo(contenido) {
    if (!estado.conteoActivo) {
      contenido.innerHTML = `
        <form id="form-conteo" class="tarjeta-form">
          <label>Almacén a contar
            <select name="almacen_id" required>
              <option value="">— Selecciona —</option>
              ${estado.almacenes.map((a) => `<option value="${a.id}">${escaparHtml(a.nombre)}</option>`).join('')}
            </select>
          </label>
          <div class="form-acciones">
            <button type="submit" class="btn-primario">Iniciar conteo</button>
          </div>
        </form>
      `
      contenido.querySelector('#form-conteo').addEventListener('submit', async (ev) => {
        ev.preventDefault()
        const almacenId = new FormData(ev.target).get('almacen_id')
        const resultado = await api.rpc('crear_conteo_fisico', { p_almacen_id: almacenId })
        const lineas = await api.select('conteos_fisicos_lineas', (q) => q.eq('conteo_id', resultado.id))
        estado.conteoActivo = { ...resultado, lineas }
        dibujar()
      })
      return
    }

    const conteo = estado.conteoActivo
    contenido.innerHTML = `
      <div class="tarjeta-form">
        <h3>Conteo ${escaparHtml(conteo.numero)}</h3>
        ${
          conteo.lineas.length
            ? `<table class="tabla">
                <thead><tr><th>Lote</th><th>Sistema</th><th>Contado</th></tr></thead>
                <tbody>
                  ${conteo.lineas
                    .map(
                      (l) => `
                    <tr>
                      <td>${l.lote_id.slice(0, 8)}…</td>
                      <td>${l.cantidad_sistema}</td>
                      <td><input type="number" step="0.001" min="0" class="input-conteo" data-linea="${l.id}" value="${l.cantidad_contada}" /></td>
                    </tr>`
                    )
                    .join('')}
                </tbody>
              </table>`
            : `<p class="seccion-pendiente">Este almacén no tiene existencias para contar.</p>`
        }
        <div class="form-acciones">
          <button type="button" class="btn-secundario" id="btn-cancelar-conteo">Cancelar</button>
          <button type="button" class="btn-primario" id="btn-confirmar-conteo">Confirmar ajuste</button>
        </div>
      </div>
    `

    contenido.querySelector('#btn-cancelar-conteo').addEventListener('click', () => {
      estado.conteoActivo = null
      dibujar()
    })

    contenido.querySelectorAll('.input-conteo').forEach((input) => {
      input.addEventListener('change', async () => {
        await api.rpc('actualizar_conteo_linea', {
          p_linea_id: input.dataset.linea,
          p_cantidad_contada: Number(input.value),
        })
      })
    })

    contenido.querySelector('#btn-confirmar-conteo').addEventListener('click', async (ev) => {
      ev.target.disabled = true
      try {
        const resultado = await api.rpc('registrar_ajuste_inventario', { p_conteo_id: conteo.id })
        mostrarToast(
          resultado.diferencias > 0
            ? `Ajuste ${resultado.numero}: ${resultado.diferencias} diferencia(s), valor ${formatoMoneda(resultado.valor_diferencia)}`
            : `Ajuste ${resultado.numero}: sin diferencias`,
          'exito'
        )
        estado.conteoActivo = null
        estado.existencias = await api.select('v_existencias', (q) => q.order('sku'))
        dibujar()
      } finally {
        ev.target.disabled = false
      }
    })
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
