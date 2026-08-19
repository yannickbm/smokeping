# SmokePing op Pterodactyl — projectcontext

Overdrachtsdocument. Alles wat is gebouwd, waarom het zo is gebouwd, wat er is
misgegaan en wat er nog open staat.

---

## 1. Doel

SmokePing (netwerklatency-monitoring, RRD-grafieken) draaien als Pterodactyl-egg,
zodat er per server een instantie aangemaakt kan worden zonder handwerk.

## 2. Status

Werkt:
- Image bouwt en staat op `ghcr.io/yannickbm/smokeping:latest` (public)
- Egg installeert, server start, daemon meet 3 targets
- Webinterface bereikbaar op de allocatie (getest: `84.247.164.16:6666`)

Open:
- Grafieken lijken leeg. Vermoedelijke oorzaak is de fontconfig-fout (zie §6.6),
  fix is geschreven maar op het moment van schrijven nog niet doorgevoerd in het panel
- Nog niet geverifieerd of ICMP werkt in de container (`fping -c1 1.1.1.1`)
- GitHub Actions ligt stil door een billing-lock op het GitHub-account; de image is
  daarom met de hand gebouwd en gepusht

---

## 3. Repo en image

- Repo: https://github.com/yannickbm/smokeping
- Image: `ghcr.io/yannickbm/smokeping:latest` (GHCR, public)
- Build via `.github/workflows/build-image.yml` (werkt zodra billing opgelost is),
  of met de hand:
  ```bash
  docker build -t ghcr.io/yannickbm/smokeping:latest .
  docker push ghcr.io/yannickbm/smokeping:latest
  ```

## 4. Bestanden

| Bestand | Rol |
|---|---|
| `Dockerfile` | Runtime-image. Basis `ghcr.io/parkervcp/yolks:debian`, daarbovenop smokeping, fping, rrdtool, lighttpd, perl-modules |
| `egg-smokeping.json` | De egg. Bevat het install-script als JSON-string |
| `install-script.sh` | Hetzelfde install-script als los bestand, voor copy-paste in het panel |
| `lighttpd.conf` | Webserverconfig (wordt door het install-script geschreven; los bestand voor handmatige fixes) |
| `basepage.html` | Alternatieve HTML-template met inline CSS. **Niet in gebruik** — de originele Debian-template plus upstream css/js geeft een beter resultaat |
| `README-smokeping.md` | Engelstalige gebruikersuitleg, wordt door het install-script als `README.md` in de serverfolder gezet |
| `build-image.yml` | GitHub Actions workflow |
| `setup-repo.sh` | Eenmalig hulpscript om de repo te vullen |

## 5. Hoe het draait

Install-container (`debian:bookworm-slim`, als root) schrijft naar `/mnt/server`:
`config`, `start.sh`, `lighttpd.conf`, `www/smokeping.cgi`, `README.md` en de
lege mappen `data/`, `cache/`, `run/`, `tmp/fontcache/`, `www/`.

Runtime-container draait `bash /home/container/start.sh`, dat:
1. ontbrekende templates uit `/opt/smokeping-defaults` kopieert
2. css/js downloadt van GitHub als `www/css` ontbreekt (zie §6.5)
3. `cgiurl` herschrijft naar `IP:PORT` als `AUTO_CGIURL=1`
4. `smokeping --check` draait; bij een fout stopt hij met de reden
5. de daemon met `--nodaemon` en lighttpd met `-D` start, beide in de achtergrond
6. `SmokePing is up` echoot — dit is de done-regex waar Wings op wacht
7. via `wait -n` de boel afsluit zodra één van beide processen stopt

Stopcommando is `^^C` (SIGINT), afgevangen door een trap in `start.sh`.

Variabelen: `OWNER`, `CONTACT`, `AUTO_CGIURL` (1/0), `ASSET_VERSION` (2.8.2).

---

## 6. Opgeloste problemen

Deze staan er expliciet in omdat ze allemaal niet-voor-de-hand-liggend waren.

### 6.1 apt-installatie in het install-script werkt niet
Pterodactyl bewaart alleen `/mnt/server` uit de install-container. Systeempakketten
verdwijnen. Daarom een eigen image in plaats van installeren tijdens de install.

### 6.2 `bash: /mnt/install/install.sh: Permission denied`
De install-container stond op onze eigen image, en die eindigt op `USER container`.
Die gebruiker mag het door Wings geschreven install-script niet lezen. Opgelost door
`debian:bookworm-slim` als install-container te gebruiken (draait als root).

Gevolg: het install-script kan niet meer bij `/opt/smokeping-defaults` uit de image.
Het kopiëren van templates is daarom verplaatst naar `start.sh`.

### 6.3 fping en CAP_NET_RAW
Wings dropt `CAP_NET_RAW`. Een binary met file-capabilities die niet in de bounding
set zitten kan daardoor niet meer exec'en. De Dockerfile doet daarom `setcap -r` en
`chmod u-s` op fping, zodat fping 5.x terugvalt op unprivileged ICMP datagram
sockets. Werkt zolang `net.ipv4.ping_group_range` in de container de GID omvat —
Docker zet die standaard op `0 2147483647`.

**Nog niet geverifieerd.** Test: `fping -c1 1.1.1.1` in de serverconsole. Faalt dat,
dan is de uitwijk de Curl-probe, die al uitgecommentarieerd in `config` staat.

### 6.4 `Not enough arguments for Smokeping::cgi`
In 2.8.x heeft `Smokeping::cgi` een `($$)`-prototype: configpad **en** een CGI-object.
De CGI moet dus zijn:
```perl
use CGI;
my $q = CGI->new;
Smokeping::cgi("/home/container/config", $q);
```

### 6.5 Interface volledig ongestyled
`basepage.html` verwijst relatief naar `css/smokeping-screen.css` en `js/*`. Het
Debian-pakket levert die bestanden niet op een pad dat wij vonden, dus alles gaf 404.
Opgelost door ze uit de upstream release te halen:
```bash
cd /home/container/www && curl -sL \
  https://github.com/oetiker/SmokePing/archive/refs/tags/2.8.2.tar.gz \
  | tar xz --strip-components=2 SmokePing-2.8.2/htdocs/css SmokePing-2.8.2/htdocs/js
```
Zit nu in `start.sh` (bij ontbreken) én in de Dockerfile (bij build).

### 6.6 `Fontconfig error: No writable cache directories`
`mod_cgi` geeft het script een uitgeklede omgeving zonder `HOME`. RRDtool tekent zijn
labels via fontconfig, dat een schrijfbare cachemap wil. Opgelost met een
`setenv.add-environment`-blok in `lighttpd.conf` (`HOME`, `XDG_CACHE_HOME`, `TMPDIR`)
plus de map `tmp/fontcache`.

**Dit is de meest waarschijnlijke oorzaak van de "lege" grafieken.**

### 6.7 `Section 'X' does not exist`
Geen bug. Oude links uit de browsergeschiedenis naar groepen die niet in de huidige
`config` staan. Gewoon naar de root van de site gaan.

### 6.8 Onschadelijke ruis in de console
- `setlogsock(): type='unix': path not available` — geen syslog-socket in de
  container, met opzet; logging gaat naar de console omdat `syslogfacility` niet is gezet
- `Use of uninitialized value ...` — upstream-warnings van SmokePing zelf

---

## 7. Belangrijkste valkuil

**Het JSON-bestand is niet de egg.** Het install-script leeft in de
panel-database. Een nieuwe image pullen of een nieuwe server maken verandert niets
aan het install-script; dat moet je expliciet bijwerken in Admin → Nests → egg →
Installation, of door de egg te verwijderen en opnieuw te importeren (kan alleen
zonder gekoppelde servers). Daarna Reinstall Server.

Dit heeft meerdere rondes gekost — controleer bij twijfel of het scriptveld in het
panel het woord `setenv` bevat.

## 8. Nog te doen

1. Egg in het panel bijwerken naar de laatste versie, server reinstallen
2. `fping -c1 1.1.1.1` draaien en het resultaat vaststellen
3. Als ICMP niet mag: Curl-probe activeren en de bestaande RRD's van omgezette
   targets weggooien (anders meng je ICMP- en HTTP-metingen)
4. GitHub billing oplossen zodat Actions de image weer bouwt
5. Optioneel: image opnieuw bouwen zodat de css/js erin zitten en de runtime-download
   overbodig wordt
6. Optioneel: label `SmokePing (Debian 12)` klopt niet meer, de yolks-basis is
   inmiddels Debian 13 (trixie)

## 9. Handige commando's

```bash
# in de serverconsole
fping -c1 1.1.1.1
ls -l /home/container/data/Internet/
rrdtool lastupdate /home/container/data/Internet/Cloudflare.rrd
smokeping --config=/home/container/config --check

# originele template terugzetten
cp /opt/smokeping-defaults/basepage.html /home/container/basepage.html
```
