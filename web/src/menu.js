/** Menú por rol (SPEC §9). Todas las secciones salvo Tablero están pendientes de fases futuras. */
export const MENU = [
  { ruta: '/', etiqueta: 'Tablero', roles: ['admin', 'vendedor', 'almacen', 'contador'] },
  { ruta: '/pos', etiqueta: 'POS / Nueva venta', roles: ['admin', 'vendedor'] },
  { ruta: '/cotizaciones', etiqueta: 'Cotizaciones', roles: ['admin', 'vendedor'] },
  { ruta: '/ventas', etiqueta: 'Ventas', roles: ['admin', 'vendedor', 'contador'] },
  { ruta: '/catalogo', etiqueta: 'Catálogo', roles: ['admin', 'almacen', 'vendedor'] },
  { ruta: '/inventario', etiqueta: 'Inventario', roles: ['admin', 'almacen'] },
  { ruta: '/compras', etiqueta: 'Compras', roles: ['admin', 'almacen'] },
  { ruta: '/consignacion', etiqueta: 'Consignación', roles: ['admin', 'almacen'] },
  { ruta: '/clientes', etiqueta: 'Clientes y CxC', roles: ['admin', 'vendedor'] },
  { ruta: '/cxp', etiqueta: 'Cuentas por pagar', roles: ['admin', 'contador'] },
  { ruta: '/caja', etiqueta: 'Caja y bancos', roles: ['admin', 'vendedor', 'contador'] },
  { ruta: '/contabilidad', etiqueta: 'Contabilidad', roles: ['admin', 'contador'] },
  { ruta: '/reportes', etiqueta: 'Reportes', roles: ['admin', 'contador'] },
  { ruta: '/configuracion', etiqueta: 'Configuración y usuarios', roles: ['admin'] },
]

export function menuParaRol(rol) {
  return MENU.filter((item) => item.roles.includes(rol))
}
