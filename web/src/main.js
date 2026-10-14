import './style.css'
import { obtenerSesion, alCambiarSesion, obtenerPerfil, cerrarSesion } from './auth.js'
import { renderLogin } from './views/login.js'
import { renderLayout } from './views/layout.js'

const app = document.querySelector('#app')
let sesionActualId = null

async function render() {
  const sesion = await obtenerSesion()

  if (!sesion) {
    sesionActualId = null
    renderLogin(app)
    return
  }

  if (sesion.user.id === sesionActualId) return // ya renderizado, evita parpadeo en refresh de token
  sesionActualId = sesion.user.id

  const perfil = await obtenerPerfil(sesion.user.id)
  if (!perfil || !perfil.activo) {
    app.innerHTML = `
      <div class="login-pantalla">
        <div class="login-tarjeta">
          <h1>Sin acceso</h1>
          <p>Tu cuenta no tiene un perfil activo asignado. Contacta a un administrador.</p>
          <button id="btn-salir-sin-perfil">Salir</button>
        </div>
      </div>
    `
    app.querySelector('#btn-salir-sin-perfil').addEventListener('click', () => cerrarSesion())
    return
  }

  renderLayout(app, perfil)
}

alCambiarSesion(render)
render()
