# Web P10 — Nginx en Alpine, sin server tokens, proceso no root
FROM alpine:3.20

LABEL pract.sysadmin="10" \
      org.opencontainers.image.title="p10-web"

# Usuario www ANTES de apk, UID/GID 1001 (evita choque con el user nginx del paquete)
RUN addgroup -g 1001 www \
    && addgroup -g 1002 reprobados \
    && addgroup -g 1003 recursadores \
    && adduser -D -H -u 1001 -G www -s /sbin/nologin www \
    && addgroup www reprobados \
    && addgroup www recursadores \
    && apk add --no-cache nginx postgresql-client iputils curl su-exec \
    && mkdir -p /var/cache/nginx /var/log/nginx /run/nginx /var/lib/nginx/tmp \
                 /usr/share/nginx/html /opt/p10-seed /tmp/nginx \
    && chown -R www:www /var/cache/nginx /var/log/nginx /run/nginx /var/lib/nginx \
                         /usr/share/nginx/html /tmp/nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY html/ /usr/share/nginx/html/
COPY html/ /opt/p10-seed/html/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh \
    && chown -R www:www /usr/share/nginx/html /opt/p10-seed

EXPOSE 8080
# El entrypoint necesita root para sembrar el volumen; nginx se lanza con su-exec www.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
