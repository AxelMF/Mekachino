import { api } from '../api.js'
import { mostrarToast } from '../toast.js'
import { supabase } from '../supabaseClient.js'

export async function renderPos(el) {
  el.innerHTML = `<p class="cargando">Cargando POS…</p>`

  const { data: auth } = await supabase.auth.getUser()
  const sesiones = await api.select('sesiones_caja', (q) => q.eq('usuario', auth.user.id).eq('estado', 'abierta'))
  if (!sesiones.length) {
    el.innerHTML = `
      <div class="pantalla-header"><h2>POS / Nueva venta</h2></div>
      <p class="seccion-pendiente">Debes abrir tu caja antes de vender. Ve a <a href="#/caja">Caja</a>.</p>
    `
    return
  }

  const estado = {
    clientes: [],
    config: null,
    lotes: [], // v_existencias (piezas con stock)
    servicios: [], // productos es_servicio = true
    cuentas: [],
    lineas: [], // { tipo:'pieza'|'servicio', lote_id|producto_id, sku, descripcion, cantidad, precio_unitario, descuento, maxDisponible, aplicaItbis }
    condicion: 'contado',
    pagos: [{ cuenta_id: '', metodo: 'efectivo', monto: '' }],
    clienteId: '',
    canal: 'mostrador',
  }

  try {
    const [clientes, config, lotes, servicios, cuentas] = await Promise.all([
      api.select('clientes', (q) => q.eq('activo', true).order('nombre')),
      api.select('configuracion'),
      api.select('v_existencias', (q) => q.order('sku')),
      api.select('productos', (q) => q.eq('es_servicio', true).eq('activo', true).order('sku')),
      api.select('cuentas_financieras', (q) => q.eq('activo', true)),
    ])
    estado.clientes = clientes
    estado.config = config[0]
    estado.lotes = lotes
    estado.servicios = servicios
    estado.cuentas = cuentas
  } catch {
    el.innerHTML = `<p class="seccion-pendiente">No se pudo cargar el POS.</p>`
    return
  }

  dibujar()

  function dibujar() {
    const totales = calcularTotales()
    el.innerHTML = `
      <div class="pantalla-header"><h2>POS / Nueva venta</h2></div>
      <div class="form-grid">
        <label>Cliente ${estado.condicion === 'credito' ? '(obligatorio)' : '(opcional)'}
          <select id="pos-cliente">
            <option value="" ${!estado.clienteId ? 'selected' : ''}>— Consumidor final —</option>
            ${estado.clientes.map((c) => `<option value="${c.id}" ${estado.clienteId === c.id ? 'selected' : ''}>${escaparHtml(c.nombre)}</option>`).join('')}
          </select>
        </label>
        <label>Canal
          <select id="pos-canal">
            <option value="mostrador" ${estado.canal === 'mostrador' ? 'selected' : ''}>Mostrador</option>
            <option value="whatsapp" ${estado.canal === 'whatsapp' ? 'selected' : ''}>WhatsApp</option>
            <option value="instagram" ${estado.canal === 'instagram' ? 'selected' : ''}>Instagram</option>
            <option value="marketplace" ${estado.canal === 'marketplace' ? 'selected' : ''}>Marketplace</option>
            <option value="otro" ${estado.canal === 'otro' ? 'selected' : ''}>Otro</option>
          </select>
        </label>
      </div>

      <div id="pos-lineas"></div>
      <div class="form-acciones">
        <button type="button" class="btn-secundario" id="btn-add-pieza">+ Agregar pieza</button>
        <button type="button" class="btn-secundario" id="btn-add-servicio">+ Agregar servicio</button>
      </div>

      <div class="tarjeta-form pos-totales">
        <div class="pos-totales-fila"><span>Subtotal</span><span>${formatoMoneda(totales.subtotal)}</span></div>
        <div class="pos-totales-fila"><span>Descuento</span><span>-${formatoMoneda(totales.descuento)}</span></div>
        <div class="pos-totales-fila"><span>ITBIS</span><span>${formatoMoneda(totales.itbis)}</span></div>
        <div class="pos-totales-fila pos-totales-total"><span>Total</span><span>${formatoMoneda(totales.total)}</span></div>
      </div>

      <div class="form-grid">
        <label>Tipo de pago
          <select id="pos-condicion">
            <option value="contado" ${estado.condicion === 'contado' ? 'selected' : ''}>Contado</option>
            <option value="credito" ${estado.condicion === 'credito' ? 'selected' : ''}>Crédito</option>
          </select>
        </label>
      </div>

      <div id="pos-pagos"></div>
      <button type="button" class="btn-secundario" id="btn-add-pago">+ Agregar pago</button>

      <div class="form-acciones">
        <button type="button" class="btn-primario" id="btn-cobrar-venta">Registrar venta</button>
      </div>
    `

    el.querySelector('#pos-condicion').addEventListener('change', (ev) => {
      estado.condicion = ev.target.value
      dibujar()
    })
    el.querySelector('#pos-cliente').addEventListener('change', (ev) => {
      estado.clienteId = ev.target.value
    })
    el.querySelector('#pos-canal').addEventListener('change', (ev) => {
      estado.canal = ev.target.value
    })

    dibujarLineas()
    dibujarPagos()

    el.querySelector('#btn-add-pieza').addEventListener('click', () => {
      estado.lineas.push({ tipo: 'pieza', lote_id: '', cantidad: 1, precio_unitario: 0, descuento: 0, maxDisponible: 0, aplicaItbis: true })
      dibujar()
    })
    el.querySelector('#btn-add-servicio').addEventListener('click', () => {
      estado.lineas.push({ tipo: 'servicio', producto_id: '', cantidad: 1, precio_unitario: 0, descuento: 0, aplicaItbis: true })
      dibujar()
    })
    el.querySelector('#btn-add-pago').addEventListener('click', () => {
      estado.pagos.push({ cuenta_id: '', metodo: 'efectivo', monto: '' })
      dibujarPagos()
    })

    el.querySelector('#btn-cobrar-venta').addEventListener('click', registrarVenta)
  }

  function dibujarLineas() {
    const cont = el.querySelector('#pos-lineas')
    cont.innerHTML = estado.lineas
      .map((l, i) => {
        if (l.tipo === 'pieza') {
          return `
          <div class="form-grid form-grid-pos" data-idx="${i}">
            <label>Pieza (lote)
              <select class="pos-lote">
                <option value="">— Selecciona —</option>
                ${estado.lotes
                  .map(
                    (lo) =>
                      `<option value="${lo.lote_id}" ${l.lote_id === lo.lote_id ? 'selected' : ''}>${escaparHtml(lo.sku)} · ${lo.propiedad === 'propia' ? 'Propia' : escaparHtml(lo.consignador)} · disp ${lo.cantidad_disponible}</option>`
                  )
                  .join('')}
              </select>
            </label>
            <label>Cantidad
              <input type="number" step="0.001" min="0.001" max="${l.maxDisponible || ''}" class="pos-cantidad" value="${l.cantidad}" />
            </label>
            <label>Precio
              <input type="number" step="0.01" min="0" class="pos-precio" value="${l.precio_unitario}" />
            </label>
            <label>Descuento
              <input type="number" step="0.01" min="0" class="pos-descuento" value="${l.descuento}" />
            </label>
            <button type="button" class="btn-secundario btn-quitar-pos" data-idx="${i}">Quitar</button>
          </div>`
        }
        return `
          <div class="form-grid form-grid-pos" data-idx="${i}">
            <label>Servicio
              <select class="pos-servicio">
                <option value="">— Selecciona —</option>
                ${estado.servicios.map((s) => `<option value="${s.id}" ${l.producto_id === s.id ? 'selected' : ''}>${escaparHtml(s.sku)} — ${escaparHtml(s.descripcion)}</option>`).join('')}
              </select>
            </label>
            <label>Cantidad
              <input type="number" step="1" min="1" class="pos-cantidad" value="${l.cantidad}" />
            </label>
            <label>Precio
              <input type="number" step="0.01" min="0" class="pos-precio" value="${l.precio_unitario}" />
            </label>
            <label>Descuento
              <input type="number" step="0.01" min="0" class="pos-descuento" value="${l.descuento}" />
            </label>
            <button type="button" class="btn-secundario btn-quitar-pos" data-idx="${i}">Quitar</button>
          </div>`
      })
      .join('')

    const idxDe = (elemento) => Number(elemento.closest('[data-idx]').dataset.idx)

    cont.querySelectorAll('.pos-lote').forEach((s) =>
      s.addEventListener('change', () => {
        const i = idxDe(s)
        const lote = estado.lotes.find((lo) => lo.lote_id === s.value)
        estado.lineas[i].lote_id = s.value
        estado.lineas[i].maxDisponible = lote ? Number(lote.cantidad_disponible) : 0
        estado.lineas[i].precio_unitario = lote ? Number(lote.precio_venta) : 0
        dibujar()
      })
    )
    cont.querySelectorAll('.pos-servicio').forEach((s) =>
      s.addEventListener('change', () => {
        const i = idxDe(s)
        const prod = estado.servicios.find((p) => p.id === s.value)
        estado.lineas[i].producto_id = s.value
        estado.lineas[i].precio_unitario = prod ? Number(prod.precio_venta) : 0
        dibujar()
      })
    )
    cont.querySelectorAll('.pos-cantidad').forEach((input) =>
      input.addEventListener('input', () => {
        estado.lineas[idxDe(input)].cantidad = input.value
        dibujar()
      })
    )
    cont.querySelectorAll('.pos-precio').forEach((input) =>
      input.addEventListener('input', () => {
        estado.lineas[idxDe(input)].precio_unitario = input.value
        dibujar()
      })
    )
    cont.querySelectorAll('.pos-descuento').forEach((input) =>
      input.addEventListener('input', () => {
        estado.lineas[idxDe(input)].descuento = input.value
        dibujar()
      })
    )
    cont.querySelectorAll('.btn-quitar-pos').forEach((btn) =>
      btn.addEventListener('click', () => {
        estado.lineas.splice(Number(btn.dataset.idx), 1)
        dibujar()
      })
    )
  }

  function dibujarPagos() {
    const cont = el.querySelector('#pos-pagos')
    cont.innerHTML = estado.pagos
      .map(
        (p, i) => `
      <div class="form-grid form-grid-pago" data-idx="${i}">
        <label>Cuenta
          <select class="pago-cuenta">
            <option value="">—</option>
            ${estado.cuentas.map((c) => `<option value="${c.id}" ${p.cuenta_id === c.id ? 'selected' : ''}>${escaparHtml(c.nombre)}</option>`).join('')}
          </select>
        </label>
        <label>Método
          <select class="pago-metodo">
            ${['efectivo', 'transferencia', 'tarjeta', 'cheque', 'otro']
              .map((m) => `<option value="${m}" ${p.metodo === m ? 'selected' : ''}>${m}</option>`)
              .join('')}
          </select>
        </label>
        <label>Monto
          <input type="number" step="0.01" min="0" class="pago-monto" value="${p.monto}" />
        </label>
        ${estado.pagos.length > 1 ? `<button type="button" class="btn-secundario btn-quitar-pago" data-idx="${i}">Quitar</button>` : ''}
      </div>`
      )
      .join('')

    cont.querySelectorAll('.pago-cuenta').forEach((s, i) => s.addEventListener('change', () => (estado.pagos[i].cuenta_id = s.value)))
    cont.querySelectorAll('.pago-metodo').forEach((s, i) => s.addEventListener('change', () => (estado.pagos[i].metodo = s.value)))
    cont.querySelectorAll('.pago-monto').forEach((input, i) => input.addEventListener('input', () => (estado.pagos[i].monto = input.value)))
    cont.querySelectorAll('.btn-quitar-pago').forEach((btn) =>
      btn.addEventListener('click', () => {
        estado.pagos.splice(Number(btn.dataset.idx), 1)
        dibujarPagos()
      })
    )
  }

  function calcularTotales() {
    const itbisActivo = estado.config?.modo_fiscal !== 'informal'
    let subtotal = 0
    let descuento = 0
    let itbis = 0
    for (const l of estado.lineas) {
      const cant = Number(l.cantidad) || 0
      const precio = Number(l.precio_unitario) || 0
      const desc = Number(l.descuento) || 0
      let base = precio * cant
      const pctItbis = itbisActivo && l.aplicaItbis ? Number(estado.config.tasa_itbis) : 0
      if (estado.config?.precios_incluyen_itbis && pctItbis > 0) {
        base = base / (1 + pctItbis / 100)
      }
      const baseConDescuento = Math.max(base - desc, 0)
      subtotal += base
      descuento += desc
      itbis += baseConDescuento * (pctItbis / 100)
    }
    const total = subtotal - descuento + itbis
    return { subtotal, descuento, itbis, total }
  }

  async function registrarVenta() {
    const clienteId = estado.clienteId || null
    const canal = estado.canal

    if (!estado.lineas.length) {
      mostrarToast('Agrega al menos una pieza o servicio')
      return
    }
    if (estado.condicion === 'credito' && !clienteId) {
      mostrarToast('Una venta a crédito requiere cliente')
      return
    }

    const lineasPayload = estado.lineas.map((l) => ({
      producto_id: l.tipo === 'pieza' ? estado.lotes.find((lo) => lo.lote_id === l.lote_id)?.producto_id : l.producto_id,
      lote_id: l.tipo === 'pieza' ? l.lote_id : null,
      cantidad: Number(l.cantidad),
      precio_unitario: Number(l.precio_unitario),
      descuento: Number(l.descuento) || 0,
    }))
    if (lineasPayload.some((l) => !l.producto_id || !l.cantidad)) {
      mostrarToast('Completa todas las líneas antes de continuar')
      return
    }

    const pagosPayload = estado.pagos
      .filter((p) => p.cuenta_id && Number(p.monto) > 0)
      .map((p) => ({ cuenta_id: p.cuenta_id, metodo: p.metodo, monto: Number(p.monto) }))

    const boton = el.querySelector('#btn-cobrar-venta')
    boton.disabled = true
    try {
      const resultado = await api.rpc('registrar_venta', {
        p_cliente_id: clienteId,
        p_canal: canal,
        p_lineas: lineasPayload,
        p_pagos: pagosPayload,
        p_tipo_pago: estado.condicion,
      })
      mostrarToast(`Venta ${resultado.numero} registrada — total ${formatoMoneda(resultado.total)}`, 'exito')
      estado.lineas = []
      estado.pagos = [{ cuenta_id: '', metodo: 'efectivo', monto: '' }]
      estado.clienteId = ''
      estado.condicion = 'contado'
      estado.lotes = await api.select('v_existencias', (q) => q.order('sku'))
      dibujar()
    } finally {
      boton.disabled = false
    }
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
