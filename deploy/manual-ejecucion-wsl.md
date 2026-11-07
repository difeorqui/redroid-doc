# Manual de ejecución — redroid en WSL2 (Windows)

Manual operativo para **correr y gestionar** instancias de redroid en Windows
sobre WSL2. Asume que el entorno ya está instalado (kernel custom con
binderfs/DMA-BUF, Docker, módulos de red, iptables-legacy). Si aún no lo está,
primero sigue la guía de instalación: [wsl.md](wsl.md).

- **Entorno verificado:** Windows 11, WSL 3.0, kernel `6.18.54.1-…-WSL2+`,
  distro `Ubuntu-24.04`, Docker 29.
- **Versiones que arrancan:** Android **8.1 – 15** (modo software). Android 16
  **no** arranca en WSL por ahora (ver [§10](#10-limitaciones-conocidas)).

---

## Atajo: script `redroid`

Para no escribir el `docker run` completo cada vez, hay un helper:
[redroid-wsl.sh](redroid-wsl.sh). Instálalo una vez en la distro:

```bash
sudo install -m 0755 redroid-wsl.sh /usr/local/bin/redroid
```

Y opera con comandos cortos (fuerza siempre el modo compatible con WSL):

```bash
redroid run 13                 # crea y arranca Android 13 en el puerto 5555
redroid run 15 5556            # Android 15 en el puerto 5556
redroid run 13 a06             # Android 13 con specs de un Samsung Galaxy A06 (ver §9)
redroid profiles               # lista los perfiles de dispositivo disponibles
redroid ls                     # lista las instancias redroid
redroid status 13              # boot_completed
redroid stop 13 / start 13     # detener / arrancar
redroid rm 13                  # eliminar contenedor
redroid reset 13               # eliminar contenedor + datos
redroid logcat 13              # logcat de Android
redroid help                   # ayuda completa
```

Admite versiones `8.1 9 10 11 12 13 14 15` y los `_64only` (p.ej.
`redroid run 14_64only`), perfiles de dispositivo por marca/modelo
(ver [§9](#9-perfiles-de-dispositivo-simular-un-celular-real)) y argumentos extra
de arranque: `redroid run 14 5555 androidboot.redroid_width=1080 androidboot.redroid_dpi=420`.

Las secciones siguientes documentan los comandos `docker` equivalentes por si
prefieres el control manual o no instalas el helper.

---

## 1. Verificación rápida del entorno

Entra a la distro desde PowerShell (entras como `root`):

```powershell
wsl -d Ubuntu-24.04
```

Comprueba lo esencial:

```bash
uname -r                               # debe terminar en -WSL2+ (kernel custom)
systemctl is-active docker             # -> active
zcat /proc/config.gz | grep -c ANDROID_BINDER_IPC=y   # -> 1
```

Si `docker` no está activo: `systemctl start docker`.
Si el kernel no termina en `+`, revisa `C:\Users\<TU>\.wslconfig` y ejecuta
`wsl --shutdown` en PowerShell (ver [wsl.md](wsl.md)).

---

## 2. Ejecutar una instancia

La fórmula es siempre la misma; **solo cambia el tag de la imagen**. En WSL son
obligatorios el modo `guest` (render por software) y `use_memfd=true`:

```bash
docker run -itd --privileged \
    -v ~/redroid-<VER>:/data \
    -p 5555:5555 \
    --name redroid-<VER> \
    redroid/redroid:<TAG> \
    androidboot.redroid_gpu_mode=guest \
    androidboot.use_memfd=true
```

| Parámetro | Para qué |
|---|---|
| `-v ~/redroid-<VER>:/data` | Datos persistentes, una carpeta por versión (no se pisan). |
| `-p 5555:5555` | Puerto adb. Cámbialo si corres varias a la vez (ver [§6](#6-varias-instancias-a-la-vez)). |
| `--name redroid-<VER>` | Nombre único de la instancia. |
| `androidboot.redroid_gpu_mode=guest` | Render por software (único que funciona en WSL). |
| `androidboot.use_memfd=true` | Reemplaza `ashmem` (removido del kernel ≥5.18). |

**Ejemplo (Android 13):**

```bash
docker run -itd --privileged -v ~/redroid-13:/data -p 5555:5555 \
    --name redroid-13 redroid/redroid:13.0.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

Espera el arranque (primer boot ~10-60 s) y confirma:

```bash
docker exec redroid-13 getprop sys.boot_completed    # 1 = arrancó del todo
```

### Si sale `Conflict. The container name "/redroid-13" is already in use`

```text
docker: Error response from daemon: Conflict. The container name "/redroid-13"
is already in use by container "7fc0aa...". You have to remove (or rename) that
container to be able to reuse that name.
```

Significa que ya existe un contenedor con ese nombre (en ejecución o detenido
de una corrida anterior). **No hay que volver a hacer `docker run`**; elige una:

| Qué quieres | Comandos |
|---|---|
| Reusar el que ya existe (conserva sus datos) | `docker start redroid-13` (si ya corre, no hace falta nada) |
| Recrearlo con las mismas opciones | `docker rm -f redroid-13` y vuelve a ejecutar el `docker run` |
| Empezar de cero (borra también los datos) | `docker rm -f redroid-13 && sudo rm -rf ~/redroid-13` y luego el `docker run` (ver nota) |

> `sudo` es obligatorio al borrar la carpeta de datos: Android crea esos
> archivos como `root`/`system` dentro del contenedor, y sin `sudo` sale
> `Permission denied`. Si ya ejecutaste el `rm` sin `sudo`, el contenedor ya
> quedó eliminado (el `&&` solo frenó el borrado de la carpeta); repite
> únicamente `sudo rm -rf ~/redroid-13`.
>
> `sudo` pide la contraseña de tu usuario de Ubuntu (al escribirla no se ve
> nada en pantalla). Si no la recuerdas, entra como root desde PowerShell, que no
> la pide (ajusta `<TU>` al nombre de tu usuario de Ubuntu):
>
> ```powershell
> wsl -d Ubuntu-24.04 -u root rm -rf /home/<TU>/redroid-13
> ```

### Recrear la instancia con acceso a la cámara

Una vez eliminado el contenedor, vuelve a crearlo pasándole la webcam. `--device`
solo se puede indicar al crear, por eso va aquí y no después. Orden:

1. **Windows (PowerShell como administrador):** comparte la webcam con WSL
   ([usbipd-win](https://github.com/dorssel/usbipd-win); `bind` solo la primera vez):

   ```powershell
   usbipd list                                         # anota el BUSID de la webcam (ej. 2-3)
   usbipd bind --busid 2-3
   usbipd attach --wsl Ubuntu-24.04 --busid 2-3
   ```

2. **WSL:** carga los módulos y confirma que existe el dispositivo:

   ```bash
   sudo modprobe videodev videobuf2-vmalloc uvcvideo
   ls -l /dev/video*                                   # debe aparecer /dev/video0
   ```

3. **WSL:** crea el contenedor con `--device /dev/video0`:

   ```bash
   docker run -itd --privileged --device /dev/video0 \
       -v ~/redroid-13:/data -p 5555:5555 \
       --name redroid-13 redroid/redroid:13.0.0-latest \
       androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
   ```

4. **Verifica:**

   ```bash
   docker exec redroid-13 ls -l /dev/video0            # el nodo existe dentro del contenedor
   docker exec redroid-13 dumpsys media.camera | head  # "Number of camera devices: N"
   ```

> **Limitación:** este procedimiento solo deja el dispositivo visible dentro del
> contenedor. Las imágenes oficiales no traen el HAL de cámara que lo lee
> (comprobado en Android 15: `Number of camera devices: 0` y la app de cámara se
> cierra). Si el paso 4 muestra 0 cámaras, ver [§13](#13-cámara-webcam-en-una-instancia).
> Tras reiniciar WSL o desconectar la webcam hay que repetir `usbipd attach`.

Para ver el estado de los contenedores existentes: `docker ps -a --filter name=redroid`.
El helper [`redroid-wsl.sh`](redroid-wsl.sh) ya hace el `docker rm -f` por ti antes
de lanzar, así que no produce este error.

---

## 3. Versiones soportadas (funcionan en WSL)

| Android | Tag(s) |
|---|---|
| 8.1 | `redroid/redroid:8.1.0-latest` |
| 9 | `redroid/redroid:9.0.0-latest` |
| 10 | `redroid/redroid:10.0.0-latest` |
| 11 | `redroid/redroid:11.0.0-latest` |
| 12 | `redroid/redroid:12.0.0-latest` · `redroid/redroid:12.0.0_64only-latest` |
| 13 | `redroid/redroid:13.0.0-latest` · `redroid/redroid:13.0.0_64only-latest` |
| 14 | `redroid/redroid:14.0.0-latest` · `redroid/redroid:14.0.0_64only-latest` |
| 15 | `redroid/redroid:15.0.0-latest` · `redroid/redroid:15.0.0_64only-latest` |

### Comando de cada versión

Copia y pega el de la versión que necesites. Todos usan el puerto `5555`, así que **solo uno a la vez**; para varios a la vez cambia el puerto (`-p 5556:5555`, …) como en [§6](#6-varias-instancias-a-la-vez). Cada versión guarda sus datos en su propia carpeta `~/redroid-<VER>`. Las variantes `_64only` van con el sufijo `-64only` en nombre y carpeta.

**Android 8.1**

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-8.1:/data -p 5555:5555 \
    --name redroid-8.1 redroid/redroid:8.1.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

**Android 9**

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-9:/data -p 5555:5555 \
    --name redroid-9 redroid/redroid:9.0.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

**Android 10**

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-10:/data -p 5555:5555 \
    --name redroid-10 redroid/redroid:10.0.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

**Android 11**

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-11:/data -p 5555:5555 \
    --name redroid-11 redroid/redroid:11.0.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

**Android 12**

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-12:/data -p 5555:5555 \
    --name redroid-12 redroid/redroid:12.0.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

Variante solo 64 bits:

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-12-64only:/data -p 5555:5555 \
    --name redroid-12-64only redroid/redroid:12.0.0_64only-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

**Android 13**

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-13:/data -p 5555:5555 \
    --name redroid-13 redroid/redroid:13.0.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

Variante solo 64 bits:

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-13-64only:/data -p 5555:5555 \
    --name redroid-13-64only redroid/redroid:13.0.0_64only-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

**Android 14**

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-14:/data -p 5555:5555 \
    --name redroid-14 redroid/redroid:14.0.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

Variante solo 64 bits:

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-14-64only:/data -p 5555:5555 \
    --name redroid-14-64only redroid/redroid:14.0.0_64only-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

**Android 15**

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-15:/data -p 5555:5555 \
    --name redroid-15 redroid/redroid:15.0.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

Variante solo 64 bits:

```bash
docker run -itd --privileged --device /dev/video0 \
    -v ~/redroid-15-64only:/data -p 5555:5555 \
    --name redroid-15-64only redroid/redroid:15.0.0_64only-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

Para dar acceso a la webcam añade `--device /dev/video0` a cualquiera de ellos (ver [§2](#recrear-la-instancia-con-acceso-a-la-cámara) y su limitación).

> **Android 16** (`16.0.0-latest`, `16.0.0_64only-latest`): **no arranca** en
> WSL por ahora. Ver [§10](#10-limitaciones-conocidas).

---

## 4. Ver y controlar desde Windows

El puerto publicado llega a `localhost` de Windows (reenvío de WSL2). Desde
**PowerShell** (con [scrcpy](https://github.com/Genymobile/scrcpy) instalado,
`winget install Genymobile.scrcpy`, que incluye `adb`):

```powershell
adb connect localhost:5555
adb devices                           # localhost:5555  device
scrcpy -s localhost:5555 --no-audio
```

- `--no-audio` evita un fallo de arranque de scrcpy cuando la imagen no trae
  encoder OPUS (p.ej. Android 11).

---

## 5. Instalar aplicaciones

Las imágenes `redroid/redroid` **no traen Play Store ni Google Play Services**,
así que las apps se instalan por su `.apk` con `adb`. El puerto adb de la
instancia llega a `localhost` de Windows, por lo que lo más cómodo es instalar
desde **PowerShell** (el `adb` viene con scrcpy).

### Desde Windows (recomendado)

```powershell
adb connect localhost:5555
adb devices                                   # localhost:5555  device
adb -s localhost:5555 install C:\ruta\a\tu-app.apk
```

Al terminar imprime `Success` y la app aparece en el cajón de aplicaciones.
Opciones útiles:

| Comando | Para qué |
|---|---|
| `adb -s localhost:5555 install -r app.apk` | Reinstalar conservando los datos (actualizar). |
| `adb -s localhost:5555 install -g app.apk` | Conceder todos los permisos al instalar. |
| `adb -s localhost:5555 install-multiple base.apk split1.apk …` | App con *splits* (extraídos de un `.aab`/`.apks`). |
| `adb -s localhost:5555 uninstall com.paquete.app` | Desinstalar por nombre de paquete. |

Si varias instancias están conectadas, `-s localhost:<puerto>` elige a cuál va.

### Desde WSL (si el APK está en Linux)

redroid no incluye un servidor `adb` dentro del contenedor; copia el APK e
instálalo con `pm`:

```bash
docker cp tu-app.apk redroid-13:/data/local/tmp/app.apk
docker exec redroid-13 pm install -r /data/local/tmp/app.apk
docker exec redroid-13 rm /data/local/tmp/app.apk        # limpiar
```

### Problemas frecuentes

- **`INSTALL_FAILED_NO_MATCHING_ABIS`**: el APK es solo ARM y la imagen es x86_64
  (toda imagen redroid lo es; las `_64only` además descartan apps de 32 bits).
  Usa un APK con ABI x86_64 o una imagen/instancia con traductor ARM.
- **`INSTALL_FAILED_INSUFFICIENT_STORAGE`**: libera espacio o recrea la instancia
  con más datos; revisa `docker exec <name> df -h /data`.
- **`INSTALL_FAILED_OLDER_SDK` / `UPDATE_INCOMPATIBLE`**: el `minSdkVersion` del
  APK es mayor que la versión de Android, o ya hay otra firma del mismo paquete
  (desinstálala primero).

> Para apps que exigen Google Play Services hace falta una imagen con GApps
> (variante aparte de redroid o instalación manual de OpenGApps); no está
> cubierto aquí.

---

## 6. Varias instancias a la vez

Da a cada una **puerto, nombre y carpeta distintos**:

```bash
# Android 11 -> puerto 5555
docker run -itd --privileged -v ~/redroid-11:/data -p 5555:5555 \
    --name redroid-11 redroid/redroid:11.0.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true

# Android 14 -> puerto 5556
docker run -itd --privileged -v ~/redroid-14:/data -p 5556:5555 \
    --name redroid-14 redroid/redroid:14.0.0-latest \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true
```

Conéctate a cada una por su puerto: `scrcpy -s localhost:5555` y
`scrcpy -s localhost:5556`.

---

## 7. Operar las instancias

```bash
docker ps                             # instancias en ejecución
docker stop  redroid-13               # detener (los datos en ~/redroid-13 quedan)
docker start redroid-13               # volver a arrancar reusando sus datos
docker rm -f redroid-13               # eliminar el contenedor
docker logs  redroid-13               # consola de init (motivos de reinicio)
docker exec  redroid-13 /system/bin/logcat -d | tail    # logcat de Android
docker exec  redroid-13 getprop sys.boot_completed       # 1 = arrancado
```

---

## 8. Opciones útiles de arranque

Se añaden como argumentos extra al final del `docker run`:

```bash
    androidboot.redroid_width=1080 \
    androidboot.redroid_height=1920 \
    androidboot.redroid_dpi=420 \
    androidboot.redroid_fps=60
```

Lista completa de parámetros en el [README](../README.md#configuration).

---

## 9. Perfiles de dispositivo (simular un celular real)

Puedes lanzar una instancia con las características de un celular concreto:
número de núcleos, RAM, resolución, densidad y nombre de modelo. Así el emulador
se comporta (y se identifica) como, por ejemplo, un **Samsung Galaxy A06**.

### Qué se puede fijar y con qué fidelidad

| Característica | Cómo se fija | ¿Lo refleja Android? |
|---|---|---|
| **Núcleos** | `--cpuset-cpus="0-N"` (Docker) | ✅ Sí: `nproc` y las apps ven N+1 núcleos. |
| **RAM** | `--memory` / `--memory-swap` (Docker) | ⚠️ Se **limita de verdad** (la instancia no puede pasar de ese tope), pero el total **mostrado** en *Opciones de desarrollador → Memoria* sigue siendo el del host. |
| **Resolución** | `androidboot.redroid_width` / `_height` | ✅ Sí: `wm size` lo refleja. |
| **Densidad (dpi)** | `androidboot.redroid_dpi` | ✅ Sí: `wm density` lo refleja. |
| **Modelo / marca** | `ro.product.model` / `ro.product.brand` / `ro.product.manufacturer` | ✅ Sí: *Ajustes → Acerca del teléfono → Modelo* lo muestra. |

> **Importante sobre la RAM.** El contenedor lee el `/proc/meminfo` real de la VM
> de WSL, por lo que el número *mostrado* no baja al valor del perfil (haría falta
> `lxcfs`, que no está en este montaje). El límite **sí se aplica**: la instancia
> será efectivamente matada (OOM) si supera el tope. Los núcleos y la pantalla, en
> cambio, sí cambian de forma visible.
>
> El perfil tampoco emula el SoC real: un núcleo asignado es un núcleo del host
> (p.ej. tu Intel), no un Cortex-A55. Igualamos **cantidad** de núcleos y RAM,
> no el rendimiento del chip original.

### Con el helper (recomendado)

El script [redroid-wsl.sh](redroid-wsl.sh) trae perfiles listos. La versión de
Android y el perfil de dispositivo son independientes:

```bash
redroid profiles              # lista los perfiles disponibles
redroid run 13 a06            # Android 13 con specs del Galaxy A06
redroid run 15 s24 5556       # Android 15 con specs del Galaxy S24, puerto 5556
```

Perfiles incluidos (specs de GSMArena, variante más común):

| Perfil | Modelo | Núcleos | RAM | Pantalla | DPI |
|---|---|---|---|---|---|
| `a06` | Samsung Galaxy A06 | 8 | 4 GB | 720×1600 | 262 |
| `a15` | Samsung Galaxy A15 | 8 | 4 GB | 1080×2340 | 396 |
| `a55` | Samsung Galaxy A55 | 8 | 8 GB | 1080×2340 | 390 |
| `s24` | Samsung Galaxy S24 | 10 | 8 GB | 1080×2340 | 416 |
| `redmia3` | Xiaomi Redmi A3 | 8 | 4 GB | 720×1650 | 268 |
| `redminote13` | Xiaomi Redmi Note 13 | 8 | 6 GB | 1080×2400 | 395 |
| `xiaomi14` | Xiaomi 14 | 8 | 12 GB | 1200×2670 | 460 |
| `motog24` | Motorola Moto G24 | 8 | 4 GB | 720×1612 | 269 |
| `edge50` | Motorola Edge 50 | 8 | 8 GB | 1220×2712 | 446 |
| `realmec55` | Realme C55 | 8 | 6 GB | 1080×2400 | 392 |
| `oppoa58` | Oppo A58 | 8 | 6 GB | 1080×2400 | 392 |
| `pixel8` | Google Pixel 8 | 9 | 8 GB | 1080×2400 | 428 |
| `oneplus12` | OnePlus 12 | 8 | 12 GB | 1440×3168 | 510 |
| `tecnospark20` | Tecno Spark 20 | 8 | 8 GB | 720×1612 | 267 |
| `infinixhot40` | Infinix Hot 40 | 8 | 8 GB | 1080×2460 | 396 |

> La mayoría de celulares Android son **octa-core (8)**; por eso casi todos los
> perfiles coinciden en núcleos y lo que más varía es RAM y pantalla. El Galaxy
> S24 (Exynos 2400) es deca-core (10) y el Pixel 8 (Tensor G3) tiene 9. Si el host
> tiene menos núcleos que el perfil, el helper ajusta al máximo disponible.

### Manualmente (sin el helper)

El mismo A06 con `docker run` directo:

```bash
docker run -itd --privileged \
    --cpuset-cpus="0-7" \
    --memory=4g --memory-swap=4g \
    -v ~/redroid-13:/data -p 5555:5555 --name redroid-13 \
    redroid/redroid:13.0.0-latest \
    androidboot.redroid_gpu_mode=guest \
    androidboot.use_memfd=true \
    androidboot.redroid_width=720 \
    androidboot.redroid_height=1600 \
    androidboot.redroid_dpi=262 \
    ro.product.model=SM-A065M \
    ro.product.brand=samsung \
    ro.product.manufacturer=samsung
```

Comprueba que se aplicó:

```bash
docker exec redroid-13 getprop ro.product.model     # SM-A065M
docker exec redroid-13 nproc                         # 8
docker exec redroid-13 wm size                       # Physical size: 720x1600
docker exec redroid-13 wm density                    # Physical density: 262
```

### Un dispositivo a medida

Para valores propios, usa `--cpuset-cpus`/`--memory` y los `androidboot.redroid_*`
con los números que quieras (p.ej. 2 núcleos y 2 GB: `--cpuset-cpus="0-1"
--memory=2g --memory-swap=2g`). O añade tu propio perfil al `case` de
`profile_spec()` en [redroid-wsl.sh](redroid-wsl.sh).

---

## 10. Limitaciones conocidas

- **Android 16 no arranca en WSL.** Dos bloqueos: SurfaceFlinger aborta al
  precargar shaders (`output buffer not gpu writeable`) y
  `ApplicationSharedMemory` exige `/dev/ashmem`, inexistente en kernels ≥5.18 y
  no cubierto por `use_memfd`. Detalle técnico en [wsl.md](wsl.md).
- **Modo `host`/GPU no es viable en WSL.** El nodo DRM lo expone `dxgkrnl` con
  un driver glibc (`d3d12`) que Android (bionic) no puede usar. Siempre
  `redroid_gpu_mode=guest`.
- El rendimiento gráfico es por software; suficiente para automatización/pruebas,
  no para juegos exigentes.
- **La cámara no existe por defecto.** WSL2 no ve la webcam de Windows y el
  contenedor no recibe ningún `/dev/video*`, y las imágenes oficiales no traen HAL de cámara V4L2. Ver [§13](#13-cámara-webcam-en-una-instancia).

---

## 11. Después de reiniciar Windows o WSL

El entorno base (kernel, Docker, módulos de red, iptables-legacy) **persiste**.
Los contenedores **no** se auto-levantan salvo que tengan política de reinicio.
Para retomar:

```powershell
wsl -d Ubuntu-24.04 -u root docker start redroid-15     # o la instancia que uses
```

> Para que una instancia se levante sola tras reiniciar, créala con
> `--restart unless-stopped` en lugar de confiar en `docker start` manual.

---

## 12. Solución de problemas

| Síntoma | Acción |
|---|---|
| El contenedor arranca y muere / se reinicia en ~1 min | Suele ser SurfaceFlinger; usa Android ≤15 y `redroid_gpu_mode=guest`. Revisa `docker exec <name> /system/bin/logcat -d -b crash`. |
| `boot_completed` queda vacío mucho tiempo | Revisa `logcat` por errores; en GPU software el primer boot puede tardar. |
| adb no conecta desde Windows | Confirma el puerto (`docker ps`), reintenta `adb connect localhost:<puerto>`; prueba la IP con `wsl hostname -I`. |
| `scrcpy -s localhost:5555` termina con `Device disconnected` y el dispositivo aparece como `sdk_gphone64_x86_64` | Estás conectado al emulador de Android Studio, que ocupa el puerto 5555 de Windows, no a redroid. Ciérralo o publica redroid en otro puerto (ver nota de [§14](#14-alternativa-emulador-de-android-studio-con-webcam)). Mientras tanto, conéctate por la IP de WSL: `adb connect $(wsl hostname -I)` (primera IP) con puerto `:5555`. |
| Docker no arranca tras actualizar | `systemctl status docker`; revisa que los módulos netfilter estén cargados (`/etc/modules-load.d/`) y iptables en modo legacy. |
| `Conflict. The container name "/redroid-<VER>" is already in use` | Ya existe un contenedor con ese nombre. `docker start redroid-<VER>` para reusarlo, o `docker rm -f redroid-<VER>` y relanza (ver [§2](#si-sale-conflict-the-container-name-redroid-13-is-already-in-use)). |
| Quiero empezar una versión de cero | `docker rm -f <name>` y `sudo rm -rf ~/redroid-<VER>` (con `sudo`, si no da `Permission denied`) antes de relanzar. |
| La cámara se abre y se cierra / `Number of camera devices: 0` | La imagen no trae HAL de cámara V4L2; ver [§13](#13-cámara-webcam-en-una-instancia). |

---

## 13. Cámara (webcam) en una instancia

**Las imágenes oficiales `redroid/redroid` no traen un HAL de cámara que lea
V4L2, así que una webcam no se puede usar solo con configuración.** Pasar
`--device /dev/video0` (y compartir la webcam con `usbipd`) deja el nodo visible
dentro del contenedor, pero Android no lo lee.

Síntoma (verificado en `redroid-15`, Android 15): la app de cámara se abre y se
cierra al instante.

```bash
docker exec redroid-15 dumpsys media.camera | head   # Number of camera devices: 0
docker exec redroid-15 /system/bin/logcat -d | grep -E "No (back|front)-facing|AndroidRuntime"
# W CAM_Camera2OneCamMgr: No back-facing camera found.
# E AndroidRuntime: ArrayIndexOutOfBoundsException ... AndroidCameraAgentImpl.getCharacteristics
```

Causa: `cameraserver` corre y `pm list features` muestra
`android.hardware.camera`, pero no hay ningún proveedor de cámara en ejecución.
La única pieza de cámara en la imagen es `/system/bin/virtual_camera` (HAL
virtual de AOSP, servicio `disabled`), que no es un puente a V4L2.

**Qué sí se puede hacer**

- **Si solo necesitas que la app no se cierre** (pruebas de flujo que no usan la
  imagen de la cámara): usa una app de cámara que tolere no tener cámaras, o
  evita el flujo que abre la cámara.
- **Si necesitas imagen de una webcam real, la vía práctica es el emulador
  de Android Studio, que sí soporta webcam: ver [§14](#14-alternativa-emulador-de-android-studio-con-webcam).**
- **Si aun así debe ser redroid:** hay que construir una imagen
  propia de redroid que incluya el HAL de cámara *external* de AOSP
  (`android.hardware.camera.provider@2.4-external-service`, con su `.rc` y entrada
  en el manifiesto VINTF) y pasarle `--device /dev/video0`. Es un cambio de
  compilación de la imagen, no de ejecución; queda fuera de este manual.
  En WSL además hay que llevar la webcam hasta `/dev/video0` con
  [usbipd-win](https://github.com/dorssel/usbipd-win) (el kernel ya trae
  `uvcvideo` y `vhci-hcd`).

> Comprueba primero qué falta: `ls /dev/video*` en WSL (¿llegó la webcam?),
> `docker inspect <name> --format '{{json .HostConfig.Devices}}'` (¿se pasó
> el dispositivo?) y `dumpsys media.camera` dentro de Android (¿cuántas
> cámaras ve?). Si el último dice 0 con `/dev/video0` presente, es la limitación
> de la imagen descrita arriba.

---

## 14. Alternativa: emulador de Android Studio con webcam

Cuando una prueba necesita **imagen real de la cámara** (QR, foto, videollamada),
usa el emulador oficial de Android en Windows, que sí tiene puente a la webcam.
redroid sigue siendo la opción para automatización sin cámara; no se mezclan.

> No usa WSL ni Docker, así que **no compite** con redroid. El emulador usa un par
> de puertos propio (consola `5554`, adb `5555`, serial `emulator-5554`) y, si
> están ocupados —por ejemplo por redroid en `localhost:5555`—, toma el siguiente
> par libre (`emulator-5556`). Comprueba el serial real con `adb devices` antes de
> usar `-s`.
>
> **Ojo con `localhost:5555`:** si el emulador de Android Studio está abierto,
> ocupa ese puerto en Windows. `adb connect localhost:5555` / `scrcpy -s
> localhost:5555` se conectan **al emulador, no a redroid** (en `adb devices` sale
> como `sdk_gphone64_x86_64` en vez de `redroid15_x86_64`). Para no mezclarlos,
> publica redroid en otro puerto (`-p 5556:5555`, y conéctate a `localhost:5556`)
> o cierra el emulador antes de usar redroid.

**1. Libera la webcam de WSL.** Mientras esté "attached" a WSL, Windows no la ve
(PowerShell como administrador):

```powershell
usbipd list
usbipd detach --busid <BUSID>        # el mismo BUSID que usaste en el attach
```

**2. Instala el emulador** (una sola vez). Requiere virtualización activa
(`HypervisorPresent = True`, ya lo cumple el entorno verificado):

```powershell
winget install Google.AndroidStudio
```

Abre Android Studio → *More Actions → SDK Manager* y, en *SDK Platforms*,
despliega *Android 15.0 ("VanillaIceCream")* (marca *Show Package Details*) e
instala:

- *Android SDK Platform 35* (= Android 15).
- **Una** imagen del sistema de API 35: *Google Play Intel x86_64 Atom System
  Image* (con Play Store) o *Google APIs Intel x86_64 Atom System Image* (sin
  Play Store). La webcam funciona igual con ambas.

**No elijas** las variantes *16 KB Page Size …*: son para probar compatibilidad
con páginas de memoria de 16 KB, no son el Android 15 normal y pueden fallar con
apps cuyas librerías nativas no estén alineadas a 16 KB. *Sources for Android 35*
y las imágenes *Tablet*, *AOSP ATD* o sin sufijo no hacen falta.

En la pestaña *SDK Tools* comprueba:

- *Android Emulator*: obligatorio.
- *Android SDK Command-line Tools (latest)*: solo si vas a crear el dispositivo
  con `avdmanager` por consola (paso 3).

**3. Crea el dispositivo con la webcam.** En *Device Manager → Create Device*,
elige la imagen API 35 que instalaste, ponle de nombre `cam15` y, en
*Show Advanced Settings → Camera*, pon **Front** y **Back** en `Webcam0`.
Luego arráncalo desde PowerShell (`emulator` no está en el `PATH`, usa la ruta
completa):

```powershell
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
& "$sdk\emulator\emulator.exe" -webcam-list           # debe listar la webcam (webcam0)
& "$sdk\emulator\emulator.exe" -avd cam15 -camera-back webcam0 -camera-front webcam0
```

Los flags `-camera-back`/`-camera-front` fuerzan la webcam aunque el dispositivo
no la tenga configurada.

Alternativa por consola (requiere *Command-line Tools*). El identificador debe
coincidir con la imagen instalada: `google_apis_playstore` si elegiste *Google
Play*, `google_apis` si elegiste *Google APIs*:

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"   # Java incluido en Android Studio
& "$sdk\cmdline-tools\latest\bin\avdmanager.bat" create avd -n cam15 `
    -k "system-images;android-35;google_apis_playstore;x86_64" -d medium_phone
```

Si sale `ERROR: JAVA_HOME is not set and no 'java' command could be found`,
`avdmanager` no encuentra Java: la línea de `JAVA_HOME` de arriba lo resuelve
(solo para esa ventana de PowerShell). Este método deja la cámara trasera en
`emulated` y la frontal en `none`: edita `%USERPROFILE%\.android\avd\cam15.avd\config.ini`
y pon `hw.camera.back=webcam0` y `hw.camera.front=webcam0` (o usa siempre los
flags `-camera-*` al arrancar).

**4. Verifica** (con `adb` del SDK o el de scrcpy):

```powershell
adb -s emulator-5554 shell dumpsys media.camera | Select-String "Number of camera devices"
```

Debe decir 1 o más (en redroid decía 0). Abre la app *Cámara* y debe mostrar la webcam.
La primera vez la app muestra un asistente ("Remember photo locations?") y pide
permiso de ubicación, que no hace falta (puedes pulsar *Don't allow*); la vista
previa aparece al terminarlo. Comprueba que miras la ventana del **emulador** y
no la de scrcpy de redroid: en `adb devices` el emulador es `emulator-5554`
(`sdk_gphone64_x86_64`) y redroid es `redroid15_x86_64`.

> Para volver a usar la webcam en WSL: `usbipd attach --wsl Ubuntu-24.04 --busid <BUSID>`.
> Si `-webcam-list` sale vacío, cierra las apps de Windows que usan la cámara
> (Teams, Zoom, la app Cámara) y comprueba que el paso 1 se hizo.
> Verificado en esta máquina: dispositivo `cam15` (Android 15, imagen
> `google_apis_playstore`) arrancado con `-camera-back webcam0 -camera-front webcam0`;
> `dumpsys media.camera` informa `Number of camera devices: 1` (cámara trasera
> mapeada a la webcam). Si `adb devices` muestra `emulator-5554 unauthorized`,
> ejecuta `adb kill-server` y `adb start-server`.
