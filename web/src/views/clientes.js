import { api } from '../api.js'
import { mostrarToast } from '../toast.js'

export async function renderClientes(el) {
  const estado = {
    pestana: 'clientes',
    clientes: [],
    cuentas: [],
    cxc: [],
    clienteEditando: null,
    clienteCobro: null,
    ventasPendientes: [],
  }

  el.innerHTML = `<p class="cargando">Cargando clientes…</p>`

  try {
    const [clientes, cuentas, cxc] = await Promise.all([
      api.select('clientes', (q) => q.order('nombre')),
      api.select('cuentas_financieras', (q) => q.eq('activo', true)),
      api.select('v_cxc_antiguedad'),
    ])
    estado.clientes = clientes
    estado.cuentas = cuentas
    estado.cxc = cxc
  } catch {
    el.innerHTML = `<p class="seccion-pendiente">No se pudo cargar clientes.</p>`
    return
  }

  dibujar()

  function dibujar() {
    el.innerHTML = `
      <div class="pantalla-header"><h2>Clientes y CxC</h2></div>
      <div class="tabs">
        <button class="tab ${estado.pestana === 'clientes' ? 'tab-activo' : ''}" data-tab="clientes">Clientes</button>
        <button class="tab ${estado.pestana === 'cxc' ? 'tab-activo' : ''}" data-tab="cxc">Cuentas por cobrar</button>
      </div>
      <div id="tab-contenido"></div>
    `
    el.querySelectorAll('.tab').forEach((btn) =>
      btn.addEventListener('click', () => {
        estado.pestana = btn.dataset.tab
        estado.clienteEditando = null
        estado.clienteCobro = null
        dibujar()
      })
    )
    const contenido = el.querySelector('#tab-contenido')
    if (estado.pestana === 'clientes') dibujarClientes(contenido)
    else dibujarCxc(contenido)
  }

  function dibujarClientes(contenido) {
    if (estado.clienteEditando !== null) {
      dibujarFormularioCliente(contenido)
      return
    }
    contenido.innerHTML = `
      <div class="pantalla-header"><button class="btn-primario" id="btn-nuevo-cliente">+ Nuevo cliente</button></div>
      <table class="tabla">
        <thead><tr><th>Nombre</th><th>Documento</th><th>Teléfono</th><th>Taller</th><th>Crédito</th><th>Activo</th></tr></thead>
        <tbody>
          ${estado.clientes
            .map(
              (c) => `
            <tr data-id="${c.id}" class="fila-click">
              <td>${escaparHtml(c.nombre)}</td>
              <td>${escaparHtml(c.documento || '—')}</td>
              <td>${escaparHtml(c.telefono || '—')}</td>
              <td>${c.es_taller ? 'Sí' : 'No'}</td>
              <td>${c.dias_credito > 0 ? `${c.dias_credito} días / ${formatoMoneda(c.limite_credito)}` : '—'}</td>
              <td>${c.activo ? 'Sí' : 'No'}</td>
            </tr>`
            )
            .join('') || `<tr><td colspan="6" class="tabla-vacia">Sin clientes.</td></tr>`}
        </tbody>
      </table>
    `
    contenido.querySelector('#btn-nuevo-cliente').addEventListener('click', () => {
      estado.clienteEditando = {}
      dibujar()
    })
    contenido.querySelectorAll('.fila-click').forEach((tr) =>
      tr.addEventListener('click', () => {
        estado.clienteEditando = estado.clientes.find((c) => c.id === tr.dataset.id)
        dibujar()
      })
    )
  }

  function dibujarFormularioCliente(contenido) {
    const c = estado.clienteEditando
    const esNuevo = !c.id
    contenido.innerHTML = `
      <div class="pantalla-header">
        <h3>${esNuevo ? 'Nuevo cliente' : 'Editar cliente'}</h3>
        <button class="btn-secundario" id="btn-volver-cliente">← Volver</button>
      </div>
      <form id="form-cliente" class="tarjeta-form">
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
        <label class="form-check">
          <input name="es_taller" type="checkbox" ${c.es_taller ? 'checked' : ''} />
          Es taller mecánico
        </label>
        <div class="form-grid">
          <label>Días de crédito
            <input name="dias_credito" type="number" min="0" value="${c.dias_credito ?? 0}" />
          </label>
          <label>Límite de crédito
            <input name="limite_credito" type="number" step="0.01" min="0" value="${c.limite_credito ?? 0}" />
          </label>
        </div>
        <label>% Descuento
          <input name="descuento_pct" type="number" step="0.01" min="0" max="100" value="${c.descuento_pct ?? 0}" />
        </label>
        <div class="form-acciones">
          <button type="submit" class="btn-primario">${esNuevo ? 'Crear cliente' : 'Guardar cambios'}</button>
        </div>
      </form>
    `
    contenido.querySelector('#btn-volver-cliente').addEventListener('click', () => {
      estado.clienteEditando = null
      dibujar()
    })
    contenido.querySelector('#form-cliente').addEventListener('submit', async (ev) => {
      ev.preventDefault()
      const fd = new FormData(ev.target)
      const valores = {
        nombre: fd.get('nombre').trim(),
        tipo_doc: fd.get('tipo_doc') || null,
        documento: fd.get('documento')?.trim() || null,
        telefono: fd.get('telefono')?.trim() || null,
        email: fd.get('email')?.trim() || null,
        es_taller: fd.get('es_taller') === 'on',
        dias_credito: Number(fd.get('dias_credito') || 0),
        limite_credito: Number(fd.get('limite_credito') || 0),
        descuento_pct: Number(fd.get('descuento_pct') || 0),
      }
      const boton = ev.target.querySelector('button[type="submit"]')
      boton.disabled = true
      try {
        if (esNuevo) {
          const [creado] = await api.insert('clientes', valores)
          estado.clientes.push(creado)
          estado.clientes.sort((a, b) => a.nombre.localeCompare(b.nombre))
          mostrarToast('Cliente creado', 'exito')
        } else {
          const [actualizado] = await api.update('clientes', c.id, valores)
          const idx = estado.clientes.findIndex((x) => x.id === c.id)
          estado.clientes[idx] = actualizado
          mostrarToast('Cambios guardados', 'exito')
        }
        estado.clienteEditando = null
        dibujar()
      } finally {
        boton.disabled = false
      }
    })
  }

  function dibujarCxc(contenido) {
    if (estado.clienteCobro) {
      dibujarCobro(contenido)
      return
    }
    contenido.innerHTML = `
      <table class="tabla">
        <thead><tr><th>Cliente</th><th>0-30 días</th><th>31-60</th><th>61-90</th><th>+90</th><th>Total</th><th></th></tr></thead>
        <tbody>
          ${estado.cxc
            .map(
              (c) => `
            <tr>
              <td>${escaparHtml(c.nombre)}</td>
              <td>${formatoMoneda(c.d0_30)}</td>
              <td>${formatoMoneda(c.d31_60)}</td>
              <td>${formatoMoneda(c.d61_90)}</td>
              <td>${c.d90_mas > 0 ? `<span class="badge badge-alerta">${formatoMoneda(c.d90_mas)}</span>` : formatoMoneda(0)}</td>
              <td><strong>${formatoMoneda(c.total)}</strong></td>
              <td><button class="btn-secundario btn-cobrar" data-id="${c.cliente_id}">Cobrar</button></td>
            </tr>`
            )
            .join('') || `<tr><td colspan="7" class="tabla-vacia">Sin cuentas por cobrar pendientes.</td></tr>`}
        </tbody>
      </table>
    `
    contenido.querySelectorAll('.btn-cobrar').forEach((btn) =>
      btn.addEventListener('click', async () => {
        estado.clienteCobro = estado.clientes.find((c) => c.id === btn.dataset.id)
        estado.ventasPendientes = await api.select('ventas', (q) =>
          q.eq('cliente_id', btn.dataset.id).gt('saldo', 0).order('fecha')
        )
        dibujar()
      })
    )
  }

  function dibujarCobro(contenido) {
    const cliente = estado.clienteCobro
    contenido.innerHTML = `
      <div class="pantalla-header">
        <h3>Cobrar a ${escaparHtml(cliente.nombre)}</h3>
        <button class="btn-secundario" id="btn-volver-cobro">← Volver</button>
      </div>
      <table class="tabla">
        <thead><tr><th>Venta</th><th>Fecha</th><th>Saldo</th><th>Aplicar</th></tr></thead>
        <tbody>
          ${estado.ventasPendientes
            .map(
              (v) => `
            <tr>
              <td>${escaparHtml(v.numero)}</td>
              <td>${new Date(v.fecha).toLocaleDateString('es-DO')}</td>
              <td>${formatoMoneda(v.saldo)}</td>
              <td><input type="number" step="0.01" min="0" max="${v.saldo}" class="input-conteo aplicar-monto" data-venta="${v.id}" value="0" /></td>
            </tr>`
            )
            .join('') || `<tr><td colspan="4" class="tabla-vacia">Sin ventas pendientes.</td></tr>`}
        </tbody>
      </table>
      <form id="form-cobro" class="tarjeta-form">
        <div class="form-grid">
          <label>Cuenta donde entra el dinero
            <select name="cuenta_id" required>
              ${estado.cuentas.map((c) => `<option value="${c.id}">${escaparHtml(c.nombre)}</option>`).join('')}
            </select>
          </label>
          <label>Método
            <select name="metodo">
              <option value="efectivo">Efectivo</option>
              <option value="transferencia">Transferencia</option>
              <option value="tarjeta">Tarjeta</option>
              <option value="cheque">Cheque</option>
              <option value="otro">Otro</option>
            </select>
          </label>
        </div>
        <label>Referencia
          <input name="referencia" />
        </label>
        <div class="form-acciones">
          <button type="submit" class="btn-primario">Registrar cobro</button>
        </div>
      </form>
    `
    contenido.querySelector('#btn-volver-cobro').addEventListener('click', () => {
      estado.clienteCobro = null
      dibujar()
    })
    contenido.querySelector('#form-cobro').addEventListener('submit', async (ev) => {
      ev.preventDefault()
      const aplicaciones = [...contenido.querySelectorAll('.aplicar-monto')]
        .filter((i) => Number(i.value) > 0)
        .map((i) => ({ venta_id: i.dataset.venta, monto: Number(i.value) }))
      if (!aplicaciones.length) {
        mostrarToast('Indica el monto a aplicar en al menos una venta')
        return
      }
      const monto = aplicaciones.reduce((acc, a) => acc + a.monto, 0)
      const fd = new FormData(ev.target)
      const boton = ev.target.querySelector('button[type="submit"]')
      boton.disabled = true
      try {
        const resultado = await api.rpc('registrar_cobro', {
          p_cliente_id: cliente.id,
          p_monto: monto,
          p_aplicaciones: aplicaciones,
          p_cuenta_id: fd.get('cuenta_id'),
          p_metodo: fd.get('metodo'),
          p_referencia: fd.get('referencia') || null,
        })
        mostrarToast(`Cobro ${resultado.numero} registrado (${formatoMoneda(resultado.monto)})`, 'exito')
        estado.cxc = await api.select('v_cxc_antiguedad')
        estado.clienteCobro = null
        dibujar()
      } finally {
        boton.disabled = false
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
