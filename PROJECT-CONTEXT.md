# SmokePing op Pterodactyl — projectcontext

Overdrachtsdocument. Alles wat is gebouwd, waarom het zo is gebouwd, wat er is
misgegaan en wat er nog open staat.

Laatst bijgewerkt: 19 augustus 2026. Alles hieronder is gemeten op een draaiende
container, niet afgeleid.

---

## 1. Doel

SmokePing (netwerklatency-monitoring, RRD-grafieken) draaien als Pterodactyl-egg,
zodat er per klant een instantie aangemaakt kan worden zonder handwerk. Het is
bedoeld als verhuurbaar product: elke klant een eigen container, een subdomain via
een Caddy-proxy en een SSL-certificaat.

## 2. Status

Werkt en is geverifieerd:

- Image staat op `ghcr.io/yannickbm/smokeping:latest`, gebouwd door GitHub Actions
- **fping 5.3 uit source**, meet echte ICMP zonder capabilities (§6.3)
- Grafieken renderen: 0 fontconfig-fouten, PNG's van 25–28 KB (§6.6)
- RRD's vullen zich met echte waarden — gemeten 3,4 / 10,7 / 21,3 ms mediaan
- Console is stil: geen valse ICMP-melding, geen perl-warnings (§6.9, §6.10)
- Geen onverklaarde herstarts: 0 crashregels over meerdere meetvensters

Nog te doen: zie §8.

## 2b. Testserver

| | |
|---|---|
| Panel | `client.hostmybot.net` |
| Server | `smokeping`, id 361, identifier `7ca5beca` |
| Node | game001 (id 24) — geen vrije allocatie meer |
| Allocatie | 84.247.164.16:6666 |
| Limieten | 50% CPU · 256 MB RAM · 512 MB disk |
| Eigenaar | yannick@hostmybot.net (user id 2) |
| Egg | id 42, nest `website` (id 6) |
| Proxy | Caddy op 217.148.167.13 zet een subdomain naar IP:poort |

Verbruik in rust: ~34 MB RAM van 256, CPU rond 0,02%, 9 MB disk van 512. De
Basic-staffel (256 MB) is daarmee ruim bemeten voor een handvol targets.

---

## 3. Repo en image

- Repo: https://github.com/yannickbm/smokeping
- Image: `ghcr.io/yannickbm/smokeping:latest` (GHCR, public)
- Actions bouwt bij elke wijziging aan `Dockerfile` of de workflow

Met de hand kan ook:

```bash
docker build -t ghcr.io/yannickbm/smokeping:latest .
docker push ghcr.io/yannickbm/smokeping:latest
```

Doe dat liefst niet. Een handmatige push vanaf een persoonlijk account maakt een
package dat níet aan de repo hangt, en dan mag de workflow er niet meer op
schrijven — zie §6.11.

## 4. Bestanden

| Bestand | Rol |
|---|---|
| `Dockerfile` | Runtime-image. Basis `ghcr.io/parkervcp/yolks:debian`, plus smokeping, rrdtool, lighttpd, perl-modules en **fping uit source** (§6.3) |
| `egg-smokeping.json` | De egg. Bevat het install-script als JSON-string |
| `install-script.sh` | Hetzelfde install-script als los bestand, voor copy-paste in het panel |
| `lighttpd.conf` | Webserverconfig (wordt door het install-script geschreven; los bestand voor handmatige fixes) |
| `basepage.html` | Alternatieve HTML-template met inline CSS. **Niet in gebruik** |
| `README-smokeping.md` | Klantdocumentatie, wordt als `README.md` in de serverfolder gezet |
| `build-image.yml` | GitHub Actions workflow |
| `setup-repo.sh` | Eenmalig hulpscript om de repo te vullen |

`egg-smokeping.json` wordt **gegenereerd** uit `install-script.sh`: pas altijd het
losse script aan en bed het daarna in de JSON in, nooit andersom.

## 5. Hoe het draait

Install-container (`debian:bookworm-slim`, als root) schrijft naar `/mnt/server`:
`config`, `start.sh`, `lighttpd.conf`, `www/smokeping.cgi`, `README.md` en de
lege mappen `data/`, `cache/`, `run/`, `logs/`, `tmp/fontcache/`, `www/`.

Runtime-container draait `bash /home/container/start.sh`, dat:
1. ontbrekende templates uit `/opt/smokeping-defaults` kopieert
2. css/js downloadt van GitHub als `www/css` ontbreekt (§6.5)
3. `cgiurl` schrijft uit `PUBLIC_URL`, of uit de allocatie als die leeg is (§6.12)
4. een ICMP-zelftest draait en het resultaat naar `icmp-test.txt` schrijft (§6.9)
5. `smokeping --check` draait; bij een fout stopt hij met de reden
6. de daemon met `--nodaemon` en lighttpd met `-D` start, beide in de achtergrond
7. `SmokePing is up` echoot — dit is de done-regex waar Wings op wacht
8. via `wait -n` afsluit zodra één van beide processen stopt

Stopcommando is `^^C` (SIGINT), afgevangen door een trap in `start.sh`.

Variabelen: `OWNER`, `CONTACT`, `PUBLIC_URL`, `ASSET_VERSION` (2.8.2).

---

## 6. Opgeloste problemen

### 6.1 apt-installatie in het install-script werkt niet
Pterodactyl bewaart alleen `/mnt/server` uit de install-container. Systeempakketten
verdwijnen. Daarom een eigen image.

### 6.2 `bash: /mnt/install/install.sh: Permission denied`
De install-container stond op onze eigen image, en die eindigt op `USER container`.
Die gebruiker mag het door Wings geschreven install-script niet lezen. Opgelost door
`debian:bookworm-slim` te gebruiken (draait als root).

Gevolg: het install-script kan niet bij `/opt/smokeping-defaults` uit de image. Het
kopiëren van templates gebeurt daarom in `start.sh`.

### 6.3 100% packet loss op alle targets — fping, niet het netwerk

De oorspronkelijke aanname was dat `CAP_NET_RAW` het probleem was. Dat klopte niet.

Gemeten in de draaiende container (uid 999, gid 987):

| Test | Uitkomst |
|---|---|
| `SOCK_RAW` ICMP-socket | geweigerd — verwacht, Wings dropt `CAP_NET_RAW` |
| `SOCK_DGRAM` ICMP-socket | **aangemaakt zonder fout** |
| Handmatige echo naar 172.18.0.1, 1.1.1.1, 8.8.8.8 | **alle drie antwoord binnen 3s** |
| `ping_group_range` | `0 2147483647` — dekt gid 987 |
| `getcap /usr/bin/fping` | leeg — caps correct gestript |
| `fping -c1 1.1.1.1` | 100% loss |
| `fping -C3 -q -B1 -r1 -i10 1.1.1.1` (SmokePing's aanroep) | `- - -` |

ICMP werkte dus, de capabilities-truc werkte, alleen fping niet.

Bij een `SOCK_DGRAM` ICMP-socket vervangt de kernel het echo-**ID** door het
poortnummer van de socket, zodat replies naar de juiste socket kunnen. Bewezen:

```
verzonden ICMP echo id = 0xBEEF
ontvangen  ICMP echo id = 0x004A
```

fping 5.1 filtert replies op het ID dat het zélf schreef en gooit dus alles weg.
Upstream opgelost in **fping 5.2** ("Fix running in unprivileged mode", #248,
2024-04-21). Debian 13 levert 5.1-1, van februari 2022.

**Fix:** de Dockerfile bouwt fping uit source (`FPING_VERSION`, standaard 5.3) in
een builder-stage. De `COPY` staat bewust *na* `apt-get install`, want het
`smokeping`-pakket trekt Debian's fping mee en zou de eigen build overschrijven.
De build faalt hard als er alsnog een fping < 5.2 in de image belandt.

Na de omzetting: `1.1.1.1 : 64 bytes, 6.96 ms, 0% loss`, `fping: Version 5.3`.

### 6.4 `Not enough arguments for Smokeping::cgi`
In 2.8.x heeft `Smokeping::cgi` een `($$)`-prototype: configpad **en** een CGI-object.

```perl
use CGI;
my $q = CGI->new;
Smokeping::cgi("/home/container/config", $q);
```

### 6.5 Interface volledig ongestyled
Het Debian-pakket levert de css/js niet op een pad dat wij vonden. Ze komen nu uit
de upstream release, zowel in de Dockerfile als in `start.sh` bij ontbreken.

### 6.6 `Fontconfig error: No writable cache directories`
`mod_cgi` geeft het script een uitgeklede omgeving zonder `HOME`. RRDtool tekent
labels via fontconfig, dat een schrijfbare cachemap wil. Opgelost met
`setenv.add-environment` in `lighttpd.conf` plus de map `tmp/fontcache`.

Geverifieerd met een request vanuit de container:

```
HTTP/1.1 200 OK          Server: lighttpd/1.4.79
fontconfig-fouten: 0
cache/Internet/Cloudflare_last_34560000.png   28228 bytes
```

Het renderen was nooit stuk. Dat de grafieken leeg leken kwam door §6.3 — er was
geen data. Twee losse problemen die op hetzelfde leken.

### 6.7 `Section 'X' does not exist`
Geen bug. Oude links uit de browsergeschiedenis. Ga naar de root van de site.

### 6.8 Onschadelijke ruis
- `setlogsock(): type='unix': path not available` — geen syslog-socket, met opzet
- `Use of uninitialized value ...` — upstream-warnings van SmokePing 2.8.2 zelf,
  in `Smokeping.pm` regel 1434/1527/1697 en `Graphs.pm` regel 28. Ze staan bij
  iedereen en raken metingen noch grafieken. Zie §6.10 voor waar ze nu heen gaan.

### 6.9 De serverconsole accepteert geen commando's
Het hoofdproces is `bash start.sh`, en bash die een script uitvoert leest geen
stdin. Alles wat je in de console typt verdwijnt. Getest via de API: commando
geaccepteerd (HTTP 204), niets gebeurd.

Diagnostiek moet via `start.sh` of de file-API. Daarom draait er een ICMP-zelftest
bij elke boot die naar `icmp-test.txt` schrijft.

**Valkuil in die zelftest, zelf ingelopen:** de eerste versie zocht naar `1 alive`
in fping's uitvoer. Dat print fping alleen bij een lijst hosts; met `-c1` op één
host komt er `xmt/rcv/%loss = 1/1/0%`. De test meldde daardoor bij elke boot dat
ICMP kapot was terwijl alles werkte. Hij controleert nu op `fping exit=0`.

Les: een zelftest die vals alarm geeft is erger dan geen zelftest. Dan leert
iedereen de melding negeren, inclusief de keer dat hij klopt.

### 6.10 Perl-warnings vulden de console
Elke pageview leverde ruim tien regels §6.8-ruis in de Pterodactyl-console. Met een
proxy die elke vijf minuten langskomt is dat een doorlopende stroom, en een klant
die dat ziet denkt dat zijn dienst stuk is.

`server.errorlog` lost dit **niet** op — dat is lighttpd's eigen log. Stderr van een
CGI-proces valt onder `server.breakagelog`. Beide staan nu in `lighttpd.conf` en
schrijven naar `logs/`. Geverifieerd: 0 warnings in de console over zeven minuten,
inclusief een volledige poll-cyclus.

### 6.11 `denied: permission_denied: write_package`
De workflow mocht niet naar GHCR pushen. Het package had geen `repository`-veld:
het was ooit met de hand gepusht vanaf het persoonlijke account, dus het hoorde bij
de gebruiker en niet bij de repo. `packages: write` in de workflow dekt alleen
repo-eigen packages.

Eenmalig opgelost via Package settings → Manage Actions access → repo toevoegen met
rol Write. De Dockerfile draagt nu ook `org.opencontainers.image.source`, waardoor
GHCR het package voortaan zelf aan de repo koppelt.

Ander struikelblok bij diezelfde build: `debian:*-slim` bevat geen `netbase`, dus
`/etc/protocols` ontbreekt. fping doet `getprotobyname("icmp")` bij het opstarten en
sterft zonder dat bestand met `icmp: unknown protocol`, exit 4 — zelfs bij `-v`.
`netbase` zit nu in beide stages.

### 6.12 `AUTO_CGIURL` was verkeerd om voor dit product
`AUTO_CGIURL` stond standaard op 1 en herschreef `cgiurl` bij elke boot naar
`http://IP:PORT`. Achter een proxy is dat altijd fout, en zet je het met de hand
goed, dan is het na de eerstvolgende herstart weer weg — zonder melding.

Omdat elke klant een subdomain met SSL krijgt, was de standaardwaarde optimaal voor
het geval dat nooit voorkomt. Vervangen door **`PUBLIC_URL`**: vul het publieke
adres in en `cgiurl` wordt daar bij elke boot naartoe geschreven. Leeg laten geeft
het oude `IP:PORT`-gedrag voor gebruik zonder proxy.

---

## 7. Belangrijkste valkuil

**Het JSON-bestand is niet de egg.** Het install-script leeft in de
panel-database. Een nieuwe image pullen of een nieuwe server maken verandert daar
niets aan; dat moet expliciet in Admin → Nests → egg → Installation, of door de egg
te verwijderen en opnieuw te importeren (kan alleen zonder gekoppelde servers).
Daarna Reinstall Server.

Dit is geen theorie: op 19 augustus stond in het panel nog de versie zonder
`setenv`, terwijl de fix al in de werkkopie zat.

De Application API kan eggs alleen *lezen*, niet schrijven. Bijwerken is altijd
handwerk in de admin-interface. Een reinstall triggeren kan wél via de API.

Let op na een reinstall: `config` blijft staan (met opzet), dus wijzigingen die je
dáárin had gemaakt overleven — inclusief eventuele verwijzingen naar dingen die
niet meer bestaan.

## 8. Nog te doen

1. **Toegang tot de webinterface.** De allocatie is publiek bereikbaar op
   `http://IP:PORT/`, zonder wachtwoord en zonder TLS. De Caddy-proxy zet er een
   naam en een certificaat voor, maar sluit de oorspronkelijke poort niet af. Wie
   het IP en de poort kent, ziet de grafieken van die klant. Voor een betaald
   product wil je dat afdichten — bijvoorbeeld met een IP-allowlist in
   `lighttpd.conf` die alleen de proxy toelaat, of basic auth
2. Per klant `PUBLIC_URL` invullen bij het aanmaken van de server
3. Optioneel: `debian:bookworm-slim` als install-container bijtrekken naar trixie,
   puur voor consistentie — bookworm werkt en is bewezen

## 9. Handige commando's

De serverconsole neemt geen input aan (§6.9). Alles gaat via de file-API of een
tijdelijke regel in `start.sh`.

```bash
# ICMP-zelftest ophalen
curl -s -H "Authorization: Bearer $CLIENT_KEY" -H "Accept: application/json" \
  "https://client.hostmybot.net/api/client/servers/7ca5beca/files/contents?file=%2Ficmp-test.txt"
```

```bash
# bestand terugschrijven
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

De live console lezen kan via de websocket: haal een token op bij
`/api/client/servers/{id}/websocket`, verbind met `origin` op de panel-URL, stuur
`{"event":"auth","args":[token]}` en daarna `{"event":"send logs","args":[null]}`.
Dat geeft de recente historie plus alles wat er live bijkomt — de enige manier om
console-uitvoer te zien zonder de webinterface.

Regels om tijdelijk in `start.sh` te zetten:

```bash
fping -c1 1.1.1.1
rrdtool lastupdate /home/container/data/Internet/Cloudflare.rrd
smokeping --config=/home/container/config --check
```

Zet ze **niet** in de achtergrond. `start.sh` eindigt op `wait -n`, dus een
subshell die klaar is telt als "een child is gestopt" en sluit de server af.
