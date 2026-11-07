#!/usr/bin/env bash
#
# redroid-wsl.sh — helper para correr y gestionar instancias de redroid en WSL2.
#
# Instala en la distro con:
#   sudo install -m 0755 redroid-wsl.sh /usr/local/bin/redroid
# y úsalo como:  redroid run 13     redroid run 13 a06     redroid ls
#
# Fuerza siempre el modo compatible con WSL (render por software + memfd).
# Admite "perfiles" de dispositivo (marca/modelo) que fijan núcleos, RAM,
# resolución, densidad y el nombre de modelo. Ver deploy/manual-ejecucion-wsl.md.

set -uo pipefail

GPU_MODE="guest"
DEFAULT_PORT=5555

usage() {
	cat <<'EOF'
redroid — helper de redroid en WSL2

USO:
  redroid run <version> [perfil] [puerto] [args-extra...]   Crear y arrancar
  redroid start <version>                           Arrancar una instancia detenida
  redroid stop <version>                            Detener (conserva datos)
  redroid rm <version>                              Eliminar el contenedor
  redroid reset <version>                           Eliminar contenedor Y datos
  redroid ls                                        Listar instancias redroid
  redroid profiles                                  Listar perfiles de dispositivo
  redroid status <version>                          Estado de arranque (boot_completed)
  redroid logs <version>                            Consola de init del contenedor
  redroid logcat <version>                          Volcado de logcat de Android
  redroid port <version>                            Mostrar el puerto adb publicado
  redroid help                                      Esta ayuda

VERSIONES (funcionan en WSL): 8.1 9 10 11 12 13 14 15
  Sufijo 64only admitido:     12_64only 13_64only 14_64only 15_64only
  Android 16 NO arranca en WSL (se avisa).

PERFIL (opcional): fija núcleos, RAM, pantalla y modelo de un celular real.
  Lista con 'redroid profiles'. Ej.: a06 a15 s24 pixel8 redminote13 ...

EJEMPLOS:
  redroid run 13                 # Android 13, recursos del host
  redroid run 13 a06             # Android 13 con specs de Samsung Galaxy A06
  redroid run 15 s24 5556        # Android 15, specs del Galaxy S24, puerto 5556
  redroid run 14 5555 androidboot.redroid_fps=60
  redroid profiles
EOF
}

# Perfiles de dispositivo. Campos: CORES|RAM|WIDTH|HEIGHT|DPI|BRAND|MANUFACTURER|MODELCODE|NOMBRE
# Fuente: GSMArena (specs de la variante más común). La RAM se limita de verdad,
# pero el total que *muestra* Android sigue siendo el del host (ver manual).
profile_spec() {
	case "$1" in
		a06)          echo "8|4g|720|1600|262|samsung|samsung|SM-A065M|Samsung Galaxy A06" ;;
		a15)          echo "8|4g|1080|2340|396|samsung|samsung|SM-A155M|Samsung Galaxy A15" ;;
		a55)          echo "8|8g|1080|2340|390|samsung|samsung|SM-A556E|Samsung Galaxy A55" ;;
		s24)          echo "10|8g|1080|2340|416|samsung|samsung|SM-S921B|Samsung Galaxy S24" ;;
		redmia3)      echo "8|4g|720|1650|268|Redmi|Xiaomi|23129RN51X|Xiaomi Redmi A3" ;;
		redminote13)  echo "8|6g|1080|2400|395|Redmi|Xiaomi|23124RA7EO|Xiaomi Redmi Note 13" ;;
		xiaomi14)     echo "8|12g|1200|2670|460|Xiaomi|Xiaomi|23127PN0CG|Xiaomi 14" ;;
		motog24)      echo "8|4g|720|1612|269|motorola|motorola|moto_g24|Motorola Moto G24" ;;
		edge50)       echo "8|8g|1220|2712|446|motorola|motorola|moto_edge_50|Motorola Edge 50" ;;
		realmec55)    echo "8|6g|1080|2400|392|realme|realme|RMX3710|Realme C55" ;;
		oppoa58)      echo "8|6g|1080|2400|392|OPPO|OPPO|CPH2577|Oppo A58" ;;
		pixel8)       echo "9|8g|1080|2400|428|google|Google|Pixel_8|Google Pixel 8" ;;
		oneplus12)    echo "8|12g|1440|3168|510|OnePlus|OnePlus|CPH2581|OnePlus 12" ;;
		tecnospark20) echo "8|8g|720|1612|267|TECNO|TECNO|TECNO-KJ5|Tecno Spark 20" ;;
		infinixhot40) echo "8|8g|1080|2460|396|Infinix|Infinix|Infinix-X6836|Infinix Hot 40" ;;
		*) return 1 ;;
	esac
}

PROFILE_KEYS="a06 a15 a55 s24 redmia3 redminote13 xiaomi14 motog24 edge50 realmec55 oppoa58 pixel8 oneplus12 tecnospark20 infinixhot40"

list_profiles() {
	printf '%-14s %-24s %-6s %-5s %-11s %s\n' "PERFIL" "MODELO" "CORES" "RAM" "PANTALLA" "DPI"
	local k c r w h d br mf code name
	for k in $PROFILE_KEYS; do
		IFS='|' read -r c r w h d br mf code name <<<"$(profile_spec "$k")"
		printf '%-14s %-24s %-6s %-5s %-11s %s\n' "$k" "$name" "$c" "$r" "${w}x${h}" "$d"
	done
	echo
	echo "Uso:  redroid run <version-android> <perfil>   (p.ej. redroid run 13 a06)"
	echo "Nota: la RAM se limita de verdad, pero el total que muestra Android sigue"
	echo "      siendo el del host (no hay lxcfs). Los núcleos y la pantalla sí cambian."
}

# version amigable -> tag de imagen. "13"->13.0.0 ; "8.1"->8.1.0 ; "13_64only"->13.0.0_64only
to_tag() {
	local v="$1" suffix="" base
	case "$v" in
		*_64only) suffix="_64only"; v="${v%_64only}" ;;
	esac
	case "$v" in
		8.1) base="8.1.0" ;;
		[0-9]|[0-9][0-9]) base="${v}.0.0" ;;
		*) base="$v" ;;   # ya viene completo, p.ej. 13.0.0
	esac
	printf 'redroid/redroid:%s%s-latest' "$base" "$suffix"
}

# nombre de contenedor y carpeta de datos a partir de la version (sin puntos)
name_of() { printf 'redroid-%s' "$(echo "$1" | tr '.' '_')"; }

require_version() {
	if [ -z "${1:-}" ]; then echo "error: falta <version>. Ver 'redroid help'." >&2; exit 2; fi
}

cmd="${1:-help}"; shift || true

case "$cmd" in
	run)
		require_version "${1:-}"
		VER="$1"; shift

		# ¿el siguiente argumento es un perfil de dispositivo conocido?
		PROFILE=""; PROF_ARGS=(); LIMIT_ARGS=()
		if [ "${1:-}" ] && profile_spec "$1" >/dev/null 2>&1; then
			PROFILE="$1"; shift
			IFS='|' read -r P_CORES P_RAM P_W P_H P_DPI P_BRAND P_MANUF P_CODE P_NAME <<<"$(profile_spec "$PROFILE")"

			# guarda: no pedir más núcleos de los que tiene el host
			HOST_CORES="$(nproc)"
			USE_CORES="$P_CORES"
			if [ "$P_CORES" -gt "$HOST_CORES" ]; then
				echo "AVISO: el perfil pide $P_CORES núcleos pero el host tiene $HOST_CORES; se usan $HOST_CORES." >&2
				USE_CORES="$HOST_CORES"
			fi
			LIMIT_ARGS=( --cpuset-cpus="0-$((USE_CORES-1))" --memory="$P_RAM" --memory-swap="$P_RAM" )
			PROF_ARGS=(
				androidboot.redroid_width="$P_W"
				androidboot.redroid_height="$P_H"
				androidboot.redroid_dpi="$P_DPI"
				ro.product.model="$P_CODE"
				ro.product.brand="$P_BRAND"
				ro.product.manufacturer="$P_MANUF"
			)
		fi

		PORT="$DEFAULT_PORT"
		if [ "${1:-}" ] && printf '%s' "$1" | grep -qE '^[0-9]+$'; then PORT="$1"; shift; fi
		TAG="$(to_tag "$VER")"
		NAME="$(name_of "$VER")"
		DATA="$HOME/${NAME}-data"

		case "$VER" in
			16|16.*) echo "AVISO: Android 16 no arranca en WSL por ahora; se intentará igualmente." >&2 ;;
		esac

		docker rm -f "$NAME" >/dev/null 2>&1 || true
		mkdir -p "$DATA"
		if [ -n "$PROFILE" ]; then
			echo "Lanzando $NAME  (imagen $TAG, perfil $PROFILE = $P_NAME, ${USE_CORES} núcleos, $P_RAM, ${P_W}x${P_H}@${P_DPI}, puerto $PORT)..."
		else
			echo "Lanzando $NAME  (imagen $TAG, puerto $PORT)..."
		fi
		docker run -itd --privileged \
			"${LIMIT_ARGS[@]}" \
			-v "$DATA:/data" \
			-p "${PORT}:5555" \
			--name "$NAME" \
			"$TAG" \
			androidboot.redroid_gpu_mode="$GPU_MODE" \
			androidboot.use_memfd=true \
			"${PROF_ARGS[@]}" \
			"$@" || { echo "fallo al lanzar" >&2; exit 1; }

		printf 'Esperando arranque'
		for _ in $(seq 1 60); do
			if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
				echo; echo "ERROR: el contenedor salió (exit=$(docker inspect -f '{{.State.ExitCode}}' "$NAME" 2>/dev/null)). Revisa 'redroid logs $VER'." >&2
				exit 1
			fi
			if [ "$(docker exec "$NAME" getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
				echo; echo "OK: $NAME arrancado. Conéctate con:  scrcpy -s localhost:${PORT} --no-audio"
				exit 0
			fi
			printf '.'; sleep 2
		done
		echo; echo "AVISO: no completó el arranque en 120s; revisa 'redroid logcat $VER'." >&2
		;;
	start)  require_version "${1:-}"; docker start "$(name_of "$1")" ;;
	stop)   require_version "${1:-}"; docker stop  "$(name_of "$1")" ;;
	rm)     require_version "${1:-}"; docker rm -f "$(name_of "$1")" ;;
	reset)
		require_version "${1:-}"
		N="$(name_of "$1")"; docker rm -f "$N" >/dev/null 2>&1 || true
		# los archivos los crea Android (root/system): hace falta sudo para borrarlos
		if [ "$(id -u)" -eq 0 ]; then rm -rf "$HOME/${N}-data"; else sudo rm -rf "$HOME/${N}-data"; fi \
			&& echo "eliminados contenedor y datos de $N"
		;;
	ls)     docker ps -a --filter 'name=redroid-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' ;;
	profiles) list_profiles ;;
	status) require_version "${1:-}"; echo "boot_completed=[$(docker exec "$(name_of "$1")" getprop sys.boot_completed 2>&1)]" ;;
	logs)   require_version "${1:-}"; docker logs "$(name_of "$1")" ;;
	logcat) require_version "${1:-}"; docker exec "$(name_of "$1")" /system/bin/logcat -d ;;
	port)   require_version "${1:-}"; docker port "$(name_of "$1")" 5555/tcp ;;
	help|-h|--help) usage ;;
	*) echo "comando desconocido: $cmd" >&2; usage; exit 2 ;;
esac
