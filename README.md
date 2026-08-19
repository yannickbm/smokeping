# SmokePing egg voor Pterodactyl

Drie bestanden:

| Bestand | Wat het is |
|---|---|
| `egg-smokeping.json` | De egg, importeer je in het panel |
| `Dockerfile` | De image die de egg gebruikt (zelf bouwen + pushen) |
| `README.md` | Dit bestand |

## Waarom een eigen image?

Pterodactyl draait install-scripts in een aparte container waarvan alleen
`/mnt/server` blijft bestaan. Een `apt-get install smokeping` in het install-script
verdwijnt dus weer. SmokePing heeft Perl + RRDtool-bindings + fping nodig, en die
moeten in de image zitten.

## 1. Repo klaarzetten

Zet in https://github.com/yannickbm/smokeping deze indeling neer:

```
smokeping/
├── Dockerfile
├── egg-smokeping.json
└── .github/workflows/build-image.yml
```

Push naar `main` en GitHub Actions bouwt de image en publiceert hem als
`ghcr.io/yannickbm/smokeping:latest`. Daarna eenmalig het package op **public**
zetten: GitHub-profiel -> Packages -> smokeping -> Package settings ->
Change visibility -> Public. Doe je dat niet, dan kan Wings de image niet pullen.

Zelf bouwen hoeft niet, maar kan wel:

```bash
docker build -t ghcr.io/yannickbm/smokeping:latest .
docker push ghcr.io/yannickbm/smokeping:latest
```

## 2. Egg importeren

Admin → Nests → Import Egg → `egg-smokeping.json`. Daarna een server aanmaken met
één allocatie (die poort wordt de webinterface).

Variabelen:

- `OWNER` – naam die in de UI staat
- `CONTACT` – contactadres / alert-ontvanger
- `PUBLIC_URL` – het adres dat mensen intypen, bijvoorbeeld
  `https://smokeping.klant.nl`. Zonder slash op het eind en zonder
  `/smokeping.cgi`; dat wordt erbij gezet. Bij elke start wordt `cgiurl` hiernaar
  herschreven, dus hij kan niet verlopen. Leeg laten voor directe toegang op de
  allocatie — dan vult hij `http://IP:PORT` in.

## 3. Wat er op de server komt te staan

```
/home/container/
├── config            ← je SmokePing-config (wordt nooit overschreven)
├── basepage.html     ← HTML-template
├── lighttpd.conf     ← webserver (wordt bij herinstall overschreven)
├── start.sh          ← startscript (idem)
├── data/             ← RRD-bestanden
├── cache/            ← gegenereerde grafieken
├── run/              ← pidfile
├── logs/             ← lighttpd-log en stderr van de CGI
└── www/smokeping.cgi ← de webinterface
```

Openen op `http://IP:PORT/`. Targets toevoegen doe je onderin `config` onder
`*** Targets ***`, daarna server herstarten.

## Belangrijk: ICMP in een Pterodactyl-container

Wings dropt `CAP_NET_RAW`, dus fping kan geen raw sockets openen. De image strijkt
de file-capabilities en het setuid-bit van fping glad, waarna fping terugvalt op
*unprivileged ICMP datagram sockets*. Die zijn toegestaan zolang
`net.ipv4.ping_group_range` de GID van de container-user omvat — Docker zet die
standaard op `0 2147483647`, dus dat gaat vanzelf goed.

**Maar dat is niet genoeg.** Bij zo'n socket vervangt de kernel het ICMP echo-ID
in het pakket door het poortnummer van de socket, zodat hij replies naar de juiste
socket kan routeren. fping vóór 5.2 filtert binnenkomende replies op het ID dat het
zelf schreef, ziet daardoor nooit een match, en meldt 100% loss terwijl er niets
mis is met het netwerk. Upstream heeft dit opgelost in 5.2 ("Fix running in
unprivileged mode", #248). Debian 13 levert nog 5.1.

Daarom bouwt de Dockerfile fping uit source (`FPING_VERSION`, standaard 5.3) in
plaats van het Debian-pakket te gebruiken. Wil je een andere versie, bouw dan met
`--build-arg FPING_VERSION=x.y`. De build faalt bewust als er alsnog een fping
onder 5.2 in de image belandt.

`start.sh` draait bij elke boot een ICMP-zelftest en schrijft die naar
`icmp-test.txt` in de serverfolder. Staat daar `fping exit=0` in, dan werkt het.
Zo niet, dan waarschuwt de console er ook over — stille 100% loss is anders niet van een
werkende meting te onderscheiden.

Let op: je kunt dit **niet** testen door `fping -c1 1.1.1.1` in de serverconsole te
typen. Het hoofdproces is `bash start.sh`, en bash die een script draait leest geen
stdin, dus console-input verdwijnt zonder foutmelding.

Blijft ICMP falen met een fping ≥ 5.2, dan blokkeert je node het echt. Twee opties:

1. Op de node in `/etc/docker/daemon.json` toestaan, of in `config.yml` van Wings
   de sysctl meegeven (per node-config, vereist herstart van Wings + de container).
2. Geen ICMP gebruiken. In de config staat een uitgecommentarieerde `Curl`-probe
   klaar: haal `#` weg bij het `+ Curl`-blok en geef targets `probe = Curl` mee.
   Die meet HTTP-round-trip en heeft geen speciale rechten nodig. Gooi wel de
   bestaande RRD's van omgezette targets weg, anders meng je ICMP- en HTTP-data.

## Overige aandachtspunten

- Geen HTTPS en geen authenticatie in de container zelf. Zet er een reverse proxy
  voor en vul `PUBLIC_URL` in.
- **De allocatie blijft daarnaast gewoon bereikbaar op `http://IP:PORT/`.** Een
  proxy geeft er een naam en een certificaat bij, maar sluit de oorspronkelijke
  poort niet af. Wie het IP en de poort kent, ziet de grafieken — zonder
  certificaat en zonder wachtwoord. Wil je dat niet, beperk de poort dan op de
  node zelf.
- Alerts via e-mail werken alleen als er een werkende `sendmail`/`mailhost` is;
  standaard is dat niet zo in de container.
- Stopcommando is `^^C` (SIGINT); `start.sh` vangt dat af en sluit beide processen
  netjes af.
- Herinstalleren overschrijft `start.sh`, `lighttpd.conf` en `www/smokeping.cgi`,
  maar laat `config` en `data/` met rust.
