#!/bin/sh
# Restringe pg_hba al segmento infra_red (solo primer arranque de db_data).
set -eu
if [ -f "${PGDATA}/pg_hba.conf" ]; then
  if grep -qE '^host[[:space:]]+all[[:space:]]+all[[:space:]]+all[[:space:]]' "${PGDATA}/pg_hba.conf"; then
    sed -i -E 's|^host[[:space:]]+all[[:space:]]+all[[:space:]]+all[[:space:]].+|host all all 172.20.0.0/16 scram-sha-256|' \
      "${PGDATA}/pg_hba.conf"
  fi
fi
