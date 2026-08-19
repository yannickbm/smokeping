# SmokePing op Pterodactyl — projectcontext

Overdrachtsdocument. Alles wat is gebouwd, waarom het zo is gebouwd, wat er is
misgegaan en wat er nog open staat.

Laatst bijgewerkt: 19 augustus 2026, na een meetsessie op een draaiende container.

---

## 1. Doel

SmokePing (netwerklatency-monitoring, RRD-grafieken) draaien als Pterodactyl-egg,
zodat er per server een instantie aangemaakt kan worden zonder handwerk.

## 2. Status

Werkt en is gemeten:
- Image bouwt en staat op `ghcr.io/yannickbm/smokeping:latest` (public)
- Egg installeert, server start, daemon meet 3 targets
- Webinterface bereikbaar op de allocatie
- **Grafieken renderen correct.** De fontconfig-fix is bevestigd, niet vermoed:
  0 fontconfig-fouten en PNG's van 25–28 KB in `cache/` (zie §6.6)

Open:
- **fping 5.1 uit Debian kan geen unprivileged ICMP.** Dit is de reden dat alle
  targets 100% loss geven. Oorzaak volledig vastgesteld, fix zit in de Dockerfile,
  maar de image moet nog gebouwd en gepusht worden (zie §6.3)
- GitHub Actions ligt stil door een billing-lock; de image is daarom met de hand
  gebouwd en gepusht

## 2b. Testserver

| | |
|---|---|
| Panel | `client.hostmybot.net` |
| Server | `smokeping`, id 361, identifier `7ca5beca` |
| Node | game001 (id 24) |
| Allocatie | 84.247.164.16:6666 |
| Limieten | 50% CPU · 256 MB RAM · 512 MB disk |
| Eigenaar | yannick@hostmybot.net (user id 2) |
| Egg | id 42, nest `website` (id 6) |

Op deze server zijn `lighttpd.conf` en `start.sh` met de hand bijgewerkt naar de
laatste versie. Het **egg in het panel is dat nog niet** — zie §7.

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
| `Dockerfile` | Runtime-image. Basis `ghcr.io/parkervcp/yolks:debian`, plus smokeping, rrdtool, lighttpd, perl-modules en **fping uit source** (§6.3) |
| `egg-smokeping.json` | De egg. Bevat het install-script als JSON-string |
| `install-script.sh` | Hetzelfde install-script als los bestand, voor copy-paste in het panel |
| `lighttpd.conf` | Webserverconfig (wordt door het install-script geschreven; los bestand voor handmatige fixes) |
| `basepage.html` | Alternatieve HTML-template met inline CSS. **Niet in gebruik** — de originele Debian-template plus upstream css/js geeft een beter resultaat |
| `README-smokeping.md` | Engelstalige gebruikersuitleg, wordt door het install-script als `README.md` in de serverfolder gezet |
| `build-image.yml` | GitHub Actions workflow |
| `setup-repo.sh` | Eenmalig hulpscript om de repo te vullen |

`egg-smokeping.json` wordt gegenereerd uit `install-script.sh`: pas altijd het
losse script aan en zet het daarna in de JSON, nooit andersom.

## 5. Hoe het draait

Install-container (`debian:bookworm-slim`, als root) schrijft naar `/mnt/server`:
`config`, `start.sh`, `lighttpd.conf`, `www/smokeping.cgi`, `README.md` en de
lege mappen `data/`, `cache/`, `run/`, `tmp/fontcache/`, `www/`.

Runtime-container draait `bash /home/container/start.sh`, dat:
1. ontbrekende templates uit `/opt/smokeping-defaults` kopieert
2. css/js downloadt van GitHub als `www/css` ontbreekt (zie §6.5)
3. `cgiurl` herschrijft naar `IP:PORT` als `AUTO_CGIURL=1`
4. een ICMP-zelftest draait en het resultaat naar `icmp-test.txt` schrijft (§6.9)
5. `smokeping --check` draait; bij een fout stopt hij met de reden
6. de daemon met `--nodaemon` en lighttpd met `-D` start, beide in de achtergrond
7. `SmokePing is up` echoot — dit is de done-regex waar Wings op wacht
8. via `wait -n` de boel afsluit zodra één van beide processen stopt

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

### 6.3 100% packet loss op alle targets — fping, niet het netwerk

Dit heeft de langste tijd op een verkeerd spoor gestaan. De oorspronkelijke
aanname was dat `CAP_NET_RAW` het probleem was. Dat klopt niet.

Wat er is gemeten in de draaiende container (uid 999, gid 987):

| Test | Uitkomst |
|---|---|
| `SOCK_RAW` ICMP-socket | geweigerd — verwacht, Wings dropt `CAP_NET_RAW` |
| `SOCK_DGRAM` ICMP-socket | **aangemaakt zonder fout** |
| Handmatige echo naar 172.18.0.1, 1.1.1.1, 8.8.8.8 | **alle drie antwoord binnen 3s** |
| `ping_group_range` | `0 2147483647` — dekt gid 987 |
| `getcap /usr/bin/fping` | leeg — caps correct gestript |
| `fping -c1 1.1.1.1` | 100% loss |
| `fping -C3 -q -B1 -r1 -i10 1.1.1.1` (SmokePing's aanroep) | `- - -` |

ICMP werkt dus gewoon. De capabilities-truc werkt ook gewoon. Alleen fping niet.

De oorzaak zit in hoe unprivileged ICMP op Linux werkt. Bij een `SOCK_DGRAM`
ICMP-socket vervangt de kernel het echo-**ID** in het pakket door het poortnummer
van de socket — zo weet hij later naar welke socket een reply moet. Bewezen met
een eigen echo:

```
verzonden ICMP echo id = 0xBEEF
ontvangen  ICMP echo id = 0x004A
```

fping 5.1 filtert binnenkomende replies op het ID dat het zélf heeft geschreven,
ziet nooit een match, en rapporteert alles als verloren. Upstream heeft dit
opgelost in **fping 5.2** ("Fix running in unprivileged mode", issue #248,
release 2024-04-21). Debian 13 (trixie) levert 5.1-1, van februari 2022.

**Fix:** de Dockerfile bouwt fping uit source (`FPING_VERSION`, standaard 5.3) in
een aparte builder-stage. De `COPY` staat bewust *na* `apt-get install`, want het
`smokeping`-pakket trekt Debian's fping mee en zou de eigen build overschrijven.
De build faalt hard als er alsnog een fping < 5.2 in de image belandt.

De Curl-probe (uitgecommentarieerd aanwezig in `config`) blijft de uitwijk voor
omgevingen waar ICMP écht geblokkeerd is. Let op: die meet HTTP-round-trip, geen
ICMP, en je moet de bestaande RRD's van omgezette targets weggooien — anders meng
je twee soorten metingen in één grafiek.

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

### 6.6 `Fontconfig error: No writable cache directories` — opgelost en bevestigd
`mod_cgi` geeft het script een uitgeklede omgeving zonder `HOME`. RRDtool tekent zijn
labels via fontconfig, dat een schrijfbare cachemap wil. Opgelost met een
`setenv.add-environment`-blok in `lighttpd.conf` (`HOME`, `XDG_CACHE_HOME`, `TMPDIR`)
plus de map `tmp/fontcache`.

Geverifieerd op de draaiende server met een request vanuit de container zelf:

```
HTTP/1.1 200 OK          Server: lighttpd/1.4.79
fontconfig-fouten in de uitvoer: 0
cache/Internet/Cloudflare_last_34560000.png   28228 bytes
cache/Internet/Cloudflare_last_864000.png     26004 bytes
```

Grafieken van 25–28 KB zijn normaal gerenderde RRD-plots. Het renderen was dus
nooit stuk. Dat de grafieken er leeg uitzagen kwam door §6.3: er ís geen meetdata.
Twee losse problemen die op hetzelfde leken — dat heeft de diagnose vertraagd.

### 6.7 `Section 'X' does not exist`
Geen bug. Oude links uit de browsergeschiedenis naar groepen die niet in de huidige
`config` staan. Gewoon naar de root van de site gaan.

### 6.8 Onschadelijke ruis in de console
- `setlogsock(): type='unix': path not available` — geen syslog-socket in de
  container, met opzet; logging gaat naar de console omdat `syslogfacility` niet is gezet
- `Use of uninitialized value ...` — upstream-warnings van SmokePing zelf

### 6.9 De serverconsole accepteert geen commando's
Het hoofdproces is `bash /home/container/start.sh`. Bash die een script uitvoert
leest geen stdin, dus alles wat je in de console typt verdwijnt. Getest via de
API: het commando wordt geaccepteerd (HTTP 204) en er gebeurt niets.

Diagnostiek moet dus via `start.sh` of via de file-API. Daarom draait er nu een
ICMP-zelftest bij elke boot, die naar `icmp-test.txt` schrijft én in de console
waarschuwt. Zonder die test is stille 100% loss niet te onderscheiden van een
werkende meting — precies de valkuil waar §6.3 in is gelopen.

---

## 7. Belangrijkste valkuil

**Het JSON-bestand is niet de egg.** Het install-script leeft in de
panel-database. Een nieuwe image pullen of een nieuwe server maken verandert niets
aan het install-script; dat moet je expliciet bijwerken in Admin → Nests → egg →
Installation, of door de egg te verwijderen en opnieuw te importeren (kan alleen
zonder gekoppelde servers). Daarna Reinstall Server.

Dit is geen theorie: op 19 augustus stond in het panel nog steeds de versie
zonder `setenv`, terwijl de fix al in de werkkopie zat. Controleer bij twijfel of
het scriptveld in het panel het woord `setenv` bevat.

De Application API kan eggs alleen *lezen*, niet schrijven. Bijwerken is dus altijd
handwerk in de admin-interface. Een reinstall triggeren kan wél via de API.

## 8. Nog te doen

1. Image opnieuw bouwen en pushen zodat fping 5.3 erin zit — dit is wat de
   100% loss oplost. De Dockerfile is er klaar voor
2. Egg in het panel bijwerken naar `install-script.sh`, server reinstallen
3. Na de reinstall `icmp-test.txt` lezen; daar hoort nu `1 alive` in te staan
4. GitHub billing oplossen zodat Actions de image weer bouwt
5. Optioneel: `debian:bookworm-slim` als install-container bijtrekken naar trixie,
   puur voor consistentie — bookworm werkt prima en is bewezen

## 9. Handige commando's

De serverconsole neemt geen input aan (§6.9). Alles hieronder gaat via de
file-API of via een tijdelijke regel in `start.sh`.

```bash
# resultaat van de ICMP-zelftest ophalen (client API)
curl -s -H "Authorization: Bearer $CLIENT_KEY" -H "Accept: application/json" \
  "https://client.hostmybot.net/api/client/servers/7ca5beca/files/contents?file=%2Ficmp-test.txt"
```

```bash
# een bestand terugschrijven
curl -s -X POST -H "Authorization: Bearer $CLIENT_KEY" -H "Content-Type: text/plain" \
  --data-binary @lighttpd.conf \
  "https://client.hostmybot.net/api/client/servers/7ca5beca/files/write?file=%2Flighttpd.conf"
```

```bash
# herstarten
curl -s -X POST -H "Authorization: Bearer $CLIENT_KEY" -H "Content-Type: application/json" \
  -d '{"signal":"restart"}' \
  "https://client.hostmybot.net/api/client/servers/7ca5beca/power"
```

Regels om tijdelijk in `start.sh` te zetten als je iets wilt weten:

```bash
fping -c1 1.1.1.1
ls -l /home/container/data/Internet/
rrdtool lastupdate /home/container/data/Internet/Cloudflare.rrd
smokeping --config=/home/container/config --check
cp /opt/smokeping-defaults/basepage.html /home/container/basepage.html
```

Let op bij zulke regels: zet ze niet in de achtergrond. `start.sh` eindigt op
`wait -n`, dus een subshell die klaar is telt als "een child is gestopt" en de
server sluit zichzelf af.
