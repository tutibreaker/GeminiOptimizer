#!/system/bin/sh

# Espera a que el sistema haya arrancado completamente
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done
# Espera adicional opcional
sleep 20

# --- Inicio de Optimizaciones ---

# Log (opcional, útil para depuración)
# LOGFILE="/sdcard/KernelSU_A24_Optimizer.log" # O usa /data/local/tmp/
# echo "$(date): Iniciando Optimizador A24 (KernelSU)" > $LOGFILE
# exec >> $LOGFILE 2>&1 # Redirige stdout y stderr al log

echo "$(date): Iniciando Optimizador A24 (KernelSU)"

# 1. Ajustes de Gestión de Memoria
echo "Aplicando ajustes de memoria..."
sysctl -w vm.swappiness=60 # Prioriza mantener apps en RAM física. Ajusta entre 10-100.
sysctl -w vm.vfs_cache_pressure=50 # Reduce presión en caché VFS. Ajusta entre 10-200.

# 2. Configuración de ZRAM
# ¡¡¡CRÍTICO PARA SAMSUNG A24!!! AJUSTA 'ZRAM_SIZE_MB' SEGÚN TU RAM:
# - Si tienes 4GB RAM -> Prueba ZRAM_SIZE_MB=2048 (2GB)
# - Si tienes 6GB RAM -> Prueba ZRAM_SIZE_MB=3072 (3GB) <-- VALOR POR DEFECTO ACTUAL
# - Si tienes 8GB RAM -> Prueba ZRAM_SIZE_MB=4096 (4GB)
# Puedes experimentar con valores ligeramente mayores o menores (ej. 40-60% de tu RAM).
ZRAM_DEVICE="/sys/block/zram0" # Usualmente es zram0, verifica si es diferente en tu A24
ZRAM_SIZE_MB=2048 # <-- ¡¡¡AJUSTA ESTO!!! (Default para 6GB RAM)
ZRAM_SIZE_BYTES=$((ZRAM_SIZE_MB * 1024 * 1024))

echo "Configurando ZRAM en $ZRAM_DEVICE..."
if [ -e "$ZRAM_DEVICE/disksize" ]; then
    swapoff $ZRAM_DEVICE >/dev/null 2>&1
    echo 1 > "$ZRAM_DEVICE/reset"
    sleep 1

    # Algoritmo de compresión (lz4 es preferido si está disponible)
    if grep -q "lz4" "$ZRAM_DEVICE/comp_algorithm"; then
        echo "lz4" > "$ZRAM_DEVICE/comp_algorithm"
    elif grep -q "lzo" "$ZRAM_DEVICE/comp_algorithm"; then
        echo "lzo" > "$ZRAM_DEVICE/comp_algorithm"
    fi

    echo "$ZRAM_SIZE_BYTES" > "$ZRAM_DEVICE/disksize"
    mkswap $ZRAM_DEVICE >/dev/null 2>&1
    swapon $ZRAM_DEVICE -p 32767 >/dev/null 2>&1 # Prioridad alta

    echo "ZRAM configurado a ${ZRAM_SIZE_MB}MB con $(cat $ZRAM_DEVICE/comp_algorithm)."
else
    echo "Advertencia: No se encontró $ZRAM_DEVICE/disksize. No se pudo configurar ZRAM."
fi

# 3. Mejora de Entropía
echo "Ajustando umbrales de entropía..."
ENTROPY_DIR="/proc/sys/kernel/random"
if [ -e "$ENTROPY_DIR/read_wakeup_threshold" ]; then
    echo 128 > "$ENTROPY_DIR/read_wakeup_threshold"
fi
if [ -e "$ENTROPY_DIR/write_wakeup_threshold" ]; then
    echo 256 > "$ENTROPY_DIR/write_wakeup_threshold"
fi

# 4. Priorización de Procesos (Ejemplo Básico - Efectividad Limitada)
# El uso de 'renice' es muy básico en Android moderno.
# echo "Priorización básica de procesos no implementada activamente (ver comentarios)."
# FG_PID=$(dumpsys activity activities | grep -E 'mResumedActivity' | sed 's/.* pid=\([0-9]*\).*/\1/')
# if [ -n "$FG_PID" ] && [ "$FG_PID" -gt 0 ]; then
#    renice -n -10 -p $FG_PID
#    echo "Prioridad aumentada (renice) para PID $FG_PID (app en primer plano estimada)"
# fi

# 5. Limpieza Agresiva de Apps en Segundo Plano (¡¡MUY AGRESIVO - DESACTIVADO POR DEFECTO!!)
ENABLE_AGGRESSIVE_KILLER=0 # Cambia a 1 para activar, ¡CON PRECAUCIÓN!
KILL_INTERVAL_SECONDS=300 # Intervalo en segundos (5 minutos)

# Lista blanca: Apps que NUNCA deben cerrarse (¡¡REVISA Y AÑADE LAS TUYAS!!)
WHITELIST_PACKAGES=(
  "com.android.systemui"
  "com.android.settings"
  "android" # Proceso del sistema principal
  "com.google.android.gms" # Servicios de Google Play
  "com.google.android.gsf" # Google Services Framework
  "com.sec.android.app.launcher" # Launcher One UI (verifica si es este en A24)
  "com.samsung.android.knox.containeragent" # Parte de Knox/Seguridad Samsung
  "com.samsung.android.incallui" # Interfaz de llamada
  "com.samsung.android.messaging" # App de Mensajes Samsung (si la usas)
  "com.android.phone"
  "com.android.nfc"
  # --- ¡¡AÑADE AQUÍ TUS APPS IMPORTANTES!! ---
  # Ejemplo: Teclado (busca el nombre del paquete de tu teclado)
  # "com.google.android.inputmethod.latin" # Gboard
  # "com.samsung.android.honeyboard" # Teclado Samsung
  # Ejemplo: Mensajería
  # "com.whatsapp"
  # "org.telegram.messenger"
  # Ejemplo: Otras apps que necesiten correr en segundo plano
  # "com.spotify.music" # Si quieres que siga sonando
)

killer_loop() {
  if [ "$ENABLE_AGGRESSIVE_KILLER" -eq 1 ]; then
    echo "$(date): Ejecutando limpieza agresiva de apps..."
    # Obtiene procesos (ps puede necesitar ruta completa en algunos entornos)
    /system/bin/ps -A -o PID,NAME | while read -r pid name; do
      # Intenta obtener el nombre del paquete
      package_name=$(dumpsys activity p $pid | grep "packageName=" | cut -d "=" -f 2 | cut -d " " -f 1)
      if [ -z "$package_name" ]; then
          package_name=$name
      fi

      # Ignora si no se pudo obtener un nombre de paquete/proceso válido
      if [ -z "$package_name" ]; then
          continue
      fi

      # Verifica si está en la lista blanca
      is_whitelisted=0
      for item in "${WHITELIST_PACKAGES[@]}"; do
        # Comprobación más robusta
        if echo "$package_name" | grep -q "^${item}$"; then
          is_whitelisted=1
          break
        fi
      done

      # Si no está en lista blanca y parece ser una app de usuario
      if [ "$is_whitelisted" -eq 0 ] && echo "$package_name" | grep -q -E '^(com\.|org\.|app\.)'; then
         # Intenta verificar si está en caché (método simplificado)
         if dumpsys activity p $pid | grep -q -E 'state=(CACHED|STOPPED)'; then
             echo "Cerrando app en caché/segundo plano: $package_name (PID: $pid)"
             am kill "$package_name" >/dev/null 2>&1
             # kill -9 $pid # ¡Evitar si es posible!
         fi
      fi
    done
    echo "$(date): Limpieza completada."
  fi
}

# Bucle para ejecutar el limpiador periódicamente si está activado
if [ "$ENABLE_AGGRESSIVE_KILLER" -eq 1 ]; then
    (while true; do
        # Asegurarse que el sistema esté completamente listo
        current_boot_completed=$(getprop sys.boot_completed)
        if [ "$current_boot_completed" = "1" ]; then
            killer_loop
        else
            echo "$(date): Esperando boot completed para iniciar killer loop..."
        fi
        sleep "$KILL_INTERVAL_SECONDS"
    done) & # Ejecuta en segundo plano
    echo "Limpiador agresivo de apps activado (Intervalo: ${KILL_INTERVAL_SECONDS}s). ¡REVISA TU WHITELIST!"
else
    echo "Limpiador agresivo de apps desactivado."
fi

echo "$(date): Optimizador A24 (KernelSU) finalizado."
