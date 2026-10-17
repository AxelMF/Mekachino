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

  // insert/update son solo para tablas maestras (catálogo, almacenes, etc.)
  // permitidas por RLS; las tablas transaccionales van siempre por rpc().
  async insert(tabla, valores) {
    const { data, error } = await supabase.from(tabla).insert(valores).select()
    if (error) {
      mostrarToast(error.message || `Error al crear en ${tabla}`)
      throw error
    }
    return data
  },

  async update(tabla, id, valores) {
    const { data, error } = await supabase.from(tabla).update(valores).eq('id', id).select()
    if (error) {
      mostrarToast(error.message || `Error al actualizar ${tabla}`)
      throw error
    }
    return data
  },
}
