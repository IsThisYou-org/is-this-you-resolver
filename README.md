# Is This You resolver

Docker Compose for the Is This You resolver and DNS-over-HTTPS stack. It runs the published container images. It does not build them.

| Service | Image | Role |
| --- | --- | --- |
| `handshake-full-node` | `jamesstevens/handshake-full-node` | Handshake full node |
| `handshake-volume-resolver` | `jamesstevens/handshake-volume-resolver` | dnsdist, HAProxy, root_proxy, and one BIND process with two views |
| `dnsflsk` | `jamesstevens/flask-doh` | JSON DoH / API |
| `easy-nginx` (profile `tls`) | `jamesstevens/easy-nginx` | Optional TLS termination |

BIND is not its own container. The views in the image are `recursive` (resolver) and `root` (ICANN root secondary).

The Ethereum / Alchemy path is not part of this stack.

## Traffic path

HTTPS arrives at optional easy-nginx, which terminates TLS and proxies plain HTTP:

- `api.isthisyou.org` → `dnsflsk` port 80 (JSON API)
- `doh.isthisyou.org` → `handshake-volume-resolver` port 80 (binary DoH)

`dnsflsk` sends the query to dnsdist over UDP/53, and over TCP/53 when the answer is truncated. Binary DoH is served by dnsdist. HAProxy sits in front of it because nginx cannot speak to dnsdist directly. Classic DNS on port 53 goes straight to dnsdist.

dnsdist splits on the RD flag. RD=1 goes to the BIND `recursive` view. RD=0 goes to root_proxy. Root-zone queries from the recursive view also go to root_proxy.

root_proxy asks the BIND `root` view first. When that answer is NXDOMAIN, it sends the same query to the Handshake full node and returns that answer. An NXDOMAIN for an RD=0 query on the root zone therefore carries the Handshake SOA.

## Requirements

- Docker Engine with Compose v2
- About 45 to 50 GB free for the Handshake chain, on the filesystem that holds the full-node data directory (below). The other services use very little disk
- UDP and TCP port 53 free on the host
- For the `tls` profile, TCP ports 80 and 443, and a PEM (below)

The resolver transfers the ICANN root zone from the primaries built into the image, so the host needs outbound DNS to those servers. The full node needs outbound access to the Handshake network. Client networks often block or intercept outbound port 53; HTTPS / DoH is the reliable way to query this service.

## Run

From this directory:

```bash
docker compose up -d
```

That starts the full node, the resolver, and dnsflsk. easy-nginx stays off.

Handshake names wait until the full node has caught up with the chain. ICANN answers wait until BIND has loaded the root zone.

To stop, without deleting the chain data:

```bash
docker compose down
```

That leaves the host directory in place. Deleting that directory makes the node fetch the chain again.

The default directory is `./handshake-full-node/data`. To put the chain on another disk, set `HSD_DATA` to an absolute host path. Compose reads it when it interpolates the bind mount. It is not an environment variable inside the container.

```bash
HSD_DATA=/srv/handshake docker compose up -d
```

Logs:

```bash
docker compose logs -f handshake-full-node
docker compose logs -f dnsflsk
```

`handshake-volume-resolver` writes syslog to `logs/messages` inside its data directory (on the host: `handshake-volume-resolver/data/logs/messages`). easy-nginx does the same under `easy-nginx/logs/`.

A local check of classic DNS, once the root zone is loaded:

```bash
dig @127.0.0.1 example.com A
```

A local check of the JSON API, from inside dnsflsk (the image includes `curl`):

```bash
docker compose exec dnsflsk curl -fsS 'http://127.0.0.1/dns/api/v1.0/resolv?name=example.com'
```

## Public endpoints

- JSON API: <https://api.isthisyou.org/>. The parameters `servers` and `rd` exist only on this API. `servers` is the name used by dnsflsk.
- Binary DoH: <https://doh.isthisyou.org/>. Those parameters are not accepted here.
- Classic DNS on the same host names, port 53, TCP and UDP.

dnsflsk also answers `/dns/api/v1.0/resolv` and `/resolv`, as described in its own README.

## TLS profile

Enable easy-nginx only when this stack should terminate TLS. When the host already terminates TLS, leave the profile off and send HTTP to:

- `dnsflsk` port 80 for `api.isthisyou.org`
- `handshake-volume-resolver` port 80 for `doh.isthisyou.org`

Those two HTTP ports are on the Compose network `resolver`. They are not published on the host, so they do not clash with easy-nginx. Attach a host proxy to that network, or publish the ports in a local override.

Start TLS with this stack:

```bash
docker compose --profile tls up -d
```

### Config file

easy-nginx reads `/opt/data/etc/nginx.input`. Compose mounts the host directory `easy-nginx/` at `/opt/data`, so the file in this repository is `easy-nginx/etc/nginx.input`.

Each line is space-separated:

```text
P <cert-name> <destination-URL> <host-name> [host-name...]
```

`P` means proxy. The shipped lines are:

```text
P isthisyou.org http://dnsflsk/ api.isthisyou.org
P isthisyou.org http://handshake-volume-resolver/ doh.isthisyou.org
```

The destinations are the Compose service names. Both containers listen on port 80, which is what an `http://` URL with no port uses. The cert name `isthisyou.org` is the basename of the PEM.

### PEM

Put one file at:

```text
easy-nginx/pems/isthisyou.org.pem
```

Inside the container that path is `/opt/data/pems/isthisyou.org.pem`. The file holds the private key and the certificate together. easy-nginx uses that same file as both the certificate and the key. It must be valid for `api.isthisyou.org` and `doh.isthisyou.org`.

Supply `easy-nginx/pems/<domain>.pem` on the host. The cert-name field is `<domain>`. Do not commit these files. Each one contains the private key. This repository ignores `easy-nginx/pems/*.pem` and any `*.pem` elsewhere. The `pems` directory in git contains only `.gitkeep`.

Place the file before the first start of the profile. If you add it later:

```bash
docker compose --profile tls restart easy-nginx
```

The same host directory is scratch space. The container creates directories there, including `logs` and `htdocs`.

The easy-nginx README does not describe this layout. The paths match its `dkrun` mount of a host directory at `/opt/data`, and the paths in `bin/remake_conf`, `bin/update_pems`, and `bin/start_syslogd`. See NOTES.md.

`dkrun` in that repository sets `NGINX_PLAIN_WEB=Y`, which serves files from `/opt/data/htdocs` and does not load the proxy map. This compose file leaves that variable unset, so the proxy map is used. No easy-nginx variables are set here, because that README lists none.

## Volumes

| Mount | Container path | Purpose |
| --- | --- | --- |
| `./handshake-full-node/data`, or `HSD_DATA` | `/opt/data` | Handshake chain data, in `hsd/` on that host directory. Allow 45 to 50 GB. The container also writes `logs/` here. |
| `./handshake-volume-resolver/data` | `/opt/data` | Resolver state and syslog. Optional authoritative zones go in `auth_zones/`, one file per zone, file name equal to the zone name. Create that directory only when it contains zone files. An empty directory makes this image try to load a zone named `*`. |
| `./easy-nginx` | `/opt/data` | easy-nginx scratch space, `etc/nginx.input`, and `pems/`. Profile `tls` only. |

The latest handshake-full-node code stores the chain in `/opt/data/hsd` (`bin/run_hsd` on branch `dev`, commit `0a4ad9f`) and changes that directory's owner to the `hsd` user. `rd_bit_proxy` listens on port 53. hsd itself still uses a separate authoritative port (root zone only) and a recursive port; the proxy is how both are reached, split on the RD bit. Default branch `master` at `ec445d7` is an older tree and still documents `/opt/hsd-data`.

## Environment

Set here, so the services can reach each other:

| Variable | Service | Value | Why |
| --- | --- | --- | --- |
| `HSD_MASTERS` | `handshake-volume-resolver` | `172.30.53.10` | Required list of Handshake nodes. `172.30.53.10` is `handshake-full-node`. No port is set, so root_proxy uses port 53, where `rd_bit_proxy` listens. |
| `DOH_SERVERS` | `dnsflsk` | `172.30.53.20` | Resolver address. `172.30.53.20` is `handshake-volume-resolver`, whose dnsdist listens on port 53. Without this, dnsflsk uses Google's resolvers. |

The network `resolver` is `172.30.53.0/24`. That subnet sits inside the default BIND allow list in the image (`172.16.0.0/12`, from `bin/start_named`). root_proxy accepts numeric addresses only. The component repositories do not define a Docker network; the subnet is recorded in NOTES.md.

Left at the image defaults, and documented by those READMEs:

- `HSD_LOG_LEVEL` (default `info`) and `HSD_ADDITIONAL_PARAMS` (default `--no-sig0 --no-wallet`, plus the migrate flags in `run_hsd`). The latest code's syslog script reads `SYSLOG_SERVER` and `SYSLOG_STDOUT`; with both unset, logs go to `/opt/data/logs/messages` in the full-node data directory.
- `DOH_SESSIONS` (dnsflsk worker count)
- `DNSDIST_STATS_KEY` and `DNSDIST_STATS_ACL` — set both to open dnsdist metrics on port 8083. This file does not choose a password. `ETH_MASTERS` is not set.

## Ports on the host

| Published | Goes to |
| --- | --- |
| `53/tcp`, `53/udp` | dnsdist in `handshake-volume-resolver` |
| `127.0.0.1:9119` | BIND metrics |
| `127.0.0.1:8405` | HAProxy metrics |
| `127.0.0.1:8083` | dnsdist metrics, only after the two stats variables above are set |
| `80`, `443` | easy-nginx, profile `tls` only |

Containers use `restart: unless-stopped`. The component `dkrun` scripts are interactive and do not set a restart policy.

## Gaps

NOTES.md lists anything this file could not take from the component repositories, and the files that were checked.
