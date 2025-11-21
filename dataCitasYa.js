// dataCitasYa.js
import { supabase } from './supabaseClient.js';

const LS_SESSION = 'cy_session_supabase';

/**
 * Guarda una sesión ligera en localStorage:
 * - id de auth
 * - id de usuario en tabla public.usuarios
 * - rol_id
 * - datos básicos
 */
export function guardarSesionLocal(perfil, authUser) {
  if (!perfil || !authUser) return null;

  const payload = {
    auth_user_id: authUser.id,
    usuario_id: perfil.id,
    rol_id: perfil.rol_id,
    nombre: perfil.nombre_completo,
    correo: perfil.correo,
    telefono: perfil.telefono,
    usuario: perfil.usuario,
    loggedAt: new Date().toISOString(),
  };

  try {
    localStorage.setItem(LS_SESSION, JSON.stringify(payload));
  } catch (e) {
    console.warn('No se pudo guardar la sesión en localStorage', e);
  }
  return payload;
}

export function cargarSesionLocal() {
  try {
    const raw = localStorage.getItem(LS_SESSION);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

export function limpiarSesionLocal() {
  try {
    localStorage.removeItem(LS_SESSION);
  } catch {
    /* ignore */
  }
}

function mapPerfilRow(row) {
  if (!row) return null;
  return {
    id: row.id,
    nombre_completo: row.nombre_completo,
    correo: row.correo,
    telefono: row.telefono,
    usuario: row.usuario,
    rol_id: row.rol_id,
  };
}

/**
 * Login SOLO por correo + contraseña (más seguro y alineado con Supabase).
 * 1. supabase.auth.signInWithPassword
 * 2. Lee el perfil en public.usuarios usando auth_user_id
 */
export async function loginConEmailYPassword(email, password) {
  const emailTrimmed = (email || '').trim().toLowerCase();
  if (!emailTrimmed || !password) {
    throw new Error('Correo y contraseña son obligatorios.');
  }

  const { data, error } = await supabase.auth.signInWithPassword({
    email: emailTrimmed,
    password,
  });

  if (error) {
    throw error;
  }

  const authUser = data.user;
  if (!authUser) {
    throw new Error('No se pudo obtener el usuario autenticado.');
  }

  const { data: perfilRow, error: errorPerfil } = await supabase
    .from('usuarios')
    .select('id, nombre_completo, correo, telefono, usuario, rol_id')
    .eq('auth_user_id', authUser.id)
    .maybeSingle();

  if (errorPerfil) {
    throw errorPerfil;
  }

  const perfil = mapPerfilRow(perfilRow);
  return { authUser, perfil };
}

/**
 * Registro de cliente:
 * 1. signUp en auth (dispara trigger handle_new_user -> inserta en public.usuarios con rol_id = 1)
 * 2. Best effort para actualizar datos extra (telefono, usuario, nombre)
 * 3. Intenta leer el perfil en public.usuarios
 */
export async function registrarCliente({ nombre, email, telefono, usuario, contrasena }) {
  const emailTrimmed = (email || '').trim().toLowerCase();

  const { data, error } = await supabase.auth.signUp({
    email: emailTrimmed,
    password: contrasena,
    options: {
      data: {
        full_name: nombre,
        phone: telefono,
        username: usuario,
      },
    },
  });

  if (error) {
    throw error;
  }

  const authUser = data.user ?? null;
  let perfil = null;

  if (authUser) {
    try {
      // Actualizar datos de perfil (permitido por policy usuarios_self_update)
      const { error: updateError } = await supabase
        .from('usuarios')
        .update({
          nombre_completo: nombre,
          telefono,
          usuario,
        })
        .eq('auth_user_id', authUser.id);

      if (updateError) {
        console.warn('No se pudo actualizar datos del perfil:', updateError.message);
      }

      const { data: perfilRow, error: perfilError } = await supabase
        .from('usuarios')
        .select('id, nombre_completo, correo, telefono, usuario, rol_id')
        .eq('auth_user_id', authUser.id)
        .maybeSingle();

      if (perfilError) {
        console.warn('No se pudo leer perfil tras el registro:', perfilError.message);
      } else {
        perfil = mapPerfilRow(perfilRow);
      }
    } catch (e) {
      console.warn('Error al completar perfil tras registro:', e);
    }
  }

  const needsEmailConfirm = !data.session; // si es true, probablemente hay verificación por correo

  return { authUser, perfil, needsEmailConfirm };
}

/**
 * Redirección por rol:
 * 1 = usuario/cliente -> agendar cita
 * 2 = barbero -> organizar agenda
 * 3 = administrador -> panel admin
 */
export function redirigirSegunRol(rolId) {
  switch (rolId) {
    case 2:
      window.location.href = 'interfaz_organizar_agenda.html';
      break;
    case 3:
      window.location.href = 'interfaz_admin.html';
      break;
    case 1:
    default:
      // Cliente final -> página pública de agendamiento
      window.location.href = 'interfaz_agendar_publico.html';
      break;
  }
}
