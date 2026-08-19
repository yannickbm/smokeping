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
- `AUTO_CGIURL` – `1` schrijft bij elke start de `cgiurl` in de config naar
  `http://IP:PORT/smokeping.cgi`. Zet op `0` als je achter een reverse proxy zit
  en de regel zelf wilt beheren.

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
└── www/smokeping.cgi ← de webinterface
```

Openen op `http://IP:PORT/`. Targets toevoegen doe je onderin `config` onder
`*** Targets ***`, daarna server herstarten.

## Belangrijk: ICMP in een Pterodactyl-container

Wings dropt `CAP_NET_RAW`, dus fping kan geen raw sockets openen. De image lost dit
op door de file-capabilities/setuid van fping te strippen, waarna fping 5.x
terugvalt op *unprivileged ICMP datagram sockets*. Dat werkt zolang
`net.ipv4.ping_group_range` in de container de GID van de container-user omvat —
Docker zet die standaard op `0 2147483647`, dus meestal gaat dit vanzelf goed.

Test het in de console van de server:

```bash
fping -c1 1.1.1.1
```

Krijg je `Operation not permitted` of 100% loss op álle targets, dan zijn er twee
opties:

1. Op de node in `/etc/docker/daemon.json` toestaan, of in `config.yml` van Wings
   de sysctl meegeven (per node-config, vereist herstart van Wings + de container).
2. Geen ICMP gebruiken. In de config staat een uitgecommentarieerde `Curl`-probe
   klaar: haal `#` weg bij het `+ Curl`-blok en geef targets `probe = Curl` mee.
   Die meet HTTP-round-trip en heeft geen speciale rechten nodig.

## Overige aandachtspunten

- Geen HTTPS en geen authenticatie. Zet er een reverse proxy voor als de instantie
  publiek bereikbaar is (en dan `AUTO_CGIURL = 0` + `cgiurl` handmatig zetten).
- Alerts via e-mail werken alleen als er een werkende `sendmail`/`mailhost` is;
  standaard is dat niet zo in de container.
- Stopcommando is `^^C` (SIGINT); `start.sh` vangt dat af en sluit beide processen
  netjes af.
- Herinstalleren overschrijft `start.sh`, `lighttpd.conf` en `www/smokeping.cgi`,
  maar laat `config` en `data/` met rust.
