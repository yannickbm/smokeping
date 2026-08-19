# ---------------------------------------------------------------------------
# SmokePing image for Pterodactyl
#
# Based on the parkervcp "yolk" so the container user (/home/container),
# entrypoint and startup-variable parsing are already Pterodactyl-compatible.
#
#   docker build -t ghcr.io/yannickbm/smokeping:latest .
#   docker push  ghcr.io/yannickbm/smokeping:latest
# ---------------------------------------------------------------------------
FROM ghcr.io/parkervcp/yolks:debian

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        smokeping \
        fping \
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
        tzdata; \
    \
    # Wings drops CAP_NET_RAW. A binary carrying file capabilities that are not
    # in the bounding set can fail to exec, so strip caps/setuid and let fping
    # (>= 5.0) fall back to unprivileged ICMP datagram sockets.
    setcap -r /usr/bin/fping 2>/dev/null || true; \
    chmod u-s /usr/bin/fping 2>/dev/null || true; \
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
    rm -rf /var/lib/apt/lists/*

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

CMD ["/bin/bash", "/entrypoint.sh"]
