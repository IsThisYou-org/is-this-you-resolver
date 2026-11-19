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

The dnsflsk README links the older Hub image `jamesstevens/doh`. This stack uses `jamesstevens/flask-doh`.

## Traffic path

HTTPS arrives at optional easy-nginx, which terminates TLS and proxies plain HTTP:

- `api.isthisyou.org` → `dnsflsk` port 80 (JSON API)
- `doh.isthisyou.org` → `handshake-volume-resolver` port 80 (binary DoH)

`dnsflsk` sends the query to dnsdist over UDP/53, and over TCP/53 when the answer is truncated. Binary DoH is served by dnsdist. HAProxy sits in front of it because nginx cannot speak to dnsdist directly. HAProxy forwards to dnsdist with `proto h2` on `127.0.0.1:800`. Classic DNS on port 53 goes straight to dnsdist.

dnsdist splits on the RD flag. RD=1 goes to the BIND `recursive` view. RD=0 goes to root_proxy. Root-zone queries from the recursive view also go to root_proxy.

root_proxy asks the BIND `root` view first. When that answer is NXDOMAIN, it sends the same query to the Handshake full node and returns that answer. An NXDOMAIN for an RD=0 query on the root zone therefore carries the Handshake SOA.

## Requirements

- Docker Engine with Compose v2
- About 45 to 50 GB free for the Handshake chain, on the filesystem that holds the data directory (below). The other services use very little disk
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

That leaves the host directories in place. Deleting `data/handshake-full-node` (or the same directory under `DATA_DIR`) makes the node fetch the chain again.

Host state for every container that needs a disk lives under one directory, `./data` by default:

| Host path | Container | Mounted at |
| --- | --- | --- |
| `data/handshake-full-node` | `handshake-full-node` | `/opt/data` (chain in `hsd/`) |
| `data/handshake-volume-resolver` | `handshake-volume-resolver` | `/opt/data` |
| `data/easy-nginx` | `easy-nginx` | `/opt/data` |

To put that whole tree on another disk, set `DATA_DIR` to an absolute host path. Compose reads it when it interpolates the bind mounts. It is not an environment variable inside a container. Copy the committed `data/` tree to the new root first, so `easy-nginx/etc/nginx.input` is still present, then add your PEMs there.

```bash
DATA_DIR=/srv/isthisyou docker compose up -d
```

Logs:

```bash
docker compose logs -f handshake-full-node
docker compose logs -f dnsflsk
```

`handshake-volume-resolver` writes syslog to `logs/messages` inside its data directory (on the host: `data/handshake-volume-resolver/logs/messages`). easy-nginx does the same under `data/easy-nginx/logs/`.

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

Only the JSON API (dnsflsk) accepts UTF-8 names in `name=` and converts them to Punycode. Binary DoH and port 53 need Punycode first. Clients should convert the name themselves, and should not use an ICANN-strict IDN converter, because Handshake names often contain Unicode that ICANN rules reject. Emoji names are common. The published `jamesstevens/flask-doh:latest` (17 November 2025) predates that change, so UTF-8 `name=` works only after the image is rebuilt and pushed.

## TLS profile

Enable easy-nginx only when this stack should terminate TLS on the host. A cloud-provider TLS shedder, or any other proxy on the instance, uses the plain HTTP ports that are published on every `docker compose up`, whether or not this profile is on:

- host port 8080 → dnsflsk (`flask-doh`) port 80, the JSON API
- host port 8081 → `handshake-volume-resolver` port 80, binary DoH

Both are plain HTTP. Limit them to the external shedder, with a security group or the equivalent.

Start TLS with this stack:

```bash
docker compose --profile tls up -d
```

### Config file

easy-nginx reads `/opt/data/etc/nginx.input`. Compose mounts `data/easy-nginx/` at `/opt/data`, so the file in this repository is `data/easy-nginx/etc/nginx.input`.

Each line is space-separated:

```text
P <cert-name> <destination-URL> <host-name> [host-name...]
```

`P` means proxy. The shipped lines are:

```text
P isthisyou.org http://172.30.53.30/ api.isthisyou.org
P isthisyou.org http://172.30.53.20/ doh.isthisyou.org
```

`172.30.53.30` is dnsflsk (the `flask-doh` image) and `172.30.53.20` is `handshake-volume-resolver`. Both listen on port 80, which is what an `http://` URL with no port uses. These addresses are the static addresses in `compose.yaml`. If those addresses change, change these lines to match. The cert name `isthisyou.org` is the basename of the PEM.

### PEM

Put one file at:

```text
data/easy-nginx/pems/isthisyou.org.pem
```

Inside the container that path is `/opt/data/pems/isthisyou.org.pem`. The file holds the private key and the certificate together. easy-nginx uses that same file as both the certificate and the key. It must be valid for `api.isthisyou.org` and `doh.isthisyou.org`.

Supply `data/easy-nginx/pems/<domain>.pem` on the host. The cert-name field is `<domain>`. Do not commit these files. Each one contains the private key. This repository ignores `data/easy-nginx/pems/*.pem` and any `*.pem` elsewhere. The `pems` directory in git contains only `.gitkeep`.

Place the file before the first start of the profile. If you add it later:

```bash
docker compose --profile tls restart easy-nginx
```

The same host directory is scratch space. The container creates directories there, including `logs` and `htdocs`.

`dkrun` in that repository sets `NGINX_PLAIN_WEB=Y`, which serves files from `/opt/data/htdocs` and does not load the proxy map. This compose file leaves that variable unset, so the proxy map is used. No easy-nginx variables are set here, because that README lists none.

## Volumes

| Mount under `./data` (or `DATA_DIR`) | Container path | Purpose |
| --- | --- | --- |
| `handshake-full-node/` | `/opt/data` | Handshake chain data, in `hsd/` inside that directory. Allow 45 to 50 GB. The container also writes `logs/` here. |
| `handshake-volume-resolver/` | `/opt/data` | Resolver state and syslog. Optional authoritative zones go in `auth_zones/`, one file per zone, file name equal to the zone name. handshake-volume-resolver PR #13 (merge `e7ccf5b`, 11 November 2026) fixed `start_named` so an empty `/opt/data/auth_zones` no longer loads a zone named `*`. The fix reaches Docker Hub `latest` only after that image is rebuilt and pushed. Until the published image includes the fix, create `auth_zones` only when it contains zone files. |
| `easy-nginx/` | `/opt/data` | easy-nginx scratch space, `etc/nginx.input`, and `pems/`. Profile `tls` only. |

handshake-full-node stores the chain in `/opt/data/hsd` (`bin/run_hsd`; `master` and `dev` are both `42957c8`) and changes that directory's owner to the `hsd` user. `rd_bit_proxy` listens on port 53. hsd itself still uses a separate authoritative port (root zone only) and a recursive port; the proxy is how both are reached, split on the RD bit.

## Environment

Set here, so the services can reach each other:

| Variable | Service | Value | Why |
| --- | --- | --- | --- |
| `HSD_MASTERS` | `handshake-volume-resolver` | `172.30.53.10` | Required list of Handshake nodes. `172.30.53.10` is `handshake-full-node`. No port is set, so root_proxy uses port 53, where `rd_bit_proxy` listens. |
| `DOH_SERVERS` | `dnsflsk` | `172.30.53.20` | Resolver address. `172.30.53.20` is `handshake-volume-resolver`, whose dnsdist listens on port 53. Without this, dnsflsk uses Google's resolvers. |

The network `resolver` is `172.30.53.0/24`. root_proxy (`HSD_MASTERS`) accepts numeric IPv4 addresses with an optional `:port` only, not host names. That is why the network uses fixed addresses in this subnet, which also sits inside the image's default BIND allow list (`172.16.0.0/12`). Assigned addresses: `.10` full node, `.20` volume resolver, `.30` dnsflsk, `.40` easy-nginx.

Left at the image defaults, and documented by those READMEs:

- `HSD_LOG_LEVEL` (default `info`) and `HSD_ADDITIONAL_PARAMS` (default `--no-sig0 --no-wallet`, plus the migrate flags in `run_hsd`). The handshake-full-node syslog script reads `SYSLOG_SERVER` and `SYSLOG_STDOUT`; with both unset, logs go to `/opt/data/logs/messages` (`data/handshake-full-node/logs/messages` on the host).
- `DOH_SESSIONS` (dnsflsk worker count)
- `DNSDIST_STATS_KEY` and `DNSDIST_STATS_ACL` — set both to open dnsdist metrics on port 8083. This file does not choose a password. `ETH_MASTERS` is not set.

## Ports on the host

| Published | Goes to |
| --- | --- |
| `53/tcp`, `53/udp` | dnsdist in `handshake-volume-resolver` |
| `8080` | dnsflsk (`flask-doh`) port 80, JSON API. Plain HTTP. Published on every `docker compose up`. |
| `8081` | `handshake-volume-resolver` port 80, binary DoH. Plain HTTP. Published on every `docker compose up`. |
| `127.0.0.1:9119` | BIND metrics |
| `127.0.0.1:8405` | HAProxy metrics |
| `127.0.0.1:8083` | dnsdist metrics, only after the two stats variables above are set |
| `80`, `443` | easy-nginx, profile `tls` only |

Host ports 8080 and 8081 stay published when the `tls` profile is on. easy-nginx still uses host ports 80 and 443. Limit 8080 and 8081 to the external TLS shedder, with a security group or the equivalent.

Handshake peer port 12038 is not published by `compose.yaml`. The node still syncs over outbound connections. Without inbound 12038 it is a private node, not a public one. To run a public node, publish `12038/tcp` on `handshake-full-node` and open it in the firewall.

Containers use `restart: unless-stopped`. The component `dkrun` scripts are interactive and do not set a restart policy.
