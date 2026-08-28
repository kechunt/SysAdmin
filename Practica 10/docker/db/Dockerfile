# PostgreSQL personalizado (Alpine) — esquema de usuarios del laboratorio
FROM postgres:16-alpine

LABEL pract.sysadmin="10" \
      org.opencontainers.image.title="p10-db"

COPY init.sql /docker-entrypoint-initdb.d/01-usuarios.sql
COPY 02-pg_hba.sh /docker-entrypoint-initdb.d/02-pg_hba.sh
RUN chmod 755 /docker-entrypoint-initdb.d/02-pg_hba.sh
