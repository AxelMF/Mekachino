import { cerrarSesion } from '../auth.js'
import { menuParaRol } from '../menu.js'
import { definirRutas, renderizar, navegar } from '../router.js'
import { renderCatalogo } from './catalogo.js'
import { renderInventario } from './inventario.js'
import { renderConsignacion } from './consignacion.js'

const VISTAS = {
  '/catalogo': renderCatalogo,
  '/inventario': renderInventario,
  '/consignacion': renderConsignacion,
}

export function renderLayout(el, perfil) {
  const menu = menuParaRol(perfil.rol)

  el.innerHTML = `
    <div class="app-shell">
      <header class="app-topbar">
        <button class="app-menu-btn" id="btn-menu" aria-label="Menú">☰</button>
        <span class="app-topbar-titulo">MekaChinos</span>
        <span class="app-topbar-usuario">${escaparHtml(perfil.nombre)} · ${perfil.rol}</span>
        <button class="app-salir" id="btn-salir">Salir</button>
      </header>
      <div class="app-cuerpo">
        <nav class="app-sidebar" id="sidebar">
          ${menu.map((item) => `<a href="#${item.ruta}" data-ruta="${item.ruta}">${item.etiqueta}</a>`).join('')}
        </nav>
        <main class="app-contenido" id="contenido"></main>
      </div>
    </div>
  `

  el.querySelector('#btn-salir').addEventListener('click', () => cerrarSesion())
  el.querySelector('#btn-menu').addEventListener('click', () => {
    el.querySelector('#sidebar').classList.toggle('app-sidebar--abierta')
  })

  const contenido = el.querySelector('#contenido')
  const rutas = menu.map((item) => ({
    ruta: item.ruta,
    render: VISTAS[item.ruta] || ((destino) => renderSeccion(destino, item.etiqueta)),
  }))
  rutas.push({
    ruta: '*',
    render: (destino) => renderSeccion(destino, 'No autorizado', 'No tienes acceso a esta sección.'),
  })

  definirRutas(rutas, contenido)
  renderizar()

  el.querySelectorAll('.app-sidebar a').forEach((a) => {
    a.addEventListener('click', () => {
      el.querySelector('#sidebar').classList.remove('app-sidebar--abierta')
      marcarActivo(el, a.dataset.ruta)
    })
  })
  marcarActivo(el, window.location.hash.replace(/^#/, '') || '/')
}

function renderSeccion(el, titulo, nota) {
  el.innerHTML = `
    <h2>${titulo}</h2>
    <p class="seccion-pendiente">${nota || 'Módulo en construcción (próxima fase).'}</p>
  `
}

function marcarActivo(el, ruta) {
  el.querySelectorAll('.app-sidebar a').forEach((a) => {
    a.classList.toggle('activo', a.dataset.ruta === ruta)
  })
}

function escaparHtml(texto) {
  const div = document.createElement('div')
  div.textContent = texto
  return div.innerHTML
}

// Reafirma la sección activa cuando cambia el hash (navegación directa, atrás/adelante)
window.addEventListener('hashchange', () => {
  const shell = document.querySelector('.app-shell')
  if (shell) marcarActivo(shell, window.location.hash.replace(/^#/, '') || '/')
})

export { navegar }
