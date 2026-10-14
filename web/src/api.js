import { supabase } from './supabaseClient.js'
import { mostrarToast } from './toast.js'

/**
 * Wrapper único para llamadas a Supabase. Las RPC son la única vía de
 * escritura (ver CLAUDE.md regla 1); el frontend nunca inserta/actualiza
 * tablas transaccionales directamente.
 */
export const api = {
  async rpc(nombre, params = {}) {
    const { data, error } = await supabase.rpc(nombre, params)
    if (error) {
      mostrarToast(error.message || `Error al ejecutar ${nombre}`)
      throw error
    }
    return data
  },

  async select(tabla, construir) {
    let query = supabase.from(tabla).select()
    if (construir) query = construir(query)
    const { data, error } = await query
    if (error) {
      mostrarToast(error.message || `Error al consultar ${tabla}`)
      throw error
    }
    return data
  },
}
