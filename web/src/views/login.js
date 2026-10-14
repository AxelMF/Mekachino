import { iniciarSesion } from '../auth.js'

export function renderLogin(el) {
  el.innerHTML = `
    <div class="login-pantalla">
      <form class="login-tarjeta" id="form-login">
        <img src="/logo.jpg" alt="MekaChinos" class="login-logo" />
        <p class="login-subtitulo">Repuestos de confianza, siempre disponibles</p>
        <label for="email">Correo</label>
        <input id="email" type="email" autocomplete="username" required />
        <label for="password">Contraseña</label>
        <input id="password" type="password" autocomplete="current-password" required />
        <button type="submit">Entrar</button>
        <p class="login-error" id="login-error" hidden></p>
      </form>
    </div>
  `

  const form = el.querySelector('#form-login')
  const errorEl = el.querySelector('#login-error')

  form.addEventListener('submit', async (ev) => {
    ev.preventDefault()
    errorEl.hidden = true
    const boton = form.querySelector('button')
    boton.disabled = true
    boton.textContent = 'Entrando…'
    try {
      await iniciarSesion(form.email.value.trim(), form.password.value)
    } catch (error) {
      errorEl.textContent = error.message || 'No se pudo iniciar sesión'
      errorEl.hidden = false
    } finally {
      boton.disabled = false
      boton.textContent = 'Entrar'
    }
  })
}
