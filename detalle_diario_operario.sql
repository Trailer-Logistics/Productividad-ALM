-- ============================================================
-- TABLA: "3-detalle_diario_operario"
-- Guarda por operario/dia el desglose de:
--   - Movimientos LPN Cajas
--   - Movimientos LPN Destino
--   - OUT Minutas (despacho)
--   - IN Minutas (recepcion)
-- Permite filtrar por operario y descargar por dia especifico
-- ============================================================

-- 1. CREAR TABLA
-- ============================================================
CREATE TABLE IF NOT EXISTS "3-detalle_diario_operario" (
    id                      BIGSERIAL PRIMARY KEY,
    usuario                 TEXT NOT NULL,
    nombre                  TEXT,
    cargo                   TEXT,
    dia                     DATE NOT NULL,
    semana                  INT,
    mes                     INT,
    anio                    INT,

    -- LPN Cajas (movimientos validos en jornada)
    mov_lpn_cajas           INT DEFAULT 0,

    -- LPN Destino (movimientos validos en jornada)
    mov_lpn_destino         INT DEFAULT 0,

    -- Minutas desglosadas
    out_minutas             NUMERIC(10,2) DEFAULT 0,   -- OUT: recep_por + EASY despachado_por x2
    in_minutas              NUMERIC(10,2) DEFAULT 0,   -- IN: despachado_por

    -- Total y productividad
    total_movimientos       NUMERIC(10,2) DEFAULT 0,
    horas_efectivas         NUMERIC(5,2),
    productividad_hora      NUMERIC(8,2),

    -- Auditoria
    actualizado_en          TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(usuario, dia)
);

CREATE INDEX IF NOT EXISTS idx_detalle_diario_usuario ON "3-detalle_diario_operario" (usuario, dia);
CREATE INDEX IF NOT EXISTS idx_detalle_diario_dia     ON "3-detalle_diario_operario" (dia);
CREATE INDEX IF NOT EXISTS idx_detalle_diario_mes     ON "3-detalle_diario_operario" (anio, mes);


-- 2. FUNCION: Poblar/actualizar la tabla para un rango de fechas
-- ============================================================
-- Uso: SELECT fn_guardar_detalle_diario('2026-01-01', '2026-12-31');

CREATE OR REPLACE FUNCTION fn_guardar_detalle_diario(
    p_fecha_desde DATE,
    p_fecha_hasta DATE
) RETURNS INT AS $$
DECLARE
    v_count INT;
BEGIN
    INSERT INTO "3-detalle_diario_operario" (
        usuario, nombre, cargo,
        dia, semana, mes, anio,
        mov_lpn_cajas,
        mov_lpn_destino,
        out_minutas,
        in_minutas,
        total_movimientos,
        horas_efectivas,
        productividad_hora,
        actualizado_en
    )
    SELECT
        v.usuario,
        v.nombre,
        v.cargo,
        v.dia,
        v.semana,
        v.mes,
        v.anio,
        v.mov_cajas,
        v.mov_destino,
        v.pallets_despacho,
        v.pallets_recepcion,
        v.total_movimientos,
        v.horas_efectivas,
        v.productividad_hora,
        NOW()
    FROM "3-v_productividad_diaria" v
    WHERE v.dia BETWEEN p_fecha_desde AND p_fecha_hasta
    ON CONFLICT (usuario, dia) DO UPDATE SET
        nombre                  = EXCLUDED.nombre,
        cargo                   = EXCLUDED.cargo,
        semana                  = EXCLUDED.semana,
        mes                     = EXCLUDED.mes,
        anio                    = EXCLUDED.anio,
        mov_lpn_cajas           = EXCLUDED.mov_lpn_cajas,
        mov_lpn_destino         = EXCLUDED.mov_lpn_destino,
        out_minutas             = EXCLUDED.out_minutas,
        in_minutas              = EXCLUDED.in_minutas,
        total_movimientos       = EXCLUDED.total_movimientos,
        horas_efectivas         = EXCLUDED.horas_efectivas,
        productividad_hora      = EXCLUDED.productividad_hora,
        actualizado_en          = NOW();

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;
