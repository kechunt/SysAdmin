# FTP personalizado (Alpine + vsftpd)
FROM alpine:3.20

LABEL pract.sysadmin="10" \
      org.opencontainers.image.title="p10-ftp"

# vsftpd.pre-install ya crea el usuario ftp. Conf real: /etc/vsftpd/vsftpd.conf
RUN addgroup -g 1001 www \
    && addgroup -g 1002 reprobados \
    && addgroup -g 1003 recursadores \
    && apk add --no-cache vsftpd shadow \
    && mkdir -p /srv/ftp/web /etc/vsftpd /etc/pam.d /var/empty \
    && chmod 555 /var/empty \
    && grep -qxF /sbin/nologin /etc/shells || echo /sbin/nologin >> /etc/shells

COPY vsftpd.conf /etc/vsftpd/vsftpd.conf
COPY pam-vsftpd /etc/pam.d/vsftpd
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh \
    && sed -i 's/\r$//' /etc/vsftpd/vsftpd.conf /usr/local/bin/docker-entrypoint.sh /etc/pam.d/vsftpd \
    && chown root:root /etc/vsftpd/vsftpd.conf \
    && chmod 644 /etc/vsftpd/vsftpd.conf

EXPOSE 21 30000-30009
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
