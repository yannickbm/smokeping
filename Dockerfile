# ---------------------------------------------------------------------------
# SmokePing image for Pterodactyl
#
# Based on the parkervcp "yolk" so the container user (/home/container),
# entrypoint and startup-variable parsing are already Pterodactyl-compatible.
#
#   docker build -t ghcr.io/yannickbm/smokeping:latest .
#   docker push  ghcr.io/yannickbm/smokeping:latest
# ---------------------------------------------------------------------------

# --- stage 1: fping from source --------------------------------------------
# Debian 13 ships fping 5.1, which is broken for our case. Wings drops
# CAP_NET_RAW, so fping falls back to unprivileged ICMP datagram sockets. On
# those the kernel overwrites the ICMP echo id with the socket's port number,
# while 5.1 still filters replies on the id it wrote itself - so every reply is
# discarded and every target reports 100% loss. Measured on a live container:
# sent id 0xBEEF, received id 0x004A.
#
# netbase is not optional here: fping calls getprotobyname("icmp") on startup,
# which reads /etc/protocols. Without it even "fping -v" dies with
# "icmp: unknown protocol" and exit code 4. debian:*-slim does not ship it.
#
# fping 5.2 fixed this ("Fix running in unprivileged mode", #248). Build from
# source until Debian ships >= 5.2. Match the base distro so glibc lines up.
ARG FPING_VERSION=5.3

FROM debian:trixie-slim AS fping-builder
ARG FPING_VERSION
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential curl ca-certificates \
        netbase; \
    curl -sfL "https://fping.org/dist/fping-${FPING_VERSION}.tar.gz" | tar xz -C /tmp; \
    cd "/tmp/fping-${FPING_VERSION}"; \
    ./configure --prefix=/usr --enable-ipv4 --enable-ipv6; \
    make; \
    make install DESTDIR=/out; \
    # upstream uses sbin_PROGRAMS; the SmokePing config expects /usr/bin/fping
    find /out -type f -name fping -exec cp {} /fping \;; \
    /fping -v

# --- stage 2: runtime -------------------------------------------------------
FROM ghcr.io/parkervcp/yolks:debian

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        smokeping \
        rrdtool \
        lighttpd \
        curl \
        ca-certificates \
        perl \
        libconfig-grammar-perl \
        librrds-perl \
        libdigest-hmac-perl \
        libsnmp-session-perl \
        libcgi-pm-perl \
        libcgi-fast-perl \
        libnet-dns-perl \
        libio-socket-ssl-perl \
        libcap2-bin \
        netbase \
        iputils-ping \
        tzdata; \
    \
    # Stash the default templates + web assets so the egg installer can copy
    # them into /home/container.
    mkdir -p /opt/smokeping-defaults/www; \
    for f in basepage.html smokemail tmail; do \
        [ -f "/etc/smokeping/$f" ] && cp -a "/etc/smokeping/$f" /opt/smokeping-defaults/ || true; \
    done; \
    for d in /usr/share/smokeping/www /var/www/html/smokeping /usr/share/doc/smokeping/htdocs; do \
        [ -d "$d" ] && cp -a "$d/." /opt/smokeping-defaults/www/ || true; \
    done; \
    \
    # Debian does not ship the css/js the template needs, so take them from the
    # upstream release. Without these the web interface renders unstyled.
    SP_VER=2.8.2; \
    curl -sfL "https://github.com/oetiker/SmokePing/archive/refs/tags/${SP_VER}.tar.gz" \
        | tar xz -C /opt/smokeping-defaults/www --strip-components=2 \
            "SmokePing-${SP_VER}/htdocs/css" "SmokePing-${SP_VER}/htdocs/js"; \
    \
    rm -rf /var/lib/apt/lists/*

# Must come AFTER apt: the smokeping package depends on Debian's fping and
# would otherwise overwrite the source build.
COPY --from=fping-builder /fping /usr/bin/fping

RUN set -eu; \
    # No caps, no setuid: a binary carrying file capabilities that are not in
    # the bounding set fails to exec once Wings drops CAP_NET_RAW. Without them
    # fping >= 5.2 uses unprivileged ICMP datagram sockets, which do work.
    chmod 0755 /usr/bin/fping; \
    setcap -r /usr/bin/fping 2>/dev/null || true; \
    chmod u-s /usr/bin/fping 2>/dev/null || true; \
    # fail the build if the wrong fping survived
    /usr/bin/fping -v; \
    /usr/bin/fping -v 2>&1 | grep -qE 'Version 5\.([2-9]|[1-9][0-9])' \
        || { echo "FATAL: /usr/bin/fping is older than 5.2"; exit 1; }

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

CMD ["/bin/bash", "/entrypoint.sh"]
