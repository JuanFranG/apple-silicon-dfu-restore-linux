#!/bin/bash
# Diagnóstico de "Failed to personalize the software update" en macOS (Apple silicon)
# Solo LEE información: no cambia ninguna configuración del Mac.
# Uso:  sudo bash diagnostico-actualizacion.sh > ~/Desktop/diagnostico.txt 2>&1

CURL=/usr/bin/curl   # el de macOS, no el de Anaconda/Homebrew
HOSTS="gs.apple.com ig.apple.com mesu.apple.com gdmf.apple.com gdmf-ados.apple.com updates.cdn-apple.com captive.apple.com"
UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
PATRON="PreflightPersonalize|kAMAuthInstall|MSU_ERR|PersonalizationError|Code=1256|Code=1259|GLOBAL_TICKET|SFR recovery|firmware identity|device identity|SFR installer"

titulo() { printf "\n==================== %s ====================\n" "$1"; }

titulo "1. Sistema"
sw_vers
echo "Arquitectura: $(uname -m)"
df -h / | tail -1 | awk '{print "Espacio libre en disco de arranque: "$4}'

titulo "2. Reloj (comparado con el servidor de Apple)"
srv=$($CURL -sI --max-time 10 https://www.apple.com | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
if [ -n "$srv" ]; then
  srv_epoch=$(LC_ALL=C date -j -u -f "%a, %d %b %Y %H:%M:%S GMT" "$srv" +%s 2>/dev/null)
  loc_epoch=$(date -u +%s)
  if [ -n "$srv_epoch" ]; then
    diff=$(( loc_epoch - srv_epoch )); [ $diff -lt 0 ] && diff=$(( -diff ))
    echo "Hora servidor: $srv | Diferencia: ${diff}s"
    [ $diff -gt 120 ] && echo "AVISO: el reloj está desfasado más de 2 minutos."
  else
    echo "No se pudo interpretar la hora del servidor: $srv"
  fi
else
  echo "No se pudo obtener la hora de www.apple.com (¿sin conexión?)"
fi

titulo "3. Archivo /etc/hosts (entradas que mencionan apple)"
grep -in "apple" /etc/hosts || echo "OK: ninguna entrada de Apple en /etc/hosts"

titulo "4. Proxy configurado"
scutil --proxy | grep -E "Enable|Proxy|Port" || echo "Sin proxy"

titulo "5. VPN y extensiones de red / filtros de contenido"
scutil --nc list 2>/dev/null
systemextensionsctl list 2>/dev/null | grep -iE "network|filter|firewall|vpn|activated" || echo "Sin extensiones de red detectadas"

titulo "6. Firewall integrado de macOS"
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null
/usr/libexec/ApplicationFirewall/socketfilterfw --getblockall 2>/dev/null

titulo "7. Conexión a los servidores de actualización de Apple"
for h in $HOSTS; do
  ip=$(dscacheutil -q host -a name "$h" 2>/dev/null | awk '/ip_address/{print $2; exit}')
  [ -z "$ip" ] && ip="NO RESUELVE"
  out=$($CURL -sv --max-time 15 -o /dev/null -w "HTTP=%{http_code}" "https://$h/" 2>&1)
  code=$(echo "$out" | grep -o "HTTP=[0-9]*" | tail -1)
  issuer=$(echo "$out" | grep -i "issuer:" | head -1 | sed 's/.*issuer: *//')
  err=$(echo "$out" | grep -iE "Could not resolve|Failed to connect|timed out|SSL certificate problem|SSL_ERROR|certificate verify failed" | head -1)
  printf "%-24s IP=%-16s %s\n" "$h" "$ip" "$code"
  [ -n "$issuer" ] && printf "%-24s Certificado emitido por: %s\n" "" "$issuer"
  [ -n "$err" ] && printf "%-24s ERROR: %s\n" "" "$err"
done
echo "(HTTP=000 = no hubo conexión. Cualquier otro código, incluso 403/404, significa que el servidor respondió."
echo " Un emisor de certificado que no sea Apple puede indicar que la red intercepta el tráfico.)"

titulo "8. Partición de recuperación del sistema (Apple_APFS_Recovery)"
diskutil list internal physical 2>/dev/null || diskutil list disk0
if diskutil list 2>/dev/null | grep -q "Apple_APFS_Recovery"; then
  echo "-> OK: existe la partición Apple_APFS_Recovery."
  sfr_ok=1
else
  echo "-> FALTA la partición Apple_APFS_Recovery (recuperación del sistema)."
  echo "   Sin ella, las actualizaciones de macOS fallan con el error 1256 'Failed to find SFR recovery volume'."
  sfr_ok=0
fi

titulo "9. Identidad de arranque (iSCPreboot vs. grupos de volúmenes)"
activo=$(diskutil info / | awk -F': *' '/APFS Volume Group/{print $2}' | grep -Eo "$UUID_RE")
echo "Grupo de volúmenes activo: ${activo:-NO DETECTADO}"
grupos=$(diskutil apfs listVolumeGroups 2>/dev/null | grep -Eo "$UUID_RE" | sort -u)
[ -z "$grupos" ] && grupos=$(diskutil apfs list 2>/dev/null | grep -i "Volume Group" | grep -Eo "$UUID_RE" | sort -u)
[ -z "$grupos" ] && [ -n "$activo" ] && grupos="$activo"
echo "Grupos de volúmenes en el disco:"
echo "$grupos" | sed 's/^/  /'
# shellcheck disable=SC2010  # los nombres son UUID alfanuméricos
carpetas=$(ls /System/Volumes/iSCPreboot 2>/dev/null | grep -Eo "^$UUID_RE$")
echo "Carpetas en /System/Volumes/iSCPreboot:"
if [ -z "$carpetas" ]; then
  echo "  (no se pudieron leer; ejecuta el script con sudo)"
else
  for c in $carpetas; do
    if echo "$grupos" | grep -qi "^$c$"; then
      echo "  $c  -> corresponde a un grupo de volúmenes del disco"
    else
      echo "  $c  -> sin grupo de volúmenes asociado (informativo; NO la borres)"
    fi
  done
fi

titulo "10. Último error de personalización en install.log"
grep -E "$PATRON" /var/log/install.log 2>/dev/null | tail -4 \
  || echo "No se encontraron líneas (o no hay permiso de lectura: usa sudo)"

titulo "11. Interpretación"
log=$(grep -E "$PATRON" /var/log/install.log 2>/dev/null | tail -20)
if echo "$log" | grep -qE "1256|SFR recovery"; then
  echo "-> Error 1256 'Failed to find SFR recovery volume': falla LOCAL, no de red."
  echo "   Causa: falta la partición Apple_APFS_Recovery (sección 8)."
  echo "   Soluciones: restauración DFU (ver README) o recrear la partición + revive."
elif echo "$log" | grep -q "ServerNotReachable"; then
  echo "-> kAMAuthInstallErrorServerNotReachable: el Mac NO llega al servidor de personalización."
  echo "   Revisa las secciones 3 a 7 (hosts, proxy, VPN, filtros, conexión)."
elif echo "$log" | grep -q "GLOBAL_TICKET_INVALID"; then
  echo "-> MSU_ERR_GLOBAL_TICKET_INVALID: Apple lo relacionó con el modo de Seguridad Reducida"
  echo "   (notas de la beta 1 de macOS 27). Revisa la Utilidad de seguridad de arranque."
elif echo "$log" | grep -qiE "1259|firmware identity|device identity|SFR installer"; then
  echo "-> Error 1259: el instalador no encuentra la identidad de este Mac (falla local)."
  echo "   Solo hay un reporte público (macOS 27 beta) y ninguna solución confirmada."
elif [ -n "$log" ]; then
  echo "-> Hay un error de personalización que no coincide con los patrones conocidos."
elif [ "$sfr_ok" = 0 ]; then
  echo "-> No hay errores en install.log, pero falta Apple_APFS_Recovery: las actualizaciones fallarán."
else
  echo "-> No hay registros del error en install.log."
fi
echo
echo "Fin del diagnóstico."
