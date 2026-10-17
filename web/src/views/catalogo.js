import { api } from '../api.js'
import { mostrarToast } from '../toast.js'

const CALIDADES = ['genuina', 'oem', 'aftermarket', 'usada']

export async function renderCatalogo(el) {
  const estado = {
    productos: [],
    categorias: [],
    marcas: [],
    modelos: [],
    filtro: '',
    productoEditando: null, // null = lista; {} = nuevo; {...} = editar
  }

  el.innerHTML = `<p class="cargando">Cargando catálogo…</p>`

  try {
    const [productos, categorias, marcas, modelos] = await Promise.all([
      api.select('productos', (q) => q.order('created_at', { ascending: false })),
      api.select('categorias', (q) => q.order('nombre')),
      api.select('marcas_vehiculo', (q) => q.order('nombre')),
      api.select('modelos_vehiculo', (q) => q.order('nombre')),
    ])
    estado.productos = productos
    estado.categorias = categorias
    estado.marcas = marcas
    estado.modelos = modelos
  } catch {
    el.innerHTML = `<p class="seccion-pendiente">No se pudo cargar el catálogo.</p>`
    return
  }

  dibujar()

  function dibujar() {
    if (estado.productoEditando !== null) {
      dibujarFormulario()
    } else {
      dibujarLista()
    }
  }

  function dibujarLista() {
    const filtro = estado.filtro.trim().toLowerCase()
    const filas = estado.productos.filter((p) => {
      if (!filtro) return true
      return (
        p.sku.toLowerCase().includes(filtro) ||
        p.descripcion.toLowerCase().includes(filtro) ||
        (p.numero_oem || '').toLowerCase().includes(filtro)
      )
    })

    el.innerHTML = `
      <div class="pantalla-header">
        <h2>Catálogo</h2>
        <button class="btn-primario" id="btn-nueva-pieza">+ Nueva pieza</button>
      </div>
      <input type="search" id="buscador" class="input-buscar" placeholder="Buscar por SKU, descripción o número OEM…" value="${escaparHtml(estado.filtro)}" />
      <table class="tabla">
        <thead>
          <tr><th>SKU</th><th>Descripción</th><th>Categoría</th><th>Calidad</th><th>Precio</th><th>Activo</th></tr>
        </thead>
        <tbody>
          ${filas
            .map(
              (p) => `
            <tr data-id="${p.id}" class="fila-click">
              <td>${escaparHtml(p.sku)}</td>
              <td>${escaparHtml(p.descripcion)}</td>
              <td>${escaparHtml(nombreCategoria(p.categoria_id))}</td>
              <td>${escaparHtml(p.calidad || '—')}</td>
              <td>${formatoMoneda(p.precio_venta)}</td>
              <td>${p.activo ? 'Sí' : 'No'}</td>
            </tr>`
            )
            .join('') || `<tr><td colspan="6" class="tabla-vacia">Sin piezas que coincidan.</td></tr>`}
        </tbody>
      </table>
    `

    el.querySelector('#btn-nueva-pieza').addEventListener('click', () => {
      estado.productoEditando = {}
      dibujar()
    })
    el.querySelector('#buscador').addEventListener('input', (ev) => {
      estado.filtro = ev.target.value
      dibujarLista()
    })
    el.querySelectorAll('.fila-click').forEach((tr) => {
      tr.addEventListener('click', () => {
        estado.productoEditando = estado.productos.find((p) => p.id === tr.dataset.id)
        dibujar()
      })
    })
  }

  function nombreCategoria(id) {
    return estado.categorias.find((c) => c.id === id)?.nombre || '—'
  }

  function dibujarFormulario() {
    const p = estado.productoEditando
    const esNuevo = !p.id

    el.innerHTML = `
      <div class="pantalla-header">
        <h2>${esNuevo ? 'Nueva pieza' : 'Editar pieza'}</h2>
        <button class="btn-secundario" id="btn-volver">← Volver al catálogo</button>
      </div>
      <form id="form-producto" class="tarjeta-form">
        <div class="form-grid">
          <label>SKU
            <input name="sku" required value="${escaparAttr(p.sku || '')}" />
          </label>
          <label>Número OEM
            <input name="numero_oem" value="${escaparAttr(p.numero_oem || '')}" />
          </label>
        </div>
        <label>Descripción
          <input name="descripcion" required value="${escaparAttr(p.descripcion || '')}" />
        </label>
        <div class="form-grid">
          <label>Categoría
            <select name="categoria_id">
              <option value="">— Sin categoría —</option>
              ${estado.categorias.map((c) => `<option value="${c.id}" ${p.categoria_id === c.id ? 'selected' : ''}>${escaparHtml(c.nombre)}</option>`).join('')}
            </select>
          </label>
          <label>Calidad
            <select name="calidad">
              <option value="">—</option>
              ${CALIDADES.map((c) => `<option value="${c}" ${p.calidad === c ? 'selected' : ''}>${c}</option>`).join('')}
            </select>
          </label>
        </div>
        <div class="form-grid">
          <label>Precio de venta
            <input name="precio_venta" type="number" step="0.01" min="0" required value="${p.precio_venta ?? 0}" />
          </label>
          <label>Precio mínimo
            <input name="precio_minimo" type="number" step="0.01" min="0" required value="${p.precio_minimo ?? 0}" />
          </label>
        </div>
        <div class="form-grid">
          <label>Stock mínimo
            <input name="stock_minimo" type="number" step="0.001" min="0" value="${p.stock_minimo ?? 0}" />
          </label>
          <label class="form-check">
            <input name="aplica_itbis" type="checkbox" ${p.aplica_itbis !== false ? 'checked' : ''} />
            Aplica ITBIS
          </label>
        </div>
        <div class="form-acciones">
          <button type="submit" class="btn-primario">${esNuevo ? 'Crear pieza' : 'Guardar cambios'}</button>
        </div>
      </form>
      ${esNuevo ? '' : dibujarCompatibilidadesHtml(p.id)}
    `

    el.querySelector('#btn-volver').addEventListener('click', () => {
      estado.productoEditando = null
      dibujar()
    })

    el.querySelector('#form-producto').addEventListener('submit', async (ev) => {
      ev.preventDefault()
      const fd = new FormData(ev.target)
      const valores = {
        sku: fd.get('sku').trim(),
        descripcion: fd.get('descripcion').trim(),
        numero_oem: fd.get('numero_oem')?.trim() || null,
        categoria_id: fd.get('categoria_id') || null,
        calidad: fd.get('calidad') || null,
        precio_venta: Number(fd.get('precio_venta')),
        precio_minimo: Number(fd.get('precio_minimo')),
        stock_minimo: Number(fd.get('stock_minimo') || 0),
        aplica_itbis: fd.get('aplica_itbis') === 'on',
      }
      const boton = ev.target.querySelector('button[type="submit"]')
      boton.disabled = true
      try {
        if (esNuevo) {
          const [creado] = await api.insert('productos', valores)
          estado.productos.unshift(creado)
          mostrarToast('Pieza creada', 'exito')
          estado.productoEditando = creado
        } else {
          const [actualizado] = await api.update('productos', p.id, valores)
          const idx = estado.productos.findIndex((x) => x.id === p.id)
          estado.productos[idx] = actualizado
          mostrarToast('Cambios guardados', 'exito')
          estado.productoEditando = actualizado
        }
        dibujar()
      } catch {
        boton.disabled = false
      }
    })

    if (!esNuevo) wireCompatibilidades(p.id)
  }

  function dibujarCompatibilidadesHtml(productoId) {
    return `
      <div class="tarjeta-form" id="panel-compat">
        <h3>Compatibilidades</h3>
        <div id="lista-compat">Cargando…</div>
        <div class="form-grid form-grid-compat">
          <label>Marca
            <select id="compat-marca">
              <option value="">—</option>
              ${estado.marcas.map((m) => `<option value="${m.id}">${escaparHtml(m.nombre)}</option>`).join('')}
            </select>
          </label>
          <label>Modelo
            <select id="compat-modelo" disabled>
              <option value="">— Elige marca primero —</option>
            </select>
          </label>
          <label>Año desde
            <input id="compat-desde" type="number" min="1980" max="2100" />
          </label>
          <label>Año hasta
            <input id="compat-hasta" type="number" min="1980" max="2100" />
          </label>
        </div>
        <button type="button" class="btn-secundario" id="btn-add-compat">+ Agregar compatibilidad</button>
        <p class="nota-ayuda">¿No existe el modelo? Créalo primero desde un futuro módulo de catálogo de vehículos, o pide a un admin que lo agregue.</p>
      </div>
    `
  }

  async function wireCompatibilidades(productoId) {
    const listaEl = el.querySelector('#lista-compat')
    const marcaSel = el.querySelector('#compat-marca')
    const modeloSel = el.querySelector('#compat-modelo')

    async function cargarLista() {
      const compats = await api.select('compatibilidades', (q) =>
        q.eq('producto_id', productoId)
      )
      if (!compats.length) {
        listaEl.innerHTML = `<p class="seccion-pendiente">Sin compatibilidades registradas.</p>`
        return
      }
      listaEl.innerHTML = `<ul class="lista-compat">${compats
        .map((c) => {
          const modelo = estado.modelos.find((m) => m.id === c.modelo_id)
          const marca = estado.marcas.find((m) => m.id === modelo?.marca_id)
          const rango = c.anio_desde || c.anio_hasta ? ` (${c.anio_desde ?? ''}–${c.anio_hasta ?? ''})` : ''
          return `<li>${escaparHtml(marca?.nombre || '?')} ${escaparHtml(modelo?.nombre || '?')}${rango}</li>`
        })
        .join('')}</ul>`
    }
    await cargarLista()

    marcaSel.addEventListener('change', () => {
      const modelos = estado.modelos.filter((m) => m.marca_id === marcaSel.value)
      modeloSel.disabled = !marcaSel.value
      modeloSel.innerHTML = marcaSel.value
        ? modelos.map((m) => `<option value="${m.id}">${escaparHtml(m.nombre)}</option>`).join('') ||
          '<option value="">Sin modelos para esta marca</option>'
        : '<option value="">— Elige marca primero —</option>'
    })

    el.querySelector('#btn-add-compat').addEventListener('click', async () => {
      if (!modeloSel.value) {
        mostrarToast('Elige un modelo')
        return
      }
      const desde = el.querySelector('#compat-desde').value
      const hasta = el.querySelector('#compat-hasta').value
      try {
        await api.insert('compatibilidades', {
          producto_id: productoId,
          modelo_id: modeloSel.value,
          anio_desde: desde ? Number(desde) : null,
          anio_hasta: hasta ? Number(hasta) : null,
        })
        mostrarToast('Compatibilidad agregada', 'exito')
        await cargarLista()
      } catch {
        // el toast de error ya lo muestra api.insert
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
