#!/bin/bash
# Prepara Linux Mint (22.x, base Ubuntu 24.04) para restaurar/revivir un Mac Apple silicon por DFU
# Compila desde GitHub: libplist, libimobiledevice-glue, libusbmuxd, libtatsu,
#                       libimobiledevice, libirecovery, usbmuxd e idevicerestore.
# Uso:  bash preparar-mint-idevicerestore.sh
set -e

DIR="$HOME/idevicerestore-build"
REPOS="libplist libimobiledevice-glue libusbmuxd libtatsu libimobiledevice libirecovery usbmuxd idevicerestore"

echo ">> Instalando herramientas de compilación..."
sudo apt-get update
sudo apt-get install -y build-essential pkg-config git autoconf automake libtool-bin \
  libreadline-dev libusb-1.0-0-dev libcurl4-openssl-dev libssl-dev libzip-dev zlib1g-dev \
  libsystemd-dev udev

mkdir -p "$DIR" && cd "$DIR"
for r in $REPOS; do
  echo ">> Compilando $r..."
  [ -d "$r" ] || git clone --depth 1 "https://github.com/libimobiledevice/$r.git"
  cd "$r"
  extra=""
  [ "$r" = "libplist" ] && extra="--without-cython"
  [ "$r" = "libimobiledevice" ] && extra="--without-cython"
  ./autogen.sh --prefix=/usr/local $extra
  make -j"$(nproc)"
  sudo make install
  sudo ldconfig
  cd "$DIR"
done

echo ">> Activando usbmuxd (necesario para la restauración)..."
# El servicio compilado arranca con el usuario 'usbmux': crearlo si no existe
if ! id usbmux >/dev/null 2>&1; then
  if getent group plugdev >/dev/null; then
    sudo useradd --system --no-create-home --home-dir /var/lib/usbmux -g plugdev --shell /usr/sbin/nologin usbmux
  else
    sudo useradd --system --no-create-home --home-dir /var/lib/usbmux --shell /usr/sbin/nologin usbmux
  fi
fi
sudo mkdir -p /var/lib/lockdown /var/lib/usbmux
sudo chown usbmux /var/lib/lockdown /var/lib/usbmux
sudo systemctl stop usbmuxd 2>/dev/null || true
sudo systemctl daemon-reload || true
sudo udevadm control --reload-rules || true

echo
echo "Listo. Versión instalada:"
idevicerestore --version
