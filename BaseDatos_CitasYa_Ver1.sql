-- =====================================================================
-- CitasYa — ESQUEMA COMPLETO + SEGURIDAD SUPABASE (RLS + POLICIES)
-- Versión robusta (sin DROP TRIGGER sobre tablas inexistentes)
-- =====================================================================

BEGIN;

-- ======================
-- EXTENSIONES
-- ======================
create extension if not exists btree_gist;
create extension if not exists pgcrypto;

-- ======================
-- LIMPIEZA SEGURA
-- (Triggers de tablas se caen con DROP TABLE CASCADE; no los tocamos directo)
-- ======================
DROP FUNCTION IF EXISTS public.set_updated_at() CASCADE;
DROP FUNCTION IF EXISTS public.handle_new_user() CASCADE;
DROP FUNCTION IF EXISTS public.current_usuario_id() CASCADE;
DROP FUNCTION IF EXISTS public.is_admin() CASCADE;
DROP FUNCTION IF EXISTS public.is_barbero() CASCADE;
DROP FUNCTION IF EXISTS public.is_cliente() CASCADE;
DROP FUNCTION IF EXISTS public.is_negocio_owner(bigint) CASCADE;
DROP FUNCTION IF EXISTS public.is_staff_member(bigint) CASCADE;
DROP FUNCTION IF EXISTS public.get_public_negocios() CASCADE;

DROP VIEW     IF EXISTS public.negocios_publicos;

-- Tablas (en orden)
DROP TABLE IF EXISTS public.administrador      CASCADE;
DROP TABLE IF EXISTS public.comentarios        CASCADE;
DROP TABLE IF EXISTS public.tipo_comentario    CASCADE;
DROP TABLE IF EXISTS public.movimientos_tokens CASCADE;
DROP TABLE IF EXISTS public.promociones        CASCADE;
DROP TABLE IF EXISTS public.suscripciones_plus CASCADE;
DROP TABLE IF EXISTS public.compras            CASCADE;
DROP TABLE IF EXISTS public.estado_pago        CASCADE;
DROP TABLE IF EXISTS public.metodo_pago        CASCADE;
DROP TABLE IF EXISTS public.cancelaciones_cita CASCADE;
DROP TABLE IF EXISTS public.citas              CASCADE;
DROP TABLE IF EXISTS public.estado_cita        CASCADE;
DROP TABLE IF EXISTS public.dia_horario        CASCADE;
DROP TABLE IF EXISTS public.dias_semana        CASCADE;
DROP TABLE IF EXISTS public.conjunto_horario   CASCADE;
DROP TABLE IF EXISTS public.personal_servicio  CASCADE;
DROP TABLE IF EXISTS public.servicios          CASCADE;
DROP TABLE IF EXISTS public.personal           CASCADE;
DROP TABLE IF EXISTS public.negocios           CASCADE;
DROP TABLE IF EXISTS public.usuarios           CASCADE;
DROP TABLE IF EXISTS public.roles              CASCADE;
DROP TABLE IF EXISTS public.estadisticas       CASCADE;

-- ======================
-- TIPOS ENUM
-- ======================
DO $$ BEGIN
   IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'sentimiento') THEN
      CREATE TYPE public.sentimiento AS ENUM ('positivo','neutro','negativo');
   END IF;
END $$;

DO $$ BEGIN
   IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'alcance_resumen') THEN
      CREATE TYPE public.alcance_resumen AS ENUM ('pagina','negocio');
   END IF;
END $$;

DO $$ BEGIN
   IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'audiencia_resumen') THEN
      CREATE TYPE public.audiencia_resumen AS ENUM ('solo_admin','publico','negocio');
   END IF;
END $$;

-- ======================
-- FUNCION updated_at
-- ======================
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW IS DISTINCT FROM OLD THEN
    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = TG_TABLE_SCHEMA
        AND table_name   = TG_TABLE_NAME
        AND column_name  = 'actualizado_en'
    ) THEN
      NEW.actualizado_en := now();
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- ======================
-- CATALOGO DE ROLES
-- ======================
CREATE TABLE public.roles (
  id             BIGSERIAL PRIMARY KEY,
  nombre         VARCHAR(120) NOT NULL UNIQUE,
  creado_en      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ======================
-- USUARIOS (perfil app) enlazado a auth.users
-- ======================
CREATE TABLE public.usuarios (
  id               BIGSERIAL PRIMARY KEY,
  auth_user_id     UUID UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre_completo  VARCHAR(120) NOT NULL,
  correo           VARCHAR(190) UNIQUE,
  telefono         VARCHAR(20)  UNIQUE,
  usuario          VARCHAR(50)  UNIQUE,
  hash_contrasena  VARCHAR(255),               -- DEPRECADO (Auth lo maneja)
  rol_id           BIGINT NOT NULL REFERENCES public.roles(id),
  activo           BOOLEAN NOT NULL DEFAULT TRUE,
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ======================
-- NEGOCIOS / PERSONAL / SERVICIOS
-- ======================
CREATE TABLE public.negocios (
  id             BIGSERIAL PRIMARY KEY,
  nombre         VARCHAR(140) NOT NULL,
  tokens         INT NOT NULL DEFAULT 0,
  direccion      VARCHAR(240),
  latitud        NUMERIC(10,7),
  longitud       NUMERIC(10,7),
  activo         BOOLEAN NOT NULL DEFAULT FALSE, -- aprobado/visible
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_negocios_activo ON public.negocios(activo);

CREATE TABLE public.personal (
  id              BIGSERIAL PRIMARY KEY,
  negocio_id      BIGINT NOT NULL REFERENCES public.negocios(id) ON DELETE CASCADE,
  usuario_id      BIGINT REFERENCES public.usuarios(id) ON DELETE SET NULL,
  propietario     BOOLEAN NOT NULL DEFAULT FALSE, -- dueño del negocio
  nombre_publico  VARCHAR(120) NOT NULL,
  activo          BOOLEAN NOT NULL DEFAULT TRUE,
  creado_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_personal_negocio_activo ON public.personal(negocio_id, activo);
CREATE INDEX IF NOT EXISTS idx_personal_usuario        ON public.personal(usuario_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_personal_owner ON public.personal(negocio_id) WHERE propietario = true;

CREATE TABLE public.servicios (
  id             BIGSERIAL PRIMARY KEY,
  negocio_id     BIGINT NOT NULL REFERENCES public.negocios(id) ON DELETE CASCADE,
  nombre         VARCHAR(120) NOT NULL,
  duracion_min   INT NOT NULL,
  precio_cop     NUMERIC(12,2) NOT NULL,
  costo_tokens   INT NOT NULL DEFAULT 1,
  activo         BOOLEAN NOT NULL DEFAULT TRUE,
  orden          INT NOT NULL DEFAULT 0,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_servicios_negocio_nombre UNIQUE (negocio_id, nombre)
);
CREATE INDEX IF NOT EXISTS idx_servicios_negocio_activo ON public.servicios(negocio_id, activo);
CREATE INDEX IF NOT EXISTS idx_servicios_negocio_orden  ON public.servicios(negocio_id, orden);

CREATE TABLE public.personal_servicio (
  personal_id     BIGINT NOT NULL REFERENCES public.personal(id)   ON DELETE CASCADE,
  servicio_id     BIGINT NOT NULL REFERENCES public.servicios(id)  ON DELETE CASCADE,
  creado_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (personal_id, servicio_id)
);

-- ======================
-- AGENDA
-- ======================
CREATE TABLE public.conjunto_horario (
  id             BIGSERIAL PRIMARY KEY,
  negocio_id     BIGINT NOT NULL REFERENCES public.negocios(id) ON DELETE CASCADE,
  personal_id    BIGINT NOT NULL REFERENCES public.personal(id) ON DELETE CASCADE,
  fecha_inicio   DATE NOT NULL,
  fecha_fin      DATE NOT NULL,
  creado_por     BIGINT REFERENCES public.usuarios(id),
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_conjunto_personal_rango ON public.conjunto_horario(personal_id, fecha_inicio, fecha_fin);

CREATE TABLE public.dias_semana (
  id             BIGSERIAL PRIMARY KEY,
  nombre         VARCHAR(120) NOT NULL UNIQUE,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.dia_horario (
  id                      BIGSERIAL PRIMARY KEY,
  conjunto_horario_id     BIGINT NOT NULL REFERENCES public.conjunto_horario(id) ON DELETE CASCADE,
  dia_id                  BIGINT NOT NULL REFERENCES public.dias_semana(id),
  trabaja                 BOOLEAN NOT NULL DEFAULT FALSE,
  hora_inicio             TIME,
  hora_fin                TIME,
  almuerzo_inicio         TIME,
  almuerzo_fin            TIME,
  creado_en               TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_dia_conjunto UNIQUE (conjunto_horario_id, dia_id)
);

-- ======================
-- CITAS Y CANCELACIONES
-- ======================
CREATE TABLE public.estado_cita (
  id             BIGSERIAL PRIMARY KEY,
  nombre         VARCHAR(120) NOT NULL UNIQUE,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.citas (
  id                  BIGSERIAL PRIMARY KEY,
  negocio_id          BIGINT NOT NULL REFERENCES public.negocios(id)    ON DELETE CASCADE,
  personal_id         BIGINT NOT NULL REFERENCES public.personal(id)    ON DELETE CASCADE,
  servicio_id         BIGINT NOT NULL REFERENCES public.servicios(id)   ON DELETE RESTRICT,
  usuario_cliente_id  BIGINT REFERENCES public.usuarios(id)             ON DELETE SET NULL,
  nombre_invitado     VARCHAR(140),
  fecha               DATE NOT NULL,
  inicia_en           TIMESTAMPTZ NOT NULL,
  termina_en          TIMESTAMPTZ NOT NULL,
  estado_id           BIGINT NOT NULL REFERENCES public.estado_cita(id),
  notas               TEXT,
  creado_en           TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_citas_time CHECK (inicia_en < termina_en)
);
CREATE INDEX IF NOT EXISTS idx_citas_negocio_inicio            ON public.citas(negocio_id, inicia_en);
CREATE INDEX IF NOT EXISTS idx_citas_personal_inicio           ON public.citas(personal_id, inicia_en);
CREATE INDEX IF NOT EXISTS idx_citas_usuario                   ON public.citas(usuario_cliente_id);
CREATE INDEX IF NOT EXISTS idx_citas_negocio_personal_inicio   ON public.citas(negocio_id, personal_id, inicia_en);

ALTER TABLE public.citas
  ADD COLUMN IF NOT EXISTS rango_hora tstzrange
  GENERATED ALWAYS AS (tstzrange(inicia_en, termina_en, '[)')) STORED;

DO $$
BEGIN
  BEGIN
    ALTER TABLE public.citas
      ADD CONSTRAINT citas_no_overlap_personal
      EXCLUDE USING gist (personal_id WITH =, rango_hora WITH &&);
  EXCEPTION WHEN duplicate_table THEN
    NULL;
  END;
END$$;

CREATE TABLE public.cancelaciones_cita (
  id                 BIGSERIAL PRIMARY KEY,
  cita_id            BIGINT NOT NULL REFERENCES public.citas(id) ON DELETE CASCADE,
  usuario_id_cancelo BIGINT NOT NULL REFERENCES public.usuarios(id),
  motivo             VARCHAR(240),
  cancelado_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
  creado_en          TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ======================
-- PAGOS, TOKENS Y PLUS
-- ======================
CREATE TABLE public.metodo_pago (
  id             BIGSERIAL PRIMARY KEY,
  nombre         VARCHAR(120) NOT NULL UNIQUE,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.estado_pago (
  id             BIGSERIAL PRIMARY KEY,
  nombre         VARCHAR(120) NOT NULL UNIQUE,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.compras (
  id             BIGSERIAL PRIMARY KEY,
  negocio_id     BIGINT NOT NULL REFERENCES public.negocios(id) ON DELETE CASCADE,
  metodo_id      BIGINT NOT NULL REFERENCES public.metodo_pago(id),
  estado_id      BIGINT NOT NULL REFERENCES public.estado_pago(id),
  tokens         INT,
  monto_cop      NUMERIC(12,2) NOT NULL,
  ref_externa    VARCHAR(120),
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.suscripciones_plus (
  id             BIGSERIAL PRIMARY KEY,
  negocio_id     BIGINT NOT NULL REFERENCES public.negocios(id) ON DELETE CASCADE,
  fecha_inicio   DATE NOT NULL,
  fecha_fin      DATE NOT NULL,
  monto_cop      NUMERIC(12,2) NOT NULL,
  activa         BOOLEAN NOT NULL DEFAULT TRUE,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_suscripciones_negocio_activa ON public.suscripciones_plus(negocio_id, activa);

CREATE TABLE public.promociones (
  id             BIGSERIAL PRIMARY KEY,
  nombre         VARCHAR(200) NOT NULL,
  inicia         DATE NOT NULL,
  termina        DATE NOT NULL,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.movimientos_tokens (
  id               BIGSERIAL PRIMARY KEY,
  fecha            DATE NOT NULL,
  hora             TIME NOT NULL,
  negocio_id       BIGINT NOT NULL REFERENCES public.negocios(id) ON DELETE CASCADE,
  credito          INT NOT NULL DEFAULT 0,
  debito           INT NOT NULL DEFAULT 0,
  compra_id        BIGINT REFERENCES public.compras(id) ON DELETE SET NULL,
  cita_id          BIGINT REFERENCES public.citas(id) ON DELETE SET NULL,
  promocion_id     BIGINT REFERENCES public.promociones(id) ON DELETE SET NULL,
  cancelacion_id   BIGINT REFERENCES public.cancelaciones_cita(id) ON DELETE SET NULL,
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_movimientos_negocio_creado ON public.movimientos_tokens(negocio_id, creado_en);

-- ======================
-- COMENTARIOS
-- ======================
CREATE TABLE public.tipo_comentario (
  id             BIGSERIAL PRIMARY KEY,
  nombre         VARCHAR(40) NOT NULL UNIQUE,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.comentarios (
  id                 BIGSERIAL PRIMARY KEY,
  tipo_comentario_id BIGINT NOT NULL REFERENCES public.tipo_comentario(id),
  negocio_id         BIGINT REFERENCES public.negocios(id) ON DELETE SET NULL,
  usuario_autor_id   BIGINT REFERENCES public.usuarios(id) ON DELETE SET NULL,
  nombre_autor       VARCHAR(140),
  calificacion       INT NOT NULL CHECK (calificacion BETWEEN 1 AND 5),
  recomienda         BOOLEAN NOT NULL DEFAULT FALSE,
  texto              TEXT,
  sentimiento        public.sentimiento,
  visible            BOOLEAN NOT NULL DEFAULT TRUE,
  creado_en          TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_comentarios_negocio      ON public.comentarios(negocio_id);
CREATE INDEX IF NOT EXISTS idx_comentarios_calificacion ON public.comentarios(calificacion);
CREATE INDEX IF NOT EXISTS idx_comentarios_sentimiento  ON public.comentarios(sentimiento);

-- ======================
-- ESTADISTICAS
-- ======================
CREATE TABLE public.estadisticas (
  id                  BIGSERIAL PRIMARY KEY,
  alcance             public.alcance_resumen   NOT NULL,
  audiencia           public.audiencia_resumen NOT NULL DEFAULT 'solo_admin',
  negocio_id          BIGINT REFERENCES public.negocios(id) ON DELETE CASCADE,
  periodo_inicio      DATE NOT NULL,
  periodo_fin         DATE NOT NULL,
  negocios_activos    INT NOT NULL DEFAULT 0,
  barberos_activos    INT NOT NULL DEFAULT 0,
  citas_programadas   INT NOT NULL DEFAULT 0,
  citas_canceladas    INT NOT NULL DEFAULT 0,
  prom_citas_7d       NUMERIC(5,2) NOT NULL DEFAULT 0,
  tasa_cancelacion    NUMERIC(5,2) NOT NULL DEFAULT 0,
  tokens_comprados    INT NOT NULL DEFAULT 0,
  tokens_consumidos   INT NOT NULL DEFAULT 0,
  tokens_saldo_total  INT NOT NULL DEFAULT 0,
  suscrip_activas     INT NOT NULL DEFAULT 0,
  suscrip_nuevas      INT NOT NULL DEFAULT 0,
  comentarios_total   INT NOT NULL DEFAULT 0,
  calif_promedio      NUMERIC(3,2) NOT NULL DEFAULT 0,
  calif_5             INT NOT NULL DEFAULT 0,
  calif_4             INT NOT NULL DEFAULT 0,
  calif_3             INT NOT NULL DEFAULT 0,
  calif_2             INT NOT NULL DEFAULT 0,
  calif_1             INT NOT NULL DEFAULT 0,
  recomiendan_si      INT NOT NULL DEFAULT 0,
  recomiendan_no      INT NOT NULL DEFAULT 0,
  observaciones       TEXT,
  creado_en           TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_estadisticas_rango   ON public.estadisticas(alcance, negocio_id, periodo_inicio, periodo_fin);
CREATE INDEX IF NOT EXISTS idx_estadisticas_negocio ON public.estadisticas(negocio_id);

-- ======================
-- ADMINISTRADOR
-- ======================
CREATE TABLE public.administrador (
  id               BIGSERIAL PRIMARY KEY,
  usuario_id       BIGINT NOT NULL REFERENCES public.usuarios(id) ON DELETE CASCADE,
  comentarios      TEXT,
  estadisticas_id  BIGINT NOT NULL REFERENCES public.estadisticas(id) ON DELETE CASCADE,
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ======================
-- TRIGGERS updated_at (autogenerados)
-- ======================
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT table_schema, table_name
    FROM information_schema.columns
    WHERE column_name = 'actualizado_en' AND table_schema = 'public'
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_updated_at_%I ON %I.%I;', r.table_name, r.table_schema, r.table_name);
    EXECUTE format('CREATE TRIGGER trg_updated_at_%I BEFORE UPDATE ON %I.%I
                    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();', r.table_name, r.table_schema, r.table_name);
  END LOOP;
END $$;

-- ======================
-- SEEDS MINIMOS
-- ======================
INSERT INTO public.roles (nombre) VALUES
  ('usuario'), ('barbero'), ('administrador')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO public.estado_cita (nombre) VALUES
  ('pendiente'),('confirmada'),('reprogramada'),('cancelada'),('finalizada')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO public.metodo_pago (nombre) VALUES ('mercado pago')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO public.estado_pago (nombre) VALUES
  ('aprobado'),('declinado'),('en_proceso')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO public.tipo_comentario (nombre) VALUES
  ('reseña'),('sugerencia'),('queja')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO public.dias_semana (nombre) VALUES
  ('lunes'),('martes'),('miércoles'),('jueves'),('viernes'),('sábado'),('domingo')
ON CONFLICT (nombre) DO NOTHING;

-- ======================
-- HELPERS (ROL/PROPIEDAD)
-- ======================
CREATE OR REPLACE FUNCTION public.current_usuario_id()
RETURNS BIGINT LANGUAGE sql STABLE AS $$
  SELECT u.id
  FROM public.usuarios u
  WHERE u.auth_user_id = auth.uid()
$$;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid() AND r.nombre = 'administrador'
  )
$$;

CREATE OR REPLACE FUNCTION public.is_barbero()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid() AND r.nombre = 'barbero'
  )
$$;

CREATE OR REPLACE FUNCTION public.is_cliente()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid() AND r.nombre = 'usuario'
  )
$$;

CREATE OR REPLACE FUNCTION public.is_negocio_owner(_negocio_id BIGINT)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.personal p
    JOIN public.usuarios u ON u.id = p.usuario_id
    WHERE p.negocio_id = _negocio_id
      AND p.propietario = true
      AND u.auth_user_id = auth.uid()
  )
$$;

CREATE OR REPLACE FUNCTION public.is_staff_member(_personal_id BIGINT)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.personal p
    JOIN public.usuarios u ON u.id = p.usuario_id
    WHERE p.id = _personal_id
      AND u.auth_user_id = auth.uid()
  )
$$;

-- ======================
-- AUTO-PERFIL: fila en usuarios cuando se registra auth.users
-- ======================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  rol_usuario_id BIGINT;
BEGIN
  SELECT id INTO rol_usuario_id FROM public.roles WHERE nombre = 'usuario';
  IF rol_usuario_id IS NULL THEN
    INSERT INTO public.roles(nombre) VALUES ('usuario')
    ON CONFLICT (nombre) DO NOTHING;
    SELECT id INTO rol_usuario_id FROM public.roles WHERE nombre = 'usuario';
  END IF;

  INSERT INTO public.usuarios(auth_user_id, nombre_completo, correo, rol_id, activo)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name',''), COALESCE(NEW.email,''), rol_usuario_id, true)
  ON CONFLICT (auth_user_id) DO NOTHING;

  RETURN NEW;
END;
$$;

-- Re-crear trigger en auth.users (si no existe)
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ======================
-- RLS: ACTIVAR EN TODAS LAS TABLAS
-- ======================
ALTER TABLE public.roles               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usuarios            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.negocios            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.personal            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.servicios           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.personal_servicio   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conjunto_horario    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dias_semana         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dia_horario         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estado_cita         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.citas               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cancelaciones_cita  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.metodo_pago         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estado_pago         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.compras             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suscripciones_plus  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promociones         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimientos_tokens  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tipo_comentario     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comentarios         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estadisticas        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.administrador       ENABLE ROW LEVEL SECURITY;

-- Limpia políticas previas (si las hubiera)
DO $$
DECLARE t RECORD;
BEGIN
  FOR t IN
    SELECT schemaname, tablename, policyname
    FROM pg_policies
    WHERE schemaname='public'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I;', t.policyname, t.schemaname, t.tablename);
  END LOOP;
END $$;

-- ======================
-- POLITICAS POR TABLA
-- ======================

-- roles
CREATE POLICY roles_select_auth ON public.roles
FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY roles_admin_all ON public.roles
FOR ALL USING (public.is_admin())
WITH CHECK (public.is_admin());

-- usuarios
CREATE POLICY usuarios_self_select ON public.usuarios
FOR SELECT USING (auth.uid() = auth_user_id OR public.is_admin());
CREATE POLICY usuarios_self_update ON public.usuarios
FOR UPDATE USING (auth.uid() = auth_user_id OR public.is_admin())
WITH CHECK (auth.uid() = auth_user_id OR public.is_admin());
CREATE POLICY usuarios_admin_insert ON public.usuarios
FOR INSERT WITH CHECK (public.is_admin());

-- negocios
CREATE POLICY negocios_read ON public.negocios
FOR SELECT USING (activo = true OR public.is_admin() OR public.is_negocio_owner(id));
CREATE POLICY negocios_insert_barbero ON public.negocios
FOR INSERT WITH CHECK (public.is_barbero());
CREATE POLICY negocios_owner_update_delete ON public.negocios
FOR ALL USING (public.is_negocio_owner(id) OR public.is_admin())
WITH CHECK (public.is_negocio_owner(id) OR public.is_admin());

-- personal
CREATE POLICY personal_select ON public.personal
FOR SELECT USING (
  public.is_negocio_owner(negocio_id) OR public.is_admin() OR activo = true
);
CREATE POLICY personal_owner_crud ON public.personal
FOR ALL USING (public.is_negocio_owner(negocio_id) OR public.is_admin())
WITH CHECK (public.is_negocio_owner(negocio_id) OR public.is_admin());
CREATE POLICY personal_self_select ON public.personal
FOR SELECT USING (public.is_staff_member(id));
CREATE POLICY personal_self_update ON public.personal
FOR UPDATE USING (public.is_staff_member(id))
WITH CHECK (public.is_staff_member(id));

-- servicios
CREATE POLICY servicios_select ON public.servicios
FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.negocios n WHERE n.id = servicios.negocio_id AND (n.activo = true OR public.is_negocio_owner(n.id) OR public.is_admin()))
);
CREATE POLICY servicios_owner_crud ON public.servicios
FOR ALL USING (public.is_negocio_owner(negocio_id) OR public.is_admin())
WITH CHECK (public.is_negocio_owner(negocio_id) OR public.is_admin());

-- personal_servicio
CREATE POLICY personal_servicio_select ON public.personal_servicio
FOR SELECT USING (
  EXISTS (
    SELECT 1
    FROM public.personal p
    JOIN public.negocios n ON n.id = p.negocio_id
    WHERE p.id = personal_servicio.personal_id
      AND (n.activo = true OR public.is_negocio_owner(n.id) OR public.is_admin())
  )
);
CREATE POLICY personal_servicio_owner_crud ON public.personal_servicio
FOR ALL USING (
  EXISTS (
    SELECT 1
    FROM public.personal p
    WHERE p.id = personal_servicio.personal_id
      AND public.is_negocio_owner(p.negocio_id)
  ) OR public.is_admin()
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.personal p
    WHERE p.id = personal_servicio.personal_id
      AND public.is_negocio_owner(p.negocio_id)
  ) OR public.is_admin()
);

-- conjunto_horario / dia_horario
CREATE POLICY conjunto_horario_select ON public.conjunto_horario
FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.negocios n
    WHERE n.id = conjunto_horario.negocio_id
      AND (n.activo = true OR public.is_negocio_owner(n.id) OR public.is_admin())
  )
);
CREATE POLICY conjunto_horario_owner_crud ON public.conjunto_horario
FOR ALL USING (public.is_negocio_owner(negocio_id) OR public.is_admin())
WITH CHECK (public.is_negocio_owner(negocio_id) OR public.is_admin());

CREATE POLICY dia_horario_select ON public.dia_horario
FOR SELECT USING (
  EXISTS (
    SELECT 1
    FROM public.conjunto_horario c
    JOIN public.negocios n ON n.id = c.negocio_id
    WHERE c.id = dia_horario.conjunto_horario_id
      AND (n.activo = true OR public.is_negocio_owner(n.id) OR public.is_admin())
  )
);
CREATE POLICY dia_horario_owner_crud ON public.dia_horario
FOR ALL USING (
  EXISTS (
    SELECT 1
    FROM public.conjunto_horario c
    WHERE c.id = dia_horario.conjunto_horario_id
      AND public.is_negocio_owner(c.negocio_id)
  ) OR public.is_admin()
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.conjunto_horario c
    WHERE c.id = dia_horario.conjunto_horario_id
      AND public.is_negocio_owner(c.negocio_id)
  ) OR public.is_admin()
);

-- estado_cita (catálogo)
CREATE POLICY estado_cita_read ON public.estado_cita
FOR SELECT USING (true);

-- citas
CREATE POLICY citas_select_cliente ON public.citas
FOR SELECT USING (usuario_cliente_id = public.current_usuario_id() OR public.is_admin());
CREATE POLICY citas_select_staff_owner ON public.citas
FOR SELECT USING (
  EXISTS (
    SELECT 1
    FROM public.personal p
    WHERE p.id = citas.personal_id
      AND (public.is_staff_member(p.id) OR public.is_negocio_owner(p.negocio_id))
  ) OR public.is_admin()
);
CREATE POLICY citas_insert_cliente ON public.citas
FOR INSERT WITH CHECK (usuario_cliente_id = public.current_usuario_id());
CREATE POLICY citas_update_cliente ON public.citas
FOR UPDATE USING (usuario_cliente_id = public.current_usuario_id());
CREATE POLICY citas_update_staff_owner ON public.citas
FOR UPDATE USING (
  EXISTS (
    SELECT 1 FROM public.personal p
    WHERE p.id = citas.personal_id
      AND (public.is_staff_member(p.id) OR public.is_negocio_owner(p.negocio_id))
  ) OR public.is_admin()
);

-- cancelaciones_cita
CREATE POLICY cancelaciones_select ON public.cancelaciones_cita
FOR SELECT USING (
  public.is_admin() OR
  EXISTS (SELECT 1 FROM public.citas c WHERE c.id = cancelaciones_cita.cita_id AND (c.usuario_cliente_id = public.current_usuario_id()
    OR EXISTS (SELECT 1 FROM public.personal p WHERE p.id = c.personal_id AND (public.is_staff_member(p.id) OR public.is_negocio_owner(p.negocio_id)))))
);
CREATE POLICY cancelaciones_insert ON public.cancelaciones_cita
FOR INSERT WITH CHECK (
  EXISTS (SELECT 1 FROM public.citas c WHERE c.id = cancelaciones_cita.cita_id AND
    (c.usuario_cliente_id = public.current_usuario_id()
     OR EXISTS (SELECT 1 FROM public.personal p WHERE p.id = c.personal_id AND (public.is_staff_member(p.id) OR public.is_negocio_owner(p.negocio_id)))
     OR public.is_admin()))
);

-- metodo_pago / estado_pago (catálogos)
CREATE POLICY metodo_pago_read ON public.metodo_pago
FOR SELECT USING (true);
CREATE POLICY estado_pago_read ON public.estado_pago
FOR SELECT USING (true);

-- compras
CREATE POLICY compras_select ON public.compras
FOR SELECT USING (public.is_negocio_owner(negocio_id) OR public.is_admin());
CREATE POLICY compras_insert ON public.compras
FOR INSERT WITH CHECK (public.is_negocio_owner(negocio_id) OR public.is_admin());
CREATE POLICY compras_update ON public.compras
FOR UPDATE USING (public.is_negocio_owner(negocio_id) OR public.is_admin());

-- suscripciones_plus
CREATE POLICY suscripciones_select ON public.suscripciones_plus
FOR SELECT USING (public.is_negocio_owner(negocio_id) OR public.is_admin());
CREATE POLICY suscripciones_insert ON public.suscripciones_plus
FOR INSERT WITH CHECK (public.is_negocio_owner(negocio_id) OR public.is_admin());
CREATE POLICY suscripciones_update ON public.suscripciones_plus
FOR UPDATE USING (public.is_negocio_owner(negocio_id) OR public.is_admin());

-- promociones
CREATE POLICY promociones_read ON public.promociones
FOR SELECT USING (true);
CREATE POLICY promociones_admin ON public.promociones
FOR ALL USING (public.is_admin())
WITH CHECK (public.is_admin());

-- movimientos_tokens
CREATE POLICY movimientos_select ON public.movimientos_tokens
FOR SELECT USING (public.is_negocio_owner(negocio_id) OR public.is_admin());
CREATE POLICY movimientos_insert ON public.movimientos_tokens
FOR INSERT WITH CHECK (public.is_negocio_owner(negocio_id) OR public.is_admin());
CREATE POLICY movimientos_update ON public.movimientos_tokens
FOR UPDATE USING (public.is_negocio_owner(negocio_id) OR public.is_admin());

-- tipo_comentario (catálogo)
CREATE POLICY tipo_comentario_read ON public.tipo_comentario
FOR SELECT USING (true);

-- comentarios
CREATE POLICY comentarios_select ON public.comentarios
FOR SELECT USING (
  visible = true OR public.is_admin() OR (negocio_id IS NOT NULL AND public.is_negocio_owner(negocio_id))
);
CREATE POLICY comentarios_insert ON public.comentarios
FOR INSERT WITH CHECK (
  usuario_autor_id = public.current_usuario_id()
);
CREATE POLICY comentarios_update_delete ON public.comentarios
FOR ALL USING (
  usuario_autor_id = public.current_usuario_id()
  OR (negocio_id IS NOT NULL AND public.is_negocio_owner(negocio_id))
  OR public.is_admin()
) WITH CHECK (
  usuario_autor_id = public.current_usuario_id()
  OR (negocio_id IS NOT NULL AND public.is_negocio_owner(negocio_id))
  OR public.is_admin()
);

-- estadisticas
CREATE POLICY estadisticas_select ON public.estadisticas
FOR SELECT USING (
  audiencia = 'publico'
  OR (audiencia = 'negocio' AND negocio_id IS NOT NULL AND public.is_negocio_owner(negocio_id))
  OR public.is_admin()
);
CREATE POLICY estadisticas_admin ON public.estadisticas
FOR ALL USING (public.is_admin())
WITH CHECK (public.is_admin());

-- administrador
CREATE POLICY administrador_admin ON public.administrador
FOR ALL USING (public.is_admin())
WITH CHECK (public.is_admin());

-- ======================
-- SUPERFICIE PUBLICA SEGURA (RPC)
-- ======================
CREATE OR REPLACE VIEW public.negocios_publicos AS
SELECT n.id, n.nombre, n.direccion, n.latitud, n.longitud
FROM public.negocios n
WHERE n.activo = true;

CREATE OR REPLACE FUNCTION public.get_public_negocios()
RETURNS SETOF public.negocios_publicos
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT * FROM public.negocios_publicos;
$$;

GRANT EXECUTE ON FUNCTION public.get_public_negocios() TO anon, authenticated;

COMMIT;
