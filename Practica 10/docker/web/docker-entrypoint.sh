#!/bin/sh
set -eu

HTML=/usr/share/nginx/html
SEED=/opt/p10-seed/html

mkdir -p "$HTML/general" "$HTML/instaladores" "$HTML/reprobados" "$HTML/recursadores" \
         /var/cache/nginx /var/log/nginx /run/nginx /var/lib/nginx/tmp \
         /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi \
         /tmp/nginx/uwsgi /tmp/nginx/scgi
touch /var/log/nginx/error.log /var/log/nginx/access.log

# Volumen web_content tapa el HTML de la imagen: sembrar estáticos si faltan.
if [ -d "$SEED" ]; then
  if [ ! -f "$HTML/index.html" ]; then
    cp -a "$SEED/." "$HTML/"
    echo "[p10-web] web_content vacío: HTML sembrado desde imagen."
  else
    cp -a "$SEED/css" "$SEED/img" "$SEED/index.html" "$HTML/" 2>/dev/null || true
  fi
  [ -f "$HTML/general/LEAME.txt" ] || cp -a "$SEED/general/." "$HTML/general/" 2>/dev/null || true
  [ -f "$HTML/instaladores/LEAME.txt" ] || cp -a "$SEED/instaladores/." "$HTML/instaladores/" 2>/dev/null || true
fi

chown www:www "$HTML" "$HTML/index.html" 2>/dev/null || true
chown -R www:www "$HTML/css" "$HTML/img" 2>/dev/null || true
chown www:www "$HTML/general" "$HTML/instaladores" 2>/dev/null || true
chmod 2775 "$HTML/general" || true
chmod 2770 "$HTML/instaladores" || true
chown root:reprobados "$HTML/reprobados" 2>/dev/null || chown 0:1002 "$HTML/reprobados" || true
chown root:recursadores "$HTML/recursadores" 2>/dev/null || chown 0:1003 "$HTML/recursadores" || true
chmod 2770 "$HTML/reprobados" "$HTML/recursadores" || true
chown -R www:www /var/cache/nginx /var/log/nginx /run/nginx /var/lib/nginx /tmp/nginx || true

generar_usuarios() {
  umask 022
  tmp=$(mktemp)
  {
    printf '%s\n' '<!DOCTYPE html><html lang="es"><head><meta charset="utf-8">'
    printf '%s\n' '<title>Usuarios — P10</title>'
    printf '%s\n' '<link rel="stylesheet" href="/css/estilo.css"></head><body>'
    printf '%s\n' '<main class="wrap"><h1>Usuarios (PostgreSQL)</h1>'
    printf '%s\n' '<p class="muted">Consulta en caliente al contenedor <code>db</code> por DNS de infra_red.</p>'
    if PGPASSWORD="${POSTGRES_PASSWORD:-}" psql -h "${POSTGRES_HOST:-db}" \
         -U "${POSTGRES_USER:-p10}" -d "${POSTGRES_DB:-usuarios}" \
         -H -c 'SELECT id, sam, nombre, grupo, creado FROM usuarios ORDER BY id;' 2>/dev/null; then
      true
    else
      printf '%s\n' '<p>La base aún no responde. Reintente en unos segundos.</p>'
    fi
    printf '%s\n' '</main></body></html>'
  } > "$tmp"
  mv "$tmp" "$HTML/usuarios.html"
  chown www:www "$HTML/usuarios.html" || true
}

# Nginx primero; psql en segundo plano para no retrasar el healthcheck.
(
  generar_usuarios || true
  n=0
  while [ "$n" -lt 10 ]; do
    n=$((n + 1))
    sleep 3
    generar_usuarios || true
  done
  while true; do
    sleep 60
    generar_usuarios || true
  done
) &

if ! su-exec www:www /usr/sbin/nginx -t; then
  echo "[p10-web] nginx -t falló:" >&2
  cat /var/log/nginx/error.log >&2 || true
  exit 1
fi

# daemon off ya está en nginx.conf; -g duplicaría la directiva y nginx sale con [emerg].
exec su-exec www:www /usr/sbin/nginx
