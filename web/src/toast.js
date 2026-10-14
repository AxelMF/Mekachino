let contenedor

function obtenerContenedor() {
  if (!contenedor) {
    contenedor = document.createElement('div')
    contenedor.className = 'toast-contenedor'
    document.body.appendChild(contenedor)
  }
  return contenedor
}

export function mostrarToast(mensaje, tipo = 'error') {
  const cont = obtenerContenedor()
  const toast = document.createElement('div')
  toast.className = `toast toast--${tipo}`
  toast.textContent = mensaje
  cont.appendChild(toast)
  setTimeout(() => toast.classList.add('toast--visible'), 10)
  setTimeout(() => {
    toast.classList.remove('toast--visible')
    setTimeout(() => toast.remove(), 300)
  }, 4500)
}
