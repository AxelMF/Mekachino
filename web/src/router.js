/** Enrutado por hash (#/ruta) — Cloudflare Pages no soporta rewrites de SPA sin CSP estricta. */
let rutas = []
let contenedor = null

export function definirRutas(nuevasRutas, el) {
  rutas = nuevasRutas
  contenedor = el
  window.addEventListener('hashchange', renderizar)
}

function rutaActual() {
  return window.location.hash.replace(/^#/, '') || '/'
}

export function navegar(ruta) {
  window.location.hash = ruta
}

export function renderizar() {
  const ruta = rutaActual()
  const coincidencia = rutas.find((r) => r.ruta === ruta) || rutas.find((r) => r.ruta === '*')
  if (coincidencia && contenedor) {
    coincidencia.render(contenedor)
  }
}
