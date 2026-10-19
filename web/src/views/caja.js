import { api } from '../api.js'
import { mostrarToast } from '../toast.js'
import { supabase } from '../supabaseClient.js'

export async function renderCaja(el) {
  el.innerHTML = `<p class="cargando">Cargando caja…</p>`

  const { data: auth } = await supabase.auth.getUser()
  const userId = auth.user.id

  let sesion = await obtenerSesionAbierta(userId)
  let cuentasCaja = []
  try {
    cuentasCaja = await api.select('cuentas_financieras', (q) => q.eq('tipo', 'caja').eq('activo', true))
  } catch {
    el.innerHTML = `<p class="seccion-pendiente">No se pudo cargar la caja.</p>`
    return
  }

  dibujar()

  function dibujar() {
    if (sesion) {
      dibujarAbierta()
    } else {
      dibujarCerrada()
    }
  }

  function dibujarCerrada() {
    el.innerHTML = `
      <div class="pantalla-header"><h2>Caja</h2></div>
      <form id="form-abrir" class="tarjeta-form">
        <p class="seccion-pendiente">No tienes una sesión de caja abierta. Ábrela para poder vender.</p>
        <label>Cuenta de caja
          <select name="cuenta_id" required>
            <option value="">— Selecciona —</option>
            ${cuentasCaja.map((c) => `<option value="${c.id}">${escaparHtml(c.nombre)}</option>`).join('')}
          </select>
        </label>
        <label>Monto de apertura
          <input name="monto_apertura" type="number" step="0.01" min="0" value="0" required />
        </label>
        <div class="form-acciones">
          <button type="submit" class="btn-primario">Abrir caja</button>
        </div>
      </form>
    `
    el.querySelector('#form-abrir').addEventListener('submit', async (ev) => {
      ev.preventDefault()
      const fd = new FormData(ev.target)
      const boton = ev.target.querySelector('button[type="submit"]')
      boton.disabled = true
      try {
        await api.rpc('abrir_caja', {
          p_cuenta_id: fd.get('cuenta_id'),
          p_monto_apertura: Number(fd.get('monto_apertura')),
        })
        mostrarToast('Caja abierta', 'exito')
        sesion = await obtenerSesionAbierta(userId)
        dibujar()
      } finally {
        boton.disabled = false
      }
    })
  }

  function dibujarAbierta() {
    el.innerHTML = `
      <div class="pantalla-header"><h2>Caja</h2></div>
      <div class="tarjeta-form">
        <p><strong>Sesión ${escaparHtml(sesion.numero)}</strong> — abierta el ${new Date(sesion.apertura).toLocaleString('es-DO')}</p>
        <p>Monto de apertura: ${formatoMoneda(sesion.monto_apertura)}</p>
        <p class="nota-ayuda">Ya puedes vender en el POS. Cierra la caja al final del turno para cuadrar.</p>
        <label>Monto contado al cierre
          <input id="monto-contado" type="number" step="0.01" min="0" />
        </label>
        <div class="form-acciones">
          <button type="button" class="btn-primario" id="btn-cerrar">Cerrar caja</button>
        </div>
      </div>
    `
    el.querySelector('#btn-cerrar').addEventListener('click', async (ev) => {
      const monto = Number(el.querySelector('#monto-contado').value || 0)
      ev.target.disabled = true
      try {
        const resultado = await api.rpc('cerrar_caja', { p_sesion_id: sesion.id, p_monto_contado: monto })
        const dif = Number(resultado.diferencia)
        mostrarToast(
          dif === 0
            ? `Caja cerrada sin diferencia (${resultado.numero})`
            : `Caja cerrada con diferencia de ${formatoMoneda(dif)} (${resultado.numero})`,
          dif === 0 ? 'exito' : 'error'
        )
        sesion = null
        dibujar()
      } finally {
        ev.target.disabled = false
      }
    })
  }

  async function obtenerSesionAbierta(uid) {
    const filas = await api.select('sesiones_caja', (q) => q.eq('usuario', uid).eq('estado', 'abierta'))
    return filas[0] || null
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
