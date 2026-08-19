#!/bin/bash
# ---------------------------------------------------------------------------
# SmokePing installer for Pterodactyl
# Runs as root in a plain Debian container; /mnt/server == /home/container
# Templates and web assets are copied from the SmokePing image by start.sh,
# because they only exist inside that image - not here.
# ---------------------------------------------------------------------------
set -euo pipefail

echo "[*] Creating directory layout"
mkdir -p /mnt/server/data /mnt/server/cache /mnt/server/run /mnt/server/tmp/fontcache /mnt/server/www /mnt/server/logs
cd /mnt/server

# ---------------------------------------------------------------------------
# CGI (served from the document root by lighttpd)
# ---------------------------------------------------------------------------
echo "[*] Writing www/smokeping.cgi"
cat > /mnt/server/www/smokeping.cgi <<'CGIEOF'
#!/usr/bin/perl -w
use strict;
use lib qw(/usr/share/smokeping/lib /usr/share/perl5);
use CGI;
use CGI::Carp qw(fatalsToBrowser);
use Smokeping;

# Smokeping::cgi has a ($$) prototype: config path + CGI object
my $q = CGI->new;
Smokeping::cgi("/home/container/config", $q);
CGIEOF

# ---------------------------------------------------------------------------
# lighttpd
# ---------------------------------------------------------------------------
echo "[*] Writing lighttpd.conf"
cat > /mnt/server/lighttpd.conf <<'LIGHTEOF'
server.modules = ( "mod_alias", "mod_cgi", "mod_setenv" )

server.document-root = "/home/container/www"

# Without this every CGI request dumps SmokePing's upstream perl warnings
# straight into the Pterodactyl console - roughly seven lines per pageview.
# They are harmless but they bury the messages that do matter.
server.errorlog      = "/home/container/logs/lighttpd-error.log"

# server.errorlog only covers lighttpd itself. Anything a CGI writes to stderr
# goes to the server's own stderr - which here is the Pterodactyl console.
# SmokePing 2.8.2 emits a dozen "uninitialized value" warnings per pageview
# through CGI::Carp, so without breakagelog every page load floods the console.
server.breakagelog   = "/home/container/logs/cgi-stderr.log"
server.upload-dirs   = ( "/home/container/tmp" )

# The allocated port is injected at runtime
include_shell "echo server.port = ${SERVER_PORT:-8080}"

index-file.names = ( "smokeping.cgi", "index.html" )

mimetype.assign = (
  ".html" => "text/html",  ".htm"  => "text/html",
  ".css"  => "text/css",   ".js"   => "application/javascript",
  ".json" => "application/json",
  ".png"  => "image/png",  ".gif"  => "image/gif",
  ".jpg"  => "image/jpeg", ".jpeg" => "image/jpeg",
  ".svg"  => "image/svg+xml", ".ico" => "image/x-icon",
  ".woff" => "font/woff",  ".woff2" => "font/woff2",
  ".ttf"  => "font/ttf",   ".eot"  => "application/vnd.ms-fontobject",
  ".txt"  => "text/plain",
  ""      => "application/octet-stream"
)

# The Debian template expects everything under /smokeping/, the way its Apache
# config publishes it. Serve both that prefix and the root so either works.
alias.url += (
  "/smokeping/cache/"        => "/home/container/cache/",
  "/smokeping/smokeping.cgi" => "/home/container/www/smokeping.cgi",
  "/smokeping/"              => "/home/container/www/",
  "/cache/"                  => "/home/container/cache/"
)

cgi.assign = ( ".cgi" => "/usr/bin/perl" )

# mod_cgi hands the script a stripped environment. RRDtool draws its labels
# through fontconfig, which needs a writable cache dir - without HOME it fails
# with "No writable cache directories" and the graphs come out broken.
setenv.add-environment = (
  "HOME"           => "/home/container",
  "XDG_CACHE_HOME" => "/home/container/tmp/fontcache",
  "TMPDIR"         => "/home/container/tmp"
)
LIGHTEOF

# ---------------------------------------------------------------------------
# start script - also seeds templates from the image on first boot
# ---------------------------------------------------------------------------
echo "[*] Writing start.sh"
cat > /mnt/server/start.sh <<'STARTEOF'
#!/bin/bash
cd /home/container || exit 1

CONFIG=/home/container/config
DEFAULTS=/opt/smokeping-defaults
SMOKEPING_BIN=/usr/sbin/smokeping
[ -x "$SMOKEPING_BIN" ] || SMOKEPING_BIN=$(command -v smokeping)

mkdir -p data cache run tmp tmp/fontcache www logs

# --- seed templates and web assets from the image (first boot only) --------
for f in basepage.html smokemail tmail; do
    if [ ! -s "/home/container/$f" ] && [ -f "$DEFAULTS/$f" ]; then
        echo "[*] Installing default $f"
        cp -a "$DEFAULTS/$f" "/home/container/$f"
    fi
done

# --- web assets (css/js) - the page is unstyled without them --------------
if [ ! -d /home/container/www/css ] && [ -d "$DEFAULTS/www/css" ]; then
    echo "[*] Installing web assets from the image"
    cp -a "$DEFAULTS/www/." /home/container/www/ 2>/dev/null || true
fi

if [ ! -f /home/container/www/css/smokeping-screen.css ]; then
    ASSET_VER="${ASSET_VERSION:-2.8.2}"
    ASSET_URL="https://github.com/oetiker/SmokePing/archive/refs/tags/${ASSET_VER}.tar.gz"
    echo "[*] Downloading SmokePing $ASSET_VER web assets (one time only)"
    if ! ( cd /home/container/www && curl -sfL "$ASSET_URL" \
            | tar xz --strip-components=2 \
                "SmokePing-${ASSET_VER}/htdocs/css" \
                "SmokePing-${ASSET_VER}/htdocs/js" ); then
        echo "[!] Could not fetch web assets - the interface works but stays unstyled."
    fi
fi

if [ ! -s /home/container/basepage.html ]; then
    echo "[*] No template in the image, writing a minimal basepage.html"
    cat > /home/container/basepage.html <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title><##title##></title>
<style>
body{font-family:system-ui,sans-serif;margin:1.5em;background:#fafafa;color:#222}
#menu{float:left;width:230px;font-size:.9em}
#body{margin-left:260px}
a{color:#0a58ca;text-decoration:none}a:hover{text-decoration:underline}
</style>
</head>
<body>
<h1><##title##></h1>
<div id="menu"><##menu##></div>
<div id="body"><##body##></div>
</body>
</html>
HTMLEOF
fi

touch /home/container/smokemail /home/container/tmail
chmod +x /home/container/www/smokeping.cgi 2>/dev/null || true

# --- keep cgiurl in sync ---------------------------------------------------
# SmokePing builds its links and alert mails from cgiurl, and a container
# cannot discover its own public address when it sits behind a reverse proxy.
# Set PUBLIC_URL to the address users actually type; leave it empty for direct
# access on the allocation. Either way the line is rewritten on every boot, so
# it cannot drift away from reality.
if [ -n "${PUBLIC_URL:-}" ]; then
    CGIURL="${PUBLIC_URL%/}/smokeping.cgi"
else
    CGIURL="http://${SERVER_IP}:${SERVER_PORT}/smokeping.cgi"
fi
sed -i -E "s|^[[:space:]]*cgiurl[[:space:]]*=.*|cgiurl    = ${CGIURL}|" "$CONFIG"
echo "[*] cgiurl = ${CGIURL}"

# --- ICMP self-test --------------------------------------------------------
# Silent 100% loss is indistinguishable from a working probe, so say so loudly.
# The console cannot be used for this: the main process is bash running this
# script and it never reads stdin, so console input goes nowhere. The result is
# written to icmp-test.txt as well as printed here.
{
    echo "== fping -c1 1.1.1.1 =="
    fping -c1 -t2000 1.1.1.1 2>&1
    echo "fping exit=$?"
    echo
    echo "== fping version =="
    fping -v 2>&1 | head -1
    echo "== id =="
    id
    echo "== /proc/sys/net/ipv4/ping_group_range =="
    cat /proc/sys/net/ipv4/ping_group_range 2>&1
    echo "== getcap /usr/bin/fping =="
    getcap /usr/bin/fping 2>&1 || echo "(none)"
} > /home/container/icmp-test.txt 2>&1

if grep -q "^fping exit=0$" /home/container/icmp-test.txt 2>/dev/null; then
    echo "[*] ICMP self-test passed."
else
    echo "[!] ICMP self-test FAILED - every target will report 100% loss."
    echo "[!] Details in icmp-test.txt."
    echo "[!] fping below 5.2 cannot do this: without CAP_NET_RAW it uses"
    echo "[!] unprivileged ICMP sockets, whose echo id the kernel rewrites,"
    echo "[!] and only 5.2+ matches replies correctly. Check the version above."
fi

echo "[*] Checking configuration"
if ! "$SMOKEPING_BIN" --config="$CONFIG" --check; then
    echo "[!] Configuration error - fix /home/container/config and restart."
    exit 1
fi

shutdown_all() {
    echo "[*] Shutting down"
    kill -TERM "${SMOKE_PID:-}" "${HTTP_PID:-}" 2>/dev/null
    wait
    exit 0
}
trap shutdown_all SIGINT SIGTERM

echo "[*] Starting SmokePing daemon"
"$SMOKEPING_BIN" --config="$CONFIG" --nodaemon &
SMOKE_PID=$!

echo "[*] Starting lighttpd"
lighttpd -D -f /home/container/lighttpd.conf &
HTTP_PID=$!

sleep 2
echo "SmokePing is up - http://${SERVER_IP}:${SERVER_PORT}/"

wait -n
echo "[!] A child process exited, stopping the server."
kill -TERM "${SMOKE_PID:-}" "${HTTP_PID:-}" 2>/dev/null
wait
STARTEOF

# ---------------------------------------------------------------------------
# main config (only on first install, never overwrite user edits)
# ---------------------------------------------------------------------------
if [ ! -f /mnt/server/config ]; then
    echo "[*] Writing default config"
    cat > /mnt/server/config <<CONFEOF
*** General ***

owner     = ${OWNER:-Pterodactyl Admin}
contact   = ${CONTACT:-admin@example.com}
mailhost  = localhost
sendmail  = /usr/sbin/sendmail
imgcache  = /home/container/cache
imgurl    = cache
datadir   = /home/container/data
piddir    = /home/container/run
smokemail = /home/container/smokemail
tmail     = /home/container/tmail
# rewritten on every boot from PUBLIC_URL, or from the allocation if empty
cgiurl    = http://${SERVER_IP:-127.0.0.1}:${SERVER_PORT:-8080}/smokeping.cgi
# no syslogfacility -> logging goes to the Pterodactyl console
concurrentprobes = no

*** Alerts ***
to   = ${CONTACT:-admin@example.com}
from = smokeping@localhost

+someloss
type    = loss
pattern = >0%,*12*,>0%,*12*,>0%
comment = loss 3 times in a row

*** Database ***

step  = 300
pings = 20

# consfn mrhb steps total
AVERAGE  0.5   1  1008
AVERAGE  0.5  12  4320
    MIN  0.5  12  4320
    MAX  0.5  12  4320
AVERAGE  0.5 144   720
    MIN  0.5 144   720
    MAX  0.5 144   720

*** Presentation ***

template = /home/container/basepage.html
charset  = utf-8

+ charts
menu = Charts
title = The most interesting destinations

++ stddev
sorter = StdDev(entries=>4)
title = Top Standard Deviation
menu = Std Deviation
format = Standard Deviation %f

++ max
sorter = Max(entries=>5)
title = Top Max Roundtrip Time
menu = by Max
format = Max Roundtrip Time %f seconds

++ loss
sorter = Loss(entries=>5)
title = Top Packet Loss
menu = Loss
format = Packets Lost %f

++ median
sorter = Median(entries=>5)
title = Top Median Roundtrip Time
menu = by Median
format = Median RTT %f seconds

+ overview
width = 600
height = 50
range = 10h

+ detail
width = 600
height = 200
unison_tolerance = 2

"Last 3 Hours"    3h
"Last 30 Hours"   30h
"Last 10 Days"    10d
"Last 400 Days"   400d

*** Probes ***

+ FPing
binary     = /usr/bin/fping
packetsize = 56

# ICMP blocked or not permitted? Uncomment the Curl probe below and give
# targets "probe = Curl" - it measures HTTP round-trip and needs no raw sockets.
#+ Curl
#binary    = /usr/bin/curl
#forks     = 5
#step      = 60
#urlformat = http://%host%/

*** Targets ***

probe = FPing

menu   = Top
title  = Network Latency Grapher
remark = Welcome to the SmokePing website of ${OWNER:-Pterodactyl Admin}.

+ Internet
menu  = Internet
title = Public resolvers

++ Cloudflare
menu  = Cloudflare
title = Cloudflare DNS (1.1.1.1)
host  = 1.1.1.1

++ Google
menu  = Google
title = Google DNS (8.8.8.8)
host  = 8.8.8.8

++ Quad9
menu  = Quad9
title = Quad9 (9.9.9.9)
host  = 9.9.9.9
CONFEOF
else
    echo "[*] Existing config found, leaving it untouched"
fi

echo "[*] Writing README.md"
cat > /mnt/server/README.md <<'READMEEOF'
# SmokePing — how to add and change things

Everything lives in the file `config` in this folder. Edit it in the file manager,
then **restart the server** — SmokePing reads the config only at startup.

If the config has a syntax error the server refuses to start and prints the reason
in the console. Nothing is lost; fix the line it names and start again.

Your measurement history is in `data/`. It is never touched by a reinstall, and
neither is `config`.

---

## Add a host

Scroll to `*** Targets ***` at the bottom of `config`. Every host is a block that
starts with `++` under a group that starts with `+`:

```
++ MyServer
menu  = My Server
title = My Server (203.0.113.10)
host  = 203.0.113.10
```

- `menu` — the text in the sidebar. Keep it short.
- `title` — the heading above the graph.
- `host` — an IP address or a hostname. Hostnames are resolved at startup.

The name after `++` (here `MyServer`) is the internal ID. Use only letters,
numbers, `-` and `_`, and make it unique. It becomes the RRD filename, so
renaming it later starts the history over — the old data stays behind as an
orphaned file in `data/`.

## Add a group

Groups are one level up, with a single `+`. Anything you nest under them with `++`
belongs to that group:

```
+ Office
menu  = Office
title = Office locations

++ Rotterdam
menu  = Rotterdam
host  = 198.51.100.20

++ Antwerp
menu  = Antwerp
host  = 198.51.100.21
```

Deeper nesting works too: `+++` sits inside a `++`, and so on.

## Put several hosts in one graph

Useful for comparing two paths to the same service:

```
++ BothResolvers
menu  = Both resolvers
title = Cloudflare vs Google
host  = /Internet/Cloudflare /Internet/Google
```

The paths are the menu structure, starting from the top of `*** Targets ***`.

---

## Measure something other than ICMP

If ping is blocked or not permitted, use HTTP instead. Uncomment the Curl probe in
the `*** Probes ***` section:

```
+ Curl
binary    = /usr/bin/curl
forks     = 5
step      = 60
urlformat = http://%host%/
```

Then point individual targets at it. A target uses `FPing` unless you say
otherwise:

```
++ MyWebsite
menu  = My website
title = my-site.example (HTTP)
probe = Curl
host  = my-site.example
```

For HTTPS, change `urlformat` to `https://%host%/`.

## Change how often it measures

In `*** Database ***`:

```
step  = 300
pings = 20
```

`step` is the seconds between measurement rounds, `pings` the number of packets
per round. The defaults mean 20 pings every 5 minutes.

Changing `step` after data exists **invalidates your history** — the RRD files are
built around it, and SmokePing will refuse to start until you delete the old files
in `data/`. Decide early, or accept starting fresh.

Raising `pings` gives a more detailed smoke band but more traffic. Above roughly
20 targets, also set `concurrentprobes = yes` in `*** General ***` so probes run in
parallel.

## Change the graph time ranges

In `*** Presentation ***`, under `+ detail`:

```
"Last 3 Hours"    3h
"Last 30 Hours"   30h
"Last 10 Days"    10d
"Last 400 Days"   400d
```

Left is the label, right is the range. Add or remove lines freely; `h`, `d`, `w`,
`m` and `y` all work. `+ overview` controls the small graphs on group pages.

## Alerts

Alerts are defined in `*** Alerts ***` and then attached to targets:

```
++ MyServer
menu  = My Server
host  = 203.0.113.10
alerts = someloss
```

Without a working mail setup (`sendmail` / `mailhost` in `*** General ***`) alerts
are only visible in the console, not delivered by e-mail. The container has no
mail server of its own.

---

## Behind a reverse proxy

Fill in the `PUBLIC_URL` variable in the server's Startup tab with the address
people actually type:

```
https://smokeping.example.com
```

No trailing slash and no `/smokeping.cgi` — that part is added for you. On every
start the `cgiurl` line in `config` is rewritten to match, so it cannot drift out
of date. Leave `PUBLIC_URL` empty and it falls back to the raw IP and port, which
is what you want without a proxy.

Point the proxy at the node's IP and the server's allocated port. Nothing else is
needed — the graph images are served from the same port under `/cache/`.

Note that the allocation stays reachable directly on `http://IP:PORT/` as well.
The proxy adds a name and a certificate; it does not hide the origin. If the
instance should only be reachable through the proxy, restrict the port on the
node itself.

## Files in this folder

| Path | What it is |
|---|---|
| `config` | Everything you edit. Survives reinstalls. |
| `data/` | RRD measurement history. Survives reinstalls. |
| `cache/` | Generated graph images. Safe to delete. |
| `basepage.html` | HTML template for the web page. |
| `www/` | Web root: the CGI and static assets. |
| `lighttpd.conf` | Web server config. Overwritten on reinstall. |
| `start.sh` | Startup script. Overwritten on reinstall. |

## When something breaks

- **Server won't start** — read the console; the config check names the line.
- **All targets show 100% loss** — the container probably can't send ICMP. Run
  `fping -c1 1.1.1.1` in the console. If it fails, switch to the Curl probe above.
- **Graphs are empty right after setup** — normal. The first data point appears
  after one `step` (5 minutes by default), a usable line after about half an hour.
- **A new target stays blank** — check the console for a resolve error on the
  hostname, and confirm you restarted after editing.

Full documentation: https://oss.oetiker.ch/smokeping/doc/
READMEEOF

chmod +x /mnt/server/start.sh /mnt/server/www/smokeping.cgi

echo "[*] Installation done"
