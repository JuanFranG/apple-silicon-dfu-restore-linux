# Restaurar un Mac con Apple silicon desde Linux (DFU + idevicerestore)

[English](README.md) | **Español**

Guía y scripts para resolver el error **"Failed to personalize the software update"** de macOS cuando la causa es la falta de la partición de recuperación del sistema (**error 1256: `Failed to find SFR recovery volume`**). La solución es restaurar el Mac en **modo DFU** desde un PC con **Linux**, usando [idevicerestore](https://github.com/libimobiledevice/idevicerestore), **sin necesitar un segundo Mac**.

> [!WARNING]
> **La restauración con `-e` borra todo el contenido del Mac.** Haz un respaldo (Time Machine u otro) antes de empezar si tienes datos que quieras conservar.
> Este método **no es oficial ni está soportado por Apple**. Este proyecto no está afiliado con Apple ni con libimobiledevice. Úsalo bajo tu propio riesgo.

---

## Contenido

- [El problema](#el-problema)
- [Diagnóstico](#diagnóstico)
- [Opciones de solución](#opciones-de-solución)
- [Requisitos](#requisitos)
- [Paso a paso](#paso-a-paso)
- [Solución de problemas](#solución-de-problemas)
- [Probado en](#probado-en)
- [Créditos](#créditos)
- [Licencia](#licencia)

---

## El problema

Al intentar actualizar macOS desde *Ajustes del Sistema → Actualización de software* (o con `softwareupdate`), aparece:

> **Failed to personalize the software update. Please try again.**
> An error occurred while downloading the selected updates. Please check your internet connection and try again.

El mensaje sugiere un problema de internet, pero **no lo es**. Cambiar de red, reiniciar, usar el modo seguro o actualizar desde Terminal no lo resuelve.

El error real aparece en `/var/log/install.log`:

```
Failed to perform PreflightPersonalize operation: [MobileSoftwareUpdateErrorDomain(MSU):1256]
... SUMacControllerErrorIndicationsMask=0 ...
Error Domain=MobileSoftwareUpdateErrorDomain Code=1256 "Failed to find SFR recovery volume"
```

### La causa

En un Mac con Apple silicon, la última partición del disco interno debe ser **`Apple_APFS_Recovery`**, que contiene la recuperación del sistema. Según la [documentación de Asahi Linux](https://asahilinux.org/docs/sw/partitioning-cheatsheet/), **si esa partición falta, las actualizaciones de macOS dejan de funcionar**.

Así se veía el disco afectado (`diskutil list`). Solo tiene dos particiones:

```
/dev/disk0 (internal, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *1.0 TB     disk0
   1:             Apple_APFS_ISC Container disk1         524.3 MB   disk0s1
   2:                 Apple_APFS Container disk2         1.0 TB     disk0s2
```

En un disco sano debería aparecer además una tercera partición, del orden de 5 GB:

```
   3:        Apple_APFS_Recovery Container ...            5.3 GB     disk0s3
```

---

## Diagnóstico

Antes de restaurar, **confirma que este es tu problema**. El script [`scripts/diagnostico-actualizacion.sh`](scripts/diagnostico-actualizacion.sh) **solo lee información, no cambia nada**. Revisa:

- Reloj, `/etc/hosts`, proxy, VPN y filtros de red, firewall.
- Conexión a los servidores de actualización de Apple.
- **Si existe la partición `Apple_APFS_Recovery`.**
- Las carpetas de identidad de arranque (`iSCPreboot`).
- El último error de personalización en `install.log`, con su interpretación.

En el Mac, abre Terminal y ejecuta:

```bash
sudo bash ~/Downloads/diagnostico-actualizacion.sh > ~/Desktop/diagnostico.txt 2>&1
```

Abre `diagnostico.txt` en el Escritorio. **Este método aplica si el resultado indica el error 1256 y que falta `Apple_APFS_Recovery`.** Si el error es otro, por ejemplo `kAMAuthInstallErrorServerNotReachable`, el problema sí es de red y esta guía no aplica.

---

## Opciones de solución

| Opción | ¿Borra datos? | Dificultad | Notas |
|---|---|---|---|
| **Proveedor de servicio autorizado de Apple** | Normalmente sí | Baja | Método oficial, con las herramientas de Apple. |
| **Recrear la partición a mano + revive** | No (en teoría) | Alta | [Guía de Arbifox en r/AsahiLinux](https://www.reddit.com/r/AsahiLinux/comments/1fmnzm5/guide_how_to_fix_failed_to_find_sfr_recovery/). Requiere desactivar SIP, `gdisk` y cálculos exactos de particiones. |
| **Restauración DFU desde Linux** (esta guía) | **Sí, todo** | Media | Funciona sin otro Mac. |

---

## Requisitos

- **Un Mac con Apple silicon.** Probado en un MacBook Air (M1, 2020).
- **Un PC con Linux.** Probado en Linux Mint 22.3 Cinnamon; el script de preparación también se validó en Ubuntu 24.04, que es la base de toda la serie Linux Mint 22. Usa `apt`, así que debería funcionar en otras distribuciones basadas en Ubuntu 24.04, aunque no se probó en ellas.
- **Un cable USB-C que transmita datos.** Apple pide un cable USB-C a USB-C de datos y carga, y [no admite cables Thunderbolt 3](https://support.apple.com/en-us/108900). Los cables que solo cargan no sirven.
- **Espacio libre en el PC Linux.** Los firmwares de macOS pesan unos 20–27 GB. Deja al menos 40 GB libres.
- **Conexión a internet** en el PC Linux.
- **La contraseña de la cuenta de Apple** del Mac, por si el Bloqueo de Activación la pide después de restaurar.
- **El Mac conectado al cargador** durante todo el proceso.

---

## Paso a paso

### 1. Preparar Linux (compilar idevicerestore)

El script [`scripts/preparar-mint-idevicerestore.sh`](scripts/preparar-mint-idevicerestore.sh) hace lo siguiente:

1. Instala las herramientas de compilación con `apt`.
2. Descarga desde los **repositorios oficiales de libimobiledevice en GitHub** y compila, en este orden: `libplist`, `libimobiledevice-glue`, `libusbmuxd`, `libtatsu`, `libimobiledevice`, `libirecovery`, `usbmuxd` e `idevicerestore`. Todo se instala en `/usr/local`.
3. Crea el usuario de sistema `usbmux`, que el servicio `usbmuxd` necesita para arrancar, y recarga `udev` y `systemd`.

```bash
cd ~/Descargas            # o ~/Downloads
bash preparar-mint-idevicerestore.sh
```

Te pedirá tu contraseña y tarda varios minutos. Al terminar, **reinicia el PC** y verifica:

```bash
idevicerestore --version     # → idevicerestore 1.0.0-git-... (libirecovery ..., libtatsu ...)
which irecovery usbmuxd      # → rutas en /usr/local/...
id usbmux                    # → uid=...(usbmux)
```

### 2. Descargar y verificar el firmware (IPSW)

Crea una carpeta de trabajo:

```bash
mkdir -p "$(xdg-user-dir DESKTOP)/restaurar-mac" && cd "$(xdg-user-dir DESKTOP)/restaurar-mac"
```

Busca tu modelo en [ipsw.me](https://ipsw.me) para ver las versiones de macOS firmadas, sus enlaces oficiales (`updates.cdn-apple.com`) y sus sumas SHA-256. También puedes consultar su API, por ejemplo para el MacBook Air M1: `https://api.ipsw.me/v4/device/MacBookAir10,1?type=ipsw`.

Ejemplo con **macOS 26.6.2 (25G83)** para MacBook Air M1:

```bash
wget -c https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw
sha256sum UniversalMac_26.6.2_25G83_Restore.ipsw
# Debe ser exactamente:
# 885503b7f4b06609e9a512f2befd40f59730640a3f1233e3892d60affdd51c95
```

- `-c` permite reanudar la descarga si se corta.
- **Si el SHA-256 no coincide, no sigas.** Borra el archivo y descárgalo de nuevo.

> Alternativa: `idevicerestore -l` muestra las versiones firmadas y descarga la que elijas. La descarga manual tiene dos ventajas: se puede verificar el archivo y el Mac no tiene que esperar en DFU mientras se descarga.

### 3. Conectar los equipos

1. **Apaga el Mac.**
2. Conecta el cable al **puerto DFU** del Mac. Según [Apple (120694)](https://support.apple.com/en-us/120694):
   - **MacBook Air presentados en 2025 o después:** el USB-C **más a la derecha** mirando el costado izquierdo.
   - **Otros modelos portátiles** (incluido el MacBook Air M1): el USB-C **más a la izquierda** mirando el costado izquierdo, o sea, el más cercano a la bisagra.
   - Mac mini, Mac Studio y otros: consulta el artículo de Apple.
3. Conecta el otro extremo **directo** al PC Linux, sin hub. Mejor en un puerto trasero.
4. Conecta el Mac al cargador por el otro puerto.

### 4. Poner el Mac en modo DFU (portátiles Apple silicon)

Pasos según la [guía de Apple](https://support.apple.com/guide/apple-configurator-mac/revive-or-restore-a-mac-with-apple-silicon-apdd5f3c75ad/mac):

1. Presiona y **suelta** el botón de encendido (Touch ID).
2. Presiona el botón de encendido otra vez y, **sin soltarlo**, mantén al mismo tiempo **Control izquierdo + Option izquierdo + Shift derecho** durante unos **10 segundos**.
3. Suelta las tres teclas, pero **sigue presionando el botón de encendido**.
4. La pantalla del Mac debe quedar **negra**. Si aparece el logo de Apple, arrancó normal: apágalo y repite.

En un teclado en inglés, **control** (⌃) y **option** (⌥) son la 2.ª y 3.ª tecla de la fila inferior izquierda. **shift** derecho (⇧) está sobre las flechas.

**Para saber cuándo soltar**, deja corriendo esto en Linux y mantén el botón presionado hasta que aparezca el dispositivo en modo DFU:

```bash
sudo dmesg -wH
```

```
usb 1-12: New USB device found, idVendor=05ac, idProduct=1227
usb 1-12: Product: Apple Mobile Device (DFU Mode)
usb 1-12: Manufacturer: Apple Inc.
```

### 5. Verificar la detección

```bash
sudo irecovery -q
```

Salida esperada (MacBook Air M1; identificadores omitidos):

```
CPID: 0x8103
BDID: 0x26
ECID: 0x................
MODE: DFU
PRODUCT: MacBookAir10,1
MODEL: j313ap
NAME: MacBook Air (M1, 2020)
```

Lo importante es que diga **`MODE: DFU`** y que `NAME` corresponda a tu Mac.

### 6. Restaurar

```bash
sudo idevicerestore -e --logfile=restauracion.log UniversalMac_26.6.2_25G83_Restore.ipsw
```

- `-e` hace una restauración completa: **borra todo** e instala macOS limpio.
- Si te pide confirmar, escribe lo que indique la pantalla.
- En el Mac aparecen el logo de Apple y una barra de progreso, y puede reiniciarse varias veces.
- **No desconectes ni apagues ninguno de los dos equipos** hasta que la terminal indique que terminó.

### 7. Después de restaurar

1. Configura el Mac con el asistente e inicia sesión con tu cuenta de Apple si la pide.
2. Si tienes respaldo, usa el **Asistente de Migración** para recuperar tus datos.
3. Confirma que la partición de recuperación existe:
   ```bash
   diskutil list | grep Apple_APFS_Recovery
   ```
4. Prueba *Actualización de software*.

Al terminar, puedes borrar la carpeta de trabajo de Linux. Los archivos quedaron a nombre del administrador, por eso se usa `sudo`:

```bash
sudo rm -r "$(xdg-user-dir DESKTOP)/restaurar-mac"
```

---

## Solución de problemas

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `irecovery -q` → `ERROR: Unable to connect to device` | El Mac todavía no está en DFU | Observa `sudo dmesg -wH` mientras haces la secuencia. Ejecuta `irecovery` solo cuando aparezca `DFU Mode`. |
| `dmesg` no muestra ningún dispositivo Apple | Cable que solo carga, puerto equivocado del Mac o hub USB | Usa un cable de datos, el puerto DFU correcto y un puerto directo del PC. |
| `dmesg` muestra `Recovery Mode` en lugar de `DFU Mode` | Entró a recuperación, no a DFU | Repite la secuencia cuidando los tiempos. |
| El servicio `usbmuxd` no arranca | Falta el usuario `usbmux` | Vuelve a ejecutar el script de preparación, que lo crea. |
| Mensajes `ucsi_handle_connector_change ... hogged CPU` en `dmesg` | Ruido del controlador USB-C del PC | No afectan, ignóralos. |
| El SHA-256 no coincide | Descarga incompleta o corrupta | Borra el `.ipsw` y descárgalo de nuevo. |

Ante cualquier error de `idevicerestore`, **no repitas a ciegas**. Revisa `restauracion.log`. Apple silicon no se puede inutilizar de forma permanente ([Asahi Linux](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)): siempre se puede volver a entrar en DFU y reintentar.

---

## Probado en

| | |
|---|---|
| **Mac** | MacBook Air (M1, 2020), `MacBookAir10,1`, `j313ap` |
| **macOS antes** | 26.5.1 (25F80), con error 1256 y sin `Apple_APFS_Recovery` |
| **macOS restaurado** | 26.6.2 (25G83) |
| **PC Linux** | Linux Mint 22.3 "Zena" Cinnamon (base Ubuntu 24.04 LTS) |
| **idevicerestore** | `1.0.0-git-4b3e847` (libirecovery 1.3.1, libtatsu 1.0.5) |
| **Fecha** | 15 de octubre de 2026 |

El script de preparación descarga la versión más reciente de cada repositorio. Si algo cambia en el futuro, el commit probado de idevicerestore es `4b3e847`.

---

## Créditos

Este proyecto **no incluye ni modifica** código de terceros. El script de preparación descarga y compila el software original desde sus repositorios oficiales. Todo el mérito técnico de la restauración es de sus autores.

### idevicerestore y libimobiledevice

- **[idevicerestore](https://github.com/libimobiledevice/idevicerestore)**, de **Joshua Hill**, **Martin Szulecki** y **Nikias Bassen** (proyecto [libimobiledevice](https://libimobiledevice.org)). Licencia **LGPL-3.0**.
- **[libirecovery](https://github.com/libimobiledevice/libirecovery)**, **[libtatsu](https://github.com/libimobiledevice/libtatsu)**, **[libimobiledevice](https://github.com/libimobiledevice/libimobiledevice)**, **[libplist](https://github.com/libimobiledevice/libplist)**, **[libusbmuxd](https://github.com/libimobiledevice/libusbmuxd)**, **[libimobiledevice-glue](https://github.com/libimobiledevice/libimobiledevice-glue)** y **[usbmuxd](https://github.com/libimobiledevice/usbmuxd)**, del proyecto libimobiledevice. Licencias LGPL o GPL; consulta cada repositorio.

### Diagnóstico y documentación

- **[Asahi Linux](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)**: documentación sobre la partición `Apple_APFS_Recovery` y sobre restaurar por DFU desde Linux.
- **Arbifox** y **u/DarthSilicrypt**: [guía para el error "Failed to find SFR recovery volume"](https://www.reddit.com/r/AsahiLinux/comments/1fmnzm5/guide_how_to_fix_failed_to_find_sfr_recovery/), que permitió identificar la causa.
- **Howard Oakley ([The Eclectic Light Company](https://eclecticlight.co))**: explicaciones sobre la recuperación en Mac con Apple silicon.
- **[ipsw.me](https://ipsw.me)**: índice de firmwares firmados y sumas de verificación.
- **Apple**: documentación oficial sobre el [puerto DFU](https://support.apple.com/en-us/120694), el [modo DFU y revive/restore](https://support.apple.com/guide/apple-configurator-mac/revive-or-restore-a-mac-with-apple-silicon-apdd5f3c75ad/mac) y los [servidores de actualización](https://support.apple.com/en-us/101555).

### Este repositorio

Diagnóstico, scripts, pruebas y documentación: **Juan Francisco González** ([@JuanFranG](https://github.com/JuanFranG)), con asistencia de Claude (Anthropic).

---

## Licencia

Los scripts y la documentación de este repositorio se publican bajo licencia [MIT](LICENSE).

idevicerestore y las bibliotecas de libimobiledevice **no forman parte de este repositorio** y conservan sus propias licencias (LGPL / GPL). El firmware de macOS (`.ipsw`) pertenece a Apple y **no se incluye ni se redistribuye** aquí: se descarga directamente de los servidores de Apple.
