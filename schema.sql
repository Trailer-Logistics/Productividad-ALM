-- ============================================================
-- ESQUEMA DE BASE DE DATOS: PRODUCTIVIDAD OPERARIOS
-- Trailer Logistics - Supabase/Postgres
-- ============================================================
-- Ejecutar en el SQL Editor de Supabase en orden

-- 1. TABLA DE OPERARIOS (maestro de personas)
-- ============================================================
CREATE TABLE IF NOT EXISTS "3-operarios" (
    id              SERIAL PRIMARY KEY,
    rut             TEXT UNIQUE,                     -- opcional: pendientes detectados no tienen RUT hasta ser incorporados
    usuario         TEXT UNIQUE NOT NULL,            -- username del WMS (JESPINOZA, PLOPEZ, etc.)
    nombre          TEXT,                            -- opcional al crearse como pendiente; requerido al incorporar
    cargo           TEXT,                            -- opcional al crearse como pendiente; requerido al incorporar
    tipo_equipo     TEXT,                            -- SIMPLE, DOBLE
    factor_ajustado NUMERIC(3,2) DEFAULT 1.00,       -- factor 0.70 a 1.00
    activo          BOOLEAN DEFAULT TRUE,            -- espejo historico; la fuente de verdad es "estado"
    estado          TEXT NOT NULL DEFAULT 'activo'
                    CHECK (estado IN ('pendiente','activo','inactivo')),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Indices para detección idempotente y filtro por estado
CREATE UNIQUE INDEX IF NOT EXISTS uq_operarios_usuario_upper ON "3-operarios" (UPPER(usuario));
CREATE INDEX IF NOT EXISTS idx_operarios_estado ON "3-operarios" (estado);


-- 1b. TABLA DE ALIAS DE OPERARIOS
-- ============================================================
-- La minuta operacional es manual, por lo que los nombres varian.
-- Esta tabla mapea variantes (ej: GVALENZUELA, GUSTAVO) al usuario WMS (GUVALENZUE).
CREATE TABLE IF NOT EXISTS "3-operarios_alias" (
    id          SERIAL PRIMARY KEY,
    alias       TEXT NOT NULL UNIQUE,
    usuario     TEXT NOT NULL REFERENCES "3-operarios"(usuario),
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_alias_lookup ON "3-operarios_alias" (UPPER(alias));

-- Alias conocidos
INSERT INTO "3-operarios_alias" (alias, usuario) VALUES
('GVALENZUELA', 'GUVALENZUE'),
('GUSTAVO VALENZUELA', 'GUVALENZUE'),
('GUSTAVO', 'GUVALENZUE'),
('CESAR', 'CGARCES'),
('JAVIER', 'JALARCON'),
('JOSE LUIS', 'JESPINOZA'),
('JOSE', 'JESPINOZA'),
('PEDRO', 'PLOPEZ'),
('SIXTO', 'SNUNEZ'),
('SNUNES', 'SNUNEZ'),
('CARLOS', 'CAGUAS'),
('CAGUA', 'CAGUAS'),
('CAR', 'CAGUAS'),
('CARL', 'CAGUAS'),
('CRISTOPHER', 'CTESTA'),
('ERIANNIS', 'EGALUE'),
('ERIENNIS', 'EGALUE'),
('MILCA', 'MSANCHEZ'),
('MILKA', 'MSANCHEZ'),
('MSANCHES', 'MSANCHEZ'),
('SEBASTIAN', 'SMOLINA'),
('JEANNETTE MAR', 'JMARDONES'),
('GUSTAVO COLLASO', 'GCOLLAZOS'),
('GUSTAVO COLLAZOS', 'GCOLLAZOS'),
('GCOLLAZO', 'GCOLLAZOS'),
('Jvalderrey', 'JVALDERREY')
ON CONFLICT (alias) DO NOTHING;


-- 2. TABLA HISTORIAL LPN CAJAS
-- ============================================================
-- Captura movimientos del recepcionista (el gruero no registra aqui)
CREATE TABLE IF NOT EXISTS "3-historial_cajas" (
    id              BIGSERIAL PRIMARY KEY,
    id_lpn          TEXT NOT NULL,
    producto        TEXT,
    empresa_prod    TEXT,
    ubicacion       TEXT,
    ubicacion_prev  TEXT,
    fecha_mod       TIMESTAMPTZ NOT NULL,
    usuario         TEXT NOT NULL,
    mar_qa          TEXT,
    en_jornada      BOOLEAN GENERATED ALWAYS AS (EXTRACT(HOUR FROM fecha_mod) <= 18) STORED,
    es_mov_valido   BOOLEAN GENERATED ALWAYS AS (
        CASE
            WHEN ubicacion IS NOT NULL AND ubicacion_prev IS NOT NULL
                 AND ubicacion <> ubicacion_prev
                 AND ubicacion_prev <> '0'
            THEN TRUE
            ELSE FALSE
        END
    ) STORED,
    dia             DATE GENERATED ALWAYS AS (fecha_mod::date) STORED,
    semana_carga    TEXT
);

CREATE INDEX IF NOT EXISTS idx_cajas_usuario_dia
    ON "3-historial_cajas" (usuario, dia)
    WHERE en_jornada = TRUE AND es_mov_valido = TRUE;

ALTER TABLE "3-historial_cajas" ADD CONSTRAINT uq_cajas_dedup
    UNIQUE (id_lpn, ubicacion_prev, ubicacion, usuario, fecha_mod);


-- 3. TABLA HISTORIAL LPN DESTINO
-- ============================================================
-- Captura movimientos del gruero (el recepcionista no registra aqui)
CREATE TABLE IF NOT EXISTS "3-historial_destino" (
    id              BIGSERIAL PRIMARY KEY,
    id_lpn          TEXT NOT NULL,
    producto        TEXT,
    empresa_prod    TEXT,
    ubic_actual     TEXT,
    ubic_anterior   TEXT,
    fecha_mod       TIMESTAMPTZ NOT NULL,
    usuario         TEXT NOT NULL,
    en_jornada      BOOLEAN GENERATED ALWAYS AS (EXTRACT(HOUR FROM fecha_mod) <= 18) STORED,
    es_mov_valido   BOOLEAN GENERATED ALWAYS AS (
        CASE
            WHEN ubic_actual IS NOT NULL AND ubic_anterior IS NOT NULL
                 AND ubic_actual <> ubic_anterior
                 AND ubic_anterior <> '0'
            THEN TRUE
            ELSE FALSE
        END
    ) STORED,
    dia             DATE GENERATED ALWAYS AS (fecha_mod::date) STORED,
    semana_carga    TEXT
);

CREATE INDEX IF NOT EXISTS idx_destino_usuario_dia
    ON "3-historial_destino" (usuario, dia)
    WHERE en_jornada = TRUE AND es_mov_valido = TRUE;

ALTER TABLE "3-historial_destino" ADD CONSTRAINT uq_destino_dedup
    UNIQUE (id_lpn, ubic_anterior, ubic_actual, usuario, fecha_mod);


-- 4. TABLA CONFIGURACION DE HORARIOS
-- ============================================================
CREATE TABLE IF NOT EXISTS "3-config_horarios" (
    id              SERIAL PRIMARY KEY,
    dia_semana      INT NOT NULL CHECK (dia_semana BETWEEN 1 AND 7),
    nombre_dia      TEXT NOT NULL,
    horas_jornada   NUMERIC(4,2) NOT NULL,
    efectividad     NUMERIC(4,2) NOT NULL DEFAULT 0.85,
    horas_efectivas NUMERIC(5,2) GENERATED ALWAYS AS (horas_jornada * efectividad) STORED
);


-- 5. VIEW: PRODUCTIVIDAD DIARIA POR OPERARIO
-- ============================================================
-- LOGICA DE ASIGNACION DE MOVIMIENTOS:
--
-- LPN Cajas (sistema):    solo captura al recepcionista
-- LPN Destino (sistema):  solo captura al gruero
--
-- IN Minutas:  se asigna a columna despachado_por (desp/carg = gruero),
--              porque LPN cajas solo registra al recepcionista.
--
-- OUT Minutas: se asigna a columna recep_por (recp/desp = recepcionista),
--              porque LPN destino solo registra al gruero.
--              EXCEPCION EASY: tambien se suma despachado_por (gruero) x2,
--              porque EASY divide las OS y no aparecen en LPN destino.
--
-- Pallets EASY siempre se multiplican x2.
--
-- La tabla 3-operarios_alias resuelve variantes de nombres manuales.
-- ============================================================

CREATE OR REPLACE VIEW "3-v_productividad_diaria" AS
WITH mov_cajas AS (
    SELECT UPPER(usuario) AS usuario, dia, COUNT(*) AS movimientos_cajas
    FROM "3-historial_cajas"
    WHERE en_jornada = TRUE AND es_mov_valido = TRUE
    GROUP BY UPPER(usuario), dia
),
mov_destino AS (
    SELECT UPPER(usuario) AS usuario, dia, COUNT(*) AS movimientos_destino
    FROM "3-historial_destino"
    WHERE en_jornada = TRUE AND es_mov_valido = TRUE
    GROUP BY UPPER(usuario), dia
),
-- OUT minutas: recep_por para TODOS los OUT (EASY x2)
--            + despachado_por SOLO para EASY (x2), porque no sale en LPN destino
min_out AS (
    SELECT usuario, dia, SUM(pallets_out) AS pallets_despacho
    FROM (
        -- Recepcionista: todos los OUT
        SELECT UPPER(COALESCE(a.usuario, m.recep_por)) AS usuario, m.fecha AS dia,
            CASE WHEN UPPER(m.cliente) = 'EASY' THEN m.pallets * 2 ELSE m.pallets END AS pallets_out
        FROM "1-minuta_operacional" m
        LEFT JOIN "3-operarios_alias" a ON UPPER(a.alias) = UPPER(m.recep_por)
        WHERE UPPER(m.flujo) = 'OUT' AND m.recep_por IS NOT NULL

        UNION ALL

        -- Gruero: SOLO cliente EASY (excepcion porque no sale en LPN destino)
        SELECT UPPER(COALESCE(a.usuario, m.despachado_por)) AS usuario, m.fecha AS dia,
            m.pallets * 2 AS pallets_out
        FROM "1-minuta_operacional" m
        LEFT JOIN "3-operarios_alias" a ON UPPER(a.alias) = UPPER(m.despachado_por)
        WHERE UPPER(m.flujo) = 'OUT' AND UPPER(m.cliente) = 'EASY' AND m.despachado_por IS NOT NULL
    ) sub
    GROUP BY usuario, dia
),
-- IN minutas: solo despachado_por (gruero), porque LPN cajas solo captura al recepcionista
min_in AS (
    SELECT
        UPPER(COALESCE(a.usuario, m.despachado_por)) AS usuario,
        m.fecha AS dia,
        COALESCE(SUM(m.pallets), 0) AS pallets_recepcion
    FROM "1-minuta_operacional" m
    LEFT JOIN "3-operarios_alias" a ON UPPER(a.alias) = UPPER(m.despachado_por)
    WHERE UPPER(m.flujo) = 'IN' AND m.despachado_por IS NOT NULL
    GROUP BY UPPER(COALESCE(a.usuario, m.despachado_por)), m.fecha
),
todos_dias AS (
    SELECT usuario, dia FROM mov_cajas
    UNION
    SELECT usuario, dia FROM mov_destino
    UNION
    SELECT usuario, dia FROM min_out
    UNION
    SELECT usuario, dia FROM min_in
)
SELECT
    UPPER(td.usuario) AS usuario,
    o.nombre,
    o.cargo,
    o.tipo_equipo,
    o.factor_ajustado,
    td.dia,
    EXTRACT(ISODOW FROM td.dia)::INT AS dia_semana,
    EXTRACT(WEEK FROM td.dia)::INT AS semana,
    EXTRACT(MONTH FROM td.dia)::INT AS mes,
    EXTRACT(YEAR FROM td.dia)::INT AS anio,
    COALESCE(mc.movimientos_cajas, 0) AS mov_cajas,
    COALESCE(md.movimientos_destino, 0) AS mov_destino,
    COALESCE(mo.pallets_despacho, 0) AS pallets_despacho,
    COALESCE(mi.pallets_recepcion, 0) AS pallets_recepcion,
    COALESCE(mc.movimientos_cajas, 0)
        + COALESCE(md.movimientos_destino, 0)
        + COALESCE(mo.pallets_despacho, 0)
        + COALESCE(mi.pallets_recepcion, 0) AS total_movimientos,
    ch.horas_efectivas,
    CASE
        WHEN ch.horas_efectivas > 0 THEN
            ROUND(
                (COALESCE(mc.movimientos_cajas, 0)
                + COALESCE(md.movimientos_destino, 0)
                + COALESCE(mo.pallets_despacho, 0)
                + COALESCE(mi.pallets_recepcion, 0))::NUMERIC
                / ch.horas_efectivas, 2)
        ELSE 0
    END AS productividad_hora
FROM todos_dias td
LEFT JOIN "3-operarios" o ON UPPER(o.usuario) = UPPER(td.usuario)
LEFT JOIN mov_cajas mc ON mc.usuario = UPPER(td.usuario) AND mc.dia = td.dia
LEFT JOIN mov_destino md ON md.usuario = UPPER(td.usuario) AND md.dia = td.dia
LEFT JOIN min_out mo ON mo.usuario = UPPER(td.usuario) AND mo.dia = td.dia
LEFT JOIN min_in mi ON mi.usuario = UPPER(td.usuario) AND mi.dia = td.dia
LEFT JOIN "3-config_horarios" ch ON ch.dia_semana = EXTRACT(ISODOW FROM td.dia)::INT
WHERE o.id IS NOT NULL AND o.estado = 'activo';  -- pendientes e inactivos excluidos de reportes


-- 6. TABLA SNAPSHOT: Productividad final materializada
-- ============================================================
CREATE TABLE IF NOT EXISTS "3-productividad_final" (
    id              BIGSERIAL PRIMARY KEY,
    usuario         TEXT NOT NULL,
    nombre          TEXT,
    cargo           TEXT,
    dia             DATE NOT NULL,
    dia_semana      INT,
    semana          INT,
    mes             INT,
    anio            INT,
    mov_cajas       INT DEFAULT 0,
    mov_destino     INT DEFAULT 0,
    pallets_despacho INT DEFAULT 0,    -- OUT minutas
    pallets_recepcion INT DEFAULT 0,   -- IN minutas
    total_movimientos INT DEFAULT 0,
    horas_efectivas NUMERIC(5,2),
    productividad_hora NUMERIC(8,2),
    factor_ajustado NUMERIC(3,2),
    fecha_calculo   TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(usuario, dia)
);

CREATE INDEX IF NOT EXISTS idx_prod_final_usuario ON "3-productividad_final" (usuario, dia);
CREATE INDEX IF NOT EXISTS idx_prod_final_mes ON "3-productividad_final" (anio, mes);


-- 7. FUNCION: Materializar productividades
-- ============================================================
CREATE OR REPLACE FUNCTION fn_3_guardar_productividad(
    p_fecha_desde DATE,
    p_fecha_hasta DATE
) RETURNS INT AS $$
DECLARE
    filas integer;
    v_hasta date;
    huerfanos integer;
BEGIN
    v_hasta := LEAST(p_fecha_hasta, (now() AT TIME ZONE 'America/Santiago')::date);

    DELETE FROM "3-productividad_final" pf
    WHERE NOT EXISTS (
        SELECT 1 FROM "3-v_productividad_diaria" v
        WHERE v.usuario = pf.usuario AND v.dia = pf.dia
    );
    GET DIAGNOSTICS huerfanos = ROW_COUNT;

    DELETE FROM "3-productividad_final" pf
    WHERE pf.dia BETWEEN p_fecha_desde AND v_hasta
      AND NOT EXISTS (
          SELECT 1 FROM "3-v_productividad_diaria" v
          WHERE v.usuario = pf.usuario AND v.dia = pf.dia
      );

    INSERT INTO "3-productividad_final" (
        usuario, nombre, cargo, dia, dia_semana, semana, mes, anio,
        mov_cajas, mov_destino, pallets_despacho, pallets_recepcion,
        total_movimientos, horas_efectivas, productividad_hora, factor_ajustado
    )
    SELECT
        usuario, nombre, cargo, dia, dia_semana, semana, mes, anio,
        mov_cajas, mov_destino,
        pallets_despacho,
        pallets_recepcion,
        total_movimientos, horas_efectivas, productividad_hora, factor_ajustado
    FROM "3-v_productividad_diaria"
    WHERE dia BETWEEN p_fecha_desde AND v_hasta
    ON CONFLICT (usuario, dia) DO UPDATE SET
        mov_cajas = EXCLUDED.mov_cajas,
        mov_destino = EXCLUDED.mov_destino,
        pallets_despacho = EXCLUDED.pallets_despacho,
        pallets_recepcion = EXCLUDED.pallets_recepcion,
        total_movimientos = EXCLUDED.total_movimientos,
        horas_efectivas = EXCLUDED.horas_efectivas,
        productividad_hora = EXCLUDED.productividad_hora,
        factor_ajustado = EXCLUDED.factor_ajustado,
        fecha_calculo = NOW();
    GET DIAGNOSTICS filas = ROW_COUNT;
    RETURN filas;
END;
$$ LANGUAGE plpgsql;


-- 7. FUNCION: DETECTAR OPERARIOS NUEVOS (PENDIENTES)
-- ============================================================
-- Busca usuarios WMS presentes en historial_cajas/destino que NO esten
-- en "3-operarios" y los inserta con estado='pendiente'. Idempotente.
-- Se invoca desde index.html tras cada carga. El usuario decide en la
-- pagina Operarios si los incorpora (→ estado='activo', con cargo) o
-- los rechaza (→ estado='inactivo').
CREATE OR REPLACE FUNCTION public.fn_3_detectar_operarios_pendientes()
RETURNS TABLE(usuario_detectado TEXT, origen TEXT) AS $$
BEGIN
    RETURN QUERY
    WITH usuarios_wms AS (
        SELECT DISTINCT UPPER(usuario) AS usuario, 'historial_cajas' AS origen
        FROM "3-historial_cajas"
        WHERE usuario IS NOT NULL AND usuario <> ''
        UNION
        SELECT DISTINCT UPPER(usuario), 'historial_destino'
        FROM "3-historial_destino"
        WHERE usuario IS NOT NULL AND usuario <> ''
    ),
    nuevos AS (
        SELECT uw.usuario, MIN(uw.origen) AS origen
        FROM usuarios_wms uw
        WHERE NOT EXISTS (
            SELECT 1 FROM "3-operarios" o
            WHERE UPPER(o.usuario) = uw.usuario
        )
        GROUP BY uw.usuario
    ),
    inserts AS (
        INSERT INTO "3-operarios" (usuario, nombre, estado, factor_ajustado)
        SELECT n.usuario, n.usuario, 'pendiente', 1.00
        FROM nuevos n
        ON CONFLICT DO NOTHING
        RETURNING usuario
    )
    SELECT n.usuario, n.origen
    FROM nuevos n
    JOIN inserts i ON UPPER(i.usuario) = n.usuario;
END;
$$ LANGUAGE plpgsql;
