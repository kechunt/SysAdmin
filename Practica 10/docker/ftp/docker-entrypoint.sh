#!/bin/sh
set -eu

WEB=/srv/ftp/web
CONF=/etc/vsftpd/vsftpd.conf

mkdir -p "$WEB/general" "$WEB/instaladores" "$WEB/reprobados" "$WEB/recursadores" /var/empty /var/log
chmod 555 /var/empty || true
grep -qxF /sbin/nologin /etc/shells || echo /sbin/nologin >> /etc/shells

addgroup -g 1001 www 2>/dev/null || true
addgroup -g 1002 reprobados 2>/dev/null || true
addgroup -g 1003 recursadores 2>/dev/null || true

chown www:www "$WEB/general" "$WEB/instaladores" 2>/dev/null || true
chmod 2775 "$WEB/general" || true
chmod 2770 "$WEB/instaladores" || true
chown root:reprobados "$WEB/reprobados" 2>/dev/null || true
chown root:recursadores "$WEB/recursadores" 2>/dev/null || true
chmod 2770 "$WEB/reprobados" "$WEB/recursadores" || true
chmod 755 "$WEB" || true

ensure_user() {
  sam=$1
  pass=$2
  extra=$3
  pass=$(printf '%s' "$pass" | tr -d '"')
  if ! id "$sam" >/dev/null 2>&1; then
    adduser -D -H -h "$WEB" -s /sbin/nologin -G www "$sam"
  fi
  printf '%s:%s\n' "$sam" "$pass" | chpasswd
  addgroup "$sam" "$extra" 2>/dev/null || true
}

ensure_user ftp_reprobado "${FTP_REPROBADO_PASS:-Reprobados#P10}" reprobados
ensure_user ftp_recursador "${FTP_RECURSADOR_PASS:-Recursadores#P10}" recursadores

sed -i 's/\r$//' "$CONF" || true
grep -v '^pasv_address=' "$CONF" > "${CONF}.tmp"
if [ -n "${HOST_LAN_IP:-}" ]; then
  printf 'pasv_address=%s\n' "$HOST_LAN_IP" >> "${CONF}.tmp"
fi
mv "${CONF}.tmp" "$CONF"
chown root:root "$CONF"
chmod 644 "$CONF"

echo "[p10-ftp] conf=${CONF} PASV=${HOST_LAN_IP:-unset}"
echo "[p10-ftp] --- vsftpd.conf ---"
cat "$CONF"
echo "[p10-ftp] arrancando /usr/sbin/vsftpd"

# Si muere, el OOPS queda en docker logs.
exec /usr/sbin/vsftpd "$CONF"
