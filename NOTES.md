# Notes and gaps

Inspected on 11 November 2026, default-branch tips:

| Repository | Commit | What was read |
| --- | --- | --- |
| [james-stevens/easy-nginx](https://github.com/james-stevens/easy-nginx) | `260a788c4658bd788b664170a2fab9532801961d` | `README.md`, `Dockerfile`, `dkrun`, `dkmk`, `list`, `push_to_docker`, `nginx/nginx.conf`, `nginx/plain.conf`, `nginx/nolog.conf`, `bin/start_nginx`, `bin/set_conf`, `bin/remake_conf`, `bin/update_pems`, `bin/start_syslogd` |
| [james-stevens/dnsflsk](https://github.com/james-stevens/dnsflsk) | `b7bb1c538af3f0650b1b711cf05802f845ce6eda` | `README.md`, `Dockerfile`, `dkrun`, `dkmk`, `list`, `push_to_docker`, `etc/nginx.conf`, `etc/inittab`, `bin/start_wsgi`, `python/dnsflsk.py`, `python/resolv.py` |
| [james-stevens/handshake-volume-resolver](https://github.com/james-stevens/handshake-volume-resolver) | `7f10baaf875a5b796b1bba423568a0c2880c1cc6` | `README.md`, `Dockerfile`, `dkrun`, `dkmk`, `list`, `inittab`, `etc/named.conf`, `etc/haproxy.cfg`, `etc/with_eth.inc`, `bin/start_named`, `bin/start_dnsdist`, `bin/start_root_proxy`, `bin/start_syslogd`, `bin/start_exporter`, `root_proxy/root_proxy.c`, `root_proxy/liball.c` |
| [james-stevens/handshake-full-node](https://github.com/james-stevens/handshake-full-node) | `dev` `0a4ad9f438606ab4a0858c01fed0b2e963395577` (6 November 2025). Default branch `master` is the older `ec445d7c35272041cec29c3904c36f7454201ac1` | `README.md`, `Dockerfile`, `dkrun`, `bin/run_hsd`, `bin/start_syslogd`, `inittab`, and `hsd-8.0.0/hsd/lib/protocol/networks.js` for the default peer port |

Docker Hub confirmed the four image names this file uses. None of the repositories contains a Compose file. There is no published image tag that this repository can pin: `push_to_docker` tags `jamesstevens/<name>` and a date tag.

## Filled from the component code

These values are not in a Compose example upstream. They are the published run flags and listen ports.

- Images: `jamesstevens/easy-nginx`, `jamesstevens/flask-doh`, `jamesstevens/handshake-volume-resolver`, `jamesstevens/handshake-full-node`. Each `list` file is the local image name; `push_to_docker` pushes `jamesstevens/<that name>`.
- Service names match the repository names. The diagram label `dns-flask` is this `dnsflsk` repository. Its image name is `flask-doh`.
- `--read-only` is set on every service because every `dkrun` sets it.
- `handshake-volume-resolver` memory limit `1g` and `nofile` 15000 match its `dkrun`.
- Volume path `/opt/data` matches `dkrun` for easy-nginx, handshake-volume-resolver, and the latest handshake-full-node. That full-node code keeps the chain in `/opt/data/hsd`.
- `HSD_MASTERS` and `DOH_SERVERS` are the README variables those two images use to find a neighbour.

## easy-nginx layout

The easy-nginx README is a single line and does not mention `/opt/data`, the config file, PEM files, or environment variables.

The layout used here is the one described for this stack, and it matches the scripts:

- Host directory mounted at `/opt/data` (`dkrun` mounts a host directory there).
- Config file `/opt/data/etc/nginx.input` (`bin/remake_conf`).
- PEM files `/opt/data/pems/<cert-name>.pem` (`bin/update_pems` and `dkrun`). `bin/remake_conf` points both `ssl_certificate` and `ssl_certificate_key` at that one file.
- Scratch directories such as `logs` under `/opt/data` (`bin/start_syslogd`, `bin/start_nginx`).

`bin/set_conf` also honours `NGINX_NO_LOGGING` and `NGINX_PLAIN_WEB`. Neither name appears in the README, so Compose does not set them. `dkrun` sets `NGINX_PLAIN_WEB=Y`, which selects `plain.conf` and ignores `nginx.input`. Setting that here would turn the TLS proxy off.

Git `bin/remake_conf` also accepts `X`, `W`, `R`, and a `|` upstream form. The published image's copy of that script accepts `X`, `P`, and `R` (the `W` line is in git commit `260a788`, after the image was built). The file shipped here uses only the `P` line specified for this stack. The cert name `isthisyou.org` is the cert name from those example lines. No repository records the production PEM or a different basename. The operator supplies `data/easy-nginx/pems/isthisyou.org.pem`.

No certificate material is in any of the four repositories, or in this one. Operators place `data/easy-nginx/pems/<domain>.pem` on the host. `.gitignore` ignores `data/easy-nginx/pems/*.pem` and `*.pem` anywhere in the tree. The committed `pems` directory contains only `.gitkeep`. The proxy map `data/easy-nginx/etc/nginx.input` is not secret and is committed. Its destinations are the fixed Compose addresses `http://172.30.53.30/` (dnsflsk, image `flask-doh`, `api.isthisyou.org`) and `http://172.30.53.20/` (`handshake-volume-resolver`, `doh.isthisyou.org`). Those addresses are set in `compose.yaml` and the map must stay in step with them.

## handshake-full-node

The latest code is branch `dev` at `0a4ad9f` (6 November 2025). `bin/run_hsd` stores the chain in `/opt/data/hsd` and changes that directory's owner to the `hsd` user. `dkrun` mounts a host directory at `/opt/data`. Docker Hub `latest` (build `20251106.1538`) is this code.

`rd_bit_proxy` listens on port 53, so both hsd services are reached through that one port. hsd itself still uses two ports: authoritative, root zone only, on 5349, and recursive on 5350. The preferred split is the RD bit. `inittab` runs `rd_bit_proxy -s 0.0.0.0:53 -a 127.0.0.1 -r 127.0.0.1`. With no port on `-a` or `-r`, the binary uses 5349 and 5350.

Compose bind-mounts three host directories, all under `./data` by default, each at `/opt/data` in its container. The chain is therefore at `data/handshake-full-node/hsd` on the host and `/opt/data/hsd` in the container. Set `DATA_DIR` to another absolute path to place that whole tree, including the chain, on a larger disk. `DATA_DIR` is Compose interpolation, not a variable inside a container. There is no named Docker volume. `HSD_MASTERS` is `172.30.53.10` with no port, so root_proxy uses port 53.

Default branch `master` at `ec445d7` is an older tree. It listens on 153 and 253 and stores data in `/opt/hsd-data`.

`run_hsd` reads `HSD_LOG_LEVEL` (default `info`) and `HSD_ADDITIONAL_PARAMS` (default `--no-sig0 --no-wallet`). `start_syslogd` reads `SYSLOG_SERVER` and `SYSLOG_STDOUT`, which the latest README also documents. With both unset, syslog goes to `/opt/data/logs/messages`.

## Addresses

`HSD_MASTERS` is documented as a semi-colon-separated list of Handshake nodes. `root_proxy` parses each entry with `decode_net_addr` (`root_proxy/liball.c`), which accepts an IPv4 address and an optional `:port`, and rejects host names. With no port, `root_proxy.c` uses port 53, which is where `rd_bit_proxy` listens.

`DOH_SERVERS` is documented as a comma-separated list of IP addresses. `172.30.53.20` is the resolver container, where dnsdist calls `addLocal` on port 53 (`bin/start_dnsdist`).

The subnet `172.30.53.0/24` is not in any component repository. It was chosen because:

- those two variables need stable numeric addresses
- `172.30.53.0/24` is inside `172.16.0.0/12`, which is part of the default BIND ACL written by `bin/start_named` when `ALLOWED_SUBNETS` is unset (`192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`, and `127.0.0.0/8`)

`ALLOWED_SUBNETS` is read by `bin/start_named` and is not listed in the volume-resolver README, so it is not set. dnsdist's own ACL is `0.0.0.0/0` in `bin/start_dnsdist`, and it queries BIND from inside the container.

Assigned addresses: `.10` full node, `.20` volume resolver, `.30` dnsflsk, `.40` easy-nginx.

## Behaviour left as the images ship it

HAProxy in `etc/haproxy.cfg` listens on port 80 and forwards to `127.0.0.1:800` with `proto h2`. dnsdist listens for DoH on `0.0.0.0:800`. The functional diagram labels that hop HTTP/0.9. The image was not altered.

`dkrun` for the volume resolver also publishes port 8081 and sets `ETH_MASTERS`, `RESOLVER_PEERS`, `SYSLOG_STDOUT`, `DNSDIST_STATS_KEY`, and `DNSDIST_STATS_ACL`. The inittab does not start `start_eth_limo` or `start_eth_redirect`. Port 8081 and `ETH_MASTERS` are omitted. `RESOLVER_PEERS`, `SYSLOG_STDOUT`, `SYSLOG_SERVER`, `REQUIRE_COOKIES`, and `WITH_BIND_V6` appear in scripts and are absent from the README table, so they are not set. `REQUIRE_COOKIES` defaults to `yes` inside `bin/start_named`. With `SYSLOG_STDOUT` unset, syslog goes to `/opt/data/logs/messages`.

dnsdist metrics (port 8083) stay closed until both `DNSDIST_STATS_KEY` and `DNSDIST_STATS_ACL` are set. The README requires both. No password is invented here. The port is still published on `127.0.0.1`, as `dkrun` publishes it on a loopback address.

`DOH_SYSLOG_SERVER` is read by `python/dnsflsk.py` and is not in the dnsflsk README, so it is not set.

The dnsflsk README header links `jamesstevens/doh` on Docker Hub (last pushed in 2020). The production section, `list`, and `dkrun` all use `flask-doh`, which is the image named in Compose.

`bin/run_hsd` listens for Handshake peers on the `hsd` default port 12038 (`networks.js`, `main.port`). The full-node README and `dkrun` do not publish that port, so this file does not either. Outbound connections from the container still work. The README does not say whether inbound peers are required for the chain to catch up.

JSON queries use the parameter name `servers` (`python/dnsflsk.py`). There is no `server` parameter in that code.

`restart: unless-stopped` is not present in any `dkrun`. It is set so a reboot brings the stack back. The images already respawn their own processes from inittab.

`bin/start_named` treats every file in `/opt/data/auth_zones` as a zone. With an empty directory the shell leaves the glob as `*`, and BIND then tries to load a zone of that name. This repository does not create `auth_zones` until an operator adds zone files.

On start, dnsdist in `jamesstevens/handshake-volume-resolver:latest` logs PowerDNS advisory `powerdns-advisory-for-dnsdist-2026-02`. This repository does not rebuild that image.
