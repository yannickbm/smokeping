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

Set the `AUTO_CGIURL` variable to `0` in the server's Startup tab, otherwise the
`cgiurl` line is rewritten to the raw IP and port on every start. Then set it
yourself in `*** General ***`:

```
cgiurl = https://smokeping.example.com/smokeping.cgi
```

Point the proxy at the node's IP and the server's allocated port. Nothing else is
needed — the graph images are served from the same port under `/cache/`.

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
