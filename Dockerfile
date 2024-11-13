ARG BASETAG=latest
FROM postgres:$BASETAG

ARG GOCRONVER=v0.0.11
ARG TARGETOS
ARG TARGETARCH

# FIX Debian cross build
ARG DEBIAN_FRONTEND=noninteractive
RUN set -x \
    && ln -s /usr/bin/dpkg-split /usr/sbin/dpkg-split \
    && ln -s /usr/bin/dpkg-deb /usr/sbin/dpkg-deb \
    && ln -s /bin/tar /usr/sbin/tar \
    && ln -s /bin/rm /usr/sbin/rm \
    && ln -s /usr/bin/dpkg-split /usr/local/sbin/dpkg-split \
    && ln -s /usr/bin/dpkg-deb /usr/local/sbin/dpkg-deb \
    && ln -s /bin/tar /usr/local/sbin/tar \
    && ln -s /bin/rm /usr/local/sbin/rm

RUN set -x \
    && mkdir -p /etc/postgresql \
    && mkdir -p /etc/postgresql/ssl \
    && mkdir -p /var/lib/postgresql/data/log

RUN set -x \
    && apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && curl --fail --retry 4 --retry-all-errors -o /usr/local/bin/go-cron.gz -L https://github.com/prodrigestivill/go-cron/releases/download/$GOCRONVER/go-cron-$TARGETOS-$TARGETARCH.gz \
    && gzip -vnd /usr/local/bin/go-cron.gz && chmod a+x /usr/local/bin/go-cron

ENV POSTGRES_DB="**None**" \
    POSTGRES_DB_FILE="**None**" \
    POSTGRES_USER="**None**" \
    POSTGRES_USER_FILE="**None**" \
    POSTGRES_PASSWORD="**None**" \
    POSTGRES_PASSWORD_FILE="**None**" \
    POSTGRES_PASSFILE_STORE="**None**" \
    SCHEDULE="@hourly" \
    BACKUP_ON_START="FALSE" \
    BACKUP_DIR="/backups" \
    BACKUP_PREFIX="postgres" \
    BACKUP_SUFFIX=".zst" \
    BACKUP_KEEP_DAYS=30 \
    HEALTHCHECK_PORT=8080 \
    WEBHOOK_URL="**None**" \
    WEBHOOK_ERROR_URL="**None**" \
    WEBHOOK_PRE_BACKUP_URL="**None**" \
    WEBHOOK_POST_BACKUP_URL="**None**" \
    WEBHOOK_EXTRA_ARGS=""

COPY postgresql.conf /etc/postgresql/postgresql.conf
COPY hooks /hooks
COPY backup.sh env.sh init.sh /

RUN set -x \
    && chown -R postgres:postgres /etc/postgresql \
    && chmod 600 /etc/postgresql/postgresql.conf \
    && chown -R postgres:postgres /var/lib/postgresql/data \
    && chmod 700 /var/lib/postgresql/data \
    && chmod +x /backup.sh /env.sh /init.sh

VOLUME ["/backups", "/var/lib/postgresql/data"]

ENTRYPOINT []
CMD ["/init.sh"]

HEALTHCHECK --interval=5m --timeout=3s \
    CMD curl -f "http://localhost:$HEALTHCHECK_PORT/" || exit 1
