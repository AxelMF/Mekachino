import { supabase } from './supabaseClient.js'
import { mostrarToast } from './toast.js'

export async function iniciarSesion(email, password) {
  const { error } = await supabase.auth.signInWithPassword({ email, password })
  if (error) {
    mostrarToast(traducirErrorAuth(error))
    throw error
  }
}

export async function cerrarSesion() {
  await supabase.auth.signOut()
}

export async function obtenerSesion() {
  const { data } = await supabase.auth.getSession()
  return data.session
}

export function alCambiarSesion(callback) {
  const { data } = supabase.auth.onAuthStateChange((_evento, sesion) => callback(sesion))
  return () => data.subscription.unsubscribe()
}

/** Perfil (nombre, rol) del usuario autenticado. Null si aún no tiene fila en `perfiles`. */
export async function obtenerPerfil(userId) {
  const { data, error } = await supabase
    .from('perfiles')
    .select('user_id, nombre, rol, activo')
    .eq('user_id', userId)
    .maybeSingle()
  if (error) {
    mostrarToast('No se pudo cargar el perfil del usuario')
    throw error
  }
  return data
}

function traducirErrorAuth(error) {
  if (error.message?.includes('Invalid login credentials')) {
    return 'Correo o contraseña incorrectos'
  }
  return error.message || 'Error al iniciar sesión'
}
