#!/bin/sh
set -eu

INTERVAL=${BACKUP_INTERVAL:-300}
HOST=${POSTGRES_HOST:-db}
USER=${POSTGRES_USER:-p10}
DB=${POSTGRES_DB:-usuarios}
export PGPASSWORD="${POSTGRES_PASSWORD:-}"

mkdir -p /backups 2>/dev/null || true

echo "[p10-backup] destino /backups cada ${INTERVAL}s → ${USER}@${HOST}/${DB}"

while true; do
  if pg_isready -h "$HOST" -U "$USER" -d "$DB" >/dev/null 2>&1; then
    ts=$(date +%Y%m%d-%H%M%S)
    dest="/backups/usuarios-${ts}.sql.gz"
    if pg_dump -h "$HOST" -U "$USER" -d "$DB" --no-owner | gzip -c > "$dest"; then
      echo "[p10-backup] OK $dest"
      set +e
      ls -1t /backups/usuarios-*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
      set -e
    else
      echo "[p10-backup] FALLO pg_dump" >&2
      rm -f "$dest"
    fi
  else
    echo "[p10-backup] db no lista, reintento..."
  fi
  sleep "$INTERVAL"
done
