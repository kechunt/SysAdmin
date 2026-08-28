# Sidecar de respaldo: pg_dump periódico hacia carpeta del host
FROM alpine:3.20

RUN apk add --no-cache postgresql-client gzip tzdata
COPY backup-loop.sh /usr/local/bin/backup-loop.sh
RUN chmod 755 /usr/local/bin/backup-loop.sh
WORKDIR /backups
ENTRYPOINT ["/usr/local/bin/backup-loop.sh"]
