# Productividad - ALM | Trailer Logistics

Sistema de control de productividad operacional para Almacenaje de Trailer Logistics.

## Descripcion

Plataforma web que permite cargar datos del WMS, calcular automaticamente la productividad diaria de cada operario, y visualizar los resultados en un dashboard interactivo.

## Archivos

- index.html - Pagina de carga de datos
- dashboard.html - Dashboard de productividad
- operarios.html - Gestion de operarios
- schema.sql - Esquema de base de datos (tablas, vistas, funciones)
- detalle_diario_operario.sql - Tabla y funcion de detalle diario por operario

## Base de datos (Supabase)

**Proyecto Supabase:** `WMS_Almacenaje` (ref `xcmpuyjoidexrgpnotkj`, org Trailer Logistics)

### Tablas principales
- `3-operarios` - Maestro de operarios con usuario WMS, cargo, factor ajustado
- `3-operarios_alias` - Mapeo de nombres manuales de minuta a usuario WMS (ej: GVALENZUELA -> GUVALENZUE)
- `3-historial_cajas` - Movimientos LPN de cajas desde WMS (solo registra al recepcionista)
- `3-historial_destino` - Movimientos LPN destino desde WMS (solo registra al gruero)
- `3-productividad_final` - Snapshot materializado de productividad diaria por operario
- `3-productividad_semanal` - Snapshot materializado de productividad semanal por operario
- `3-detalle_diario_operario` - Detalle diario por operario (mov LPN cajas, LPN destino, OUT minutas, IN minutas)
- `3-config_horarios` - Horas de jornada y efectividad por dia de semana
- `3-log_cargas` - Bitacora de cada carga de WMS desde `index.html` (cuantas filas, duracion, archivo, usuario que cargo)

### Tabla externa consumida
- `1-minuta_operacional` - Minuta manual operacional (proyecto Minuta Almacenaje). Usada para IN/OUT minutas y para el total de lineas por dia en el grafico de tendencia del dashboard.

### Mapeo codigo -> tabla

| Archivo | Tablas / vistas | Operacion |
|---------|-----------------|-----------|
| `index.html` | `3-historial_cajas`, `3-historial_destino` | INSERT masivo desde CSV WMS |
| `index.html` | `3-log_cargas` | INSERT bitacora por carga |
| `index.html` | `3-operarios` | ping de salud |
| `index.html` | `3-productividad_final` | SELECT para verificacion post-carga |
| `dashboard.html` | `3-productividad_final`, `3-productividad_semanal` | SELECT principal del dashboard |
| `dashboard.html` | `1-minuta_operacional` | SELECT lineas IN+OUT por dia |
| `operarios.html` | `3-operarios` | CRUD completo |

### Vista principal: `3-v_productividad_diaria`

Calcula la productividad combinando 4 tipos de movimiento:

| Tipo | Fuente | Asignado a | Razon |
|------|--------|-----------|-------|
| **LPN Cajas** | Sistema WMS | Recepcionista | El sistema solo registra al recepcionista |
| **LPN Destino** | Sistema WMS | Gruero | El sistema solo registra al gruero |
| **IN Minutas** | Minuta operacional (flujo IN) | `despachado_por` (gruero) | El gruero no queda en LPN cajas, la minuta lo compensa |
| **OUT Minutas** | Minuta operacional (flujo OUT) | `recep_por` (recepcionista) | El recepcionista no queda en LPN destino, la minuta lo compensa |

**Excepcion cliente EASY en OUT:** Ademas se suma `despachado_por` (gruero) x2, porque EASY divide las OS y no aparecen en LPN destino. **Pallets EASY siempre se multiplican x2.**

Formula: `productividad_hora = total_movimientos / horas_efectivas`

### Resolucion de alias
La minuta operacional es manual, por lo que los nombres pueden variar. La tabla `3-operarios_alias` resuelve variantes (ej: GVALENZUELA, GUSTAVO VALENZUELA, GUSTAVO) al usuario WMS correcto (GUVALENZUE).

### Manejo de duplicados
- `3-historial_cajas`: constraint UNIQUE en (id_lpn, ubicacion_prev, ubicacion, usuario, fecha_mod) - si se sube el mismo archivo dos veces, los duplicados se ignoran automaticamente
- `3-historial_destino`: constraint UNIQUE en (id_lpn, ubic_anterior, ubic_actual, usuario, fecha_mod) - mismo comportamiento
- `3-productividad_final`: UPSERT por (usuario, dia) - recalcular sobreescribe sin duplicar
- `3-detalle_diario_operario`: UPSERT por (usuario, dia) - misma logica

### Funciones principales (RPC via PostgREST)
Invocadas desde el codigo:
- `fn_3_guardar_productividad(fecha_desde, fecha_hasta)` - Materializa `3-v_productividad_diaria` en `3-productividad_final`. Usada desde `index.html` tras cada carga y desde `dashboard.html` al recalcular.
- `fn_3_actualizar_productividad_semanal(fecha_desde, fecha_hasta)` - Recalcula `3-productividad_semanal` a partir del diario. Usada desde `index.html` y `dashboard.html`.
- `fn_3_limpiar_historial_antiguo()` - Purga registros antiguos de `3-historial_cajas` / `3-historial_destino`. Usada desde `index.html` al final de cada carga.
- `fn_guardar_detalle_diario(fecha_desde, fecha_hasta)` - Pobla/actualiza `3-detalle_diario_operario`.

Otras funciones presentes en la base (no invocadas directamente desde el frontend, probablemente auxiliares o de trigger):
- `fn_3_cajas_calcular`, `fn_3_destino_calcular`, `fn_3_config_horas_efectivas`, `fn_3_calcular_bono`, `fn_trigger_recalc_minuta`

### Gaps entre `schema.sql` y la base real
Tablas y funciones existentes en Supabase pero **no versionadas** en el repo:
- Tablas: `3-log_cargas`, `3-productividad_semanal`
- Funciones: `fn_3_actualizar_productividad_semanal`, `fn_3_limpiar_historial_antiguo`, `fn_3_cajas_calcular`, `fn_3_destino_calcular`, `fn_3_config_horas_efectivas`, `fn_3_calcular_bono`, `fn_trigger_recalc_minuta`

Riesgo: si se clona el repo y se corre `schema.sql` en limpio, la app no funciona completa. Pendiente dumpear estos objetos al repo.

## Dashboard - Flujo Diario en Gráfico

En vista Diaria, el grafico de "Tendencia de Productividad General" muestra sobre cada punto la cantidad total de lineas de minuta (IN + OUT) del dia, consultadas desde `1-minuta_operacional`. Esto permite correlacionar productividad con volumen de flujo en cada jornada.

---
Desarrollado para Trailer Logistics | 2026
