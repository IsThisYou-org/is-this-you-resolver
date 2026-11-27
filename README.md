# Is This You resolver

Docker Compose for the Is This You resolver and DNS-over-HTTPS stack. It runs published container images. It does not build them. The definition of `jamesstevens/is-this-you-icann-resolver` is in `is-this-you-icann-resolver/` so that directory can move into its own repository. This compose file only names the image.

| Service | Image | Profiles | Role |
| --- | --- | --- | --- |
| `handshake-full-node` | `jamesstevens/handshake-full-node` | `handshake` | Handshake full node |
| `ethereum-dns-gateway` | `jamesstevens/ethereum-dns-gateway` | `handshake` | ENS names, UDP port 53 |
| `handshake-volume-resolver` | `jamesstevens/handshake-volume-resolver` | `handshake` | dnsdist, HAProxy, root_proxy, and one BIND process with two views |
| `is-this-you-icann-resolver` | `jamesstevens/is-this-you-icann-resolver` | `icann` | Local ICANN root (Unbound) |
| `json-doh-proxy` | `jamesstevens/json-doh-proxy` | `json`, `icann`, `handshake` | JSON DoH / API |
| `easy-nginx` | `jamesstevens/easy-nginx` | `tls` | Optional TLS termination |

BIND is not its own container. The views in the image are `recursive` (resolver) and `root` (ICANN root secondary).

`.eth` is answered by `ethereum-dns-gateway`. The Hub image must be the Python build from PR #2 (branch `cursor/python-ens-gateway-8047`, commit `55b89a7` or later). This file does not build that image.

The `json-doh-proxy` README is at <https://github.com/james-stevens/json-doh-proxy>.

## Modes

Compose starts every service that has no profile, and also the services in the profiles you name. The three modes must not run together, so none of their services is left without a profile. `docker compose up` with no profile starts nothing. What `docker compose up` used to start, the full Handshake stack, is now `--profile handshake`.

Use one of `json`, `icann` or `handshake`. Add `tls` when this stack should terminate TLS.

| Mode | Included | Handshake | Cost | Suits | Trust |
| --- | --- | --- | --- | --- | --- |
| `json` | `json-doh-proxy`. easy-nginx as well, if you also enable `tls` | No | Lightest. No chain and no local copy of the root | A small site that wants the JSON API for ICANN names. Not a large site: with no `LOCAL_ICANN_ROOT`, `servers=icann-root` sends `rd=0` `do=1` queries straight to the roots `d`, `f`, `j` and `k` | The client's own validation |
| `icann` | `is-this-you-icann-resolver` and `json-doh-proxy`. easy-nginx as well, with `tls` | No | The root zone, a few tens of megabytes. No Handshake chain | Sites that want their own ICANN root and DNSSEC validation, without Handshake | DNSSEC, using the root trust anchor in `is-this-you-icann-resolver` |
| `handshake` | The current stack: `handshake-full-node`, `ethereum-dns-gateway`, `handshake-volume-resolver` and `json-doh-proxy`. easy-nginx as well, with `tls` | Yes | About 45 to 50 GB for the Handshake chain | Operators who serve Handshake names | The trust anchor is the blockchain. Anyone validating independently needs their own full node / stack |

```bash
docker compose --profile json up -d
docker compose --profile icann up -d
docker compose --profile handshake up -d
```

TLS as well, with any one mode:

```bash
docker compose --profile handshake --profile tls up -d
```

`json` leaves `LOCAL_ICANN_ROOT` unset and sets `DOH_SERVERS` to `https://dns.google/dns-query,https://cloudflare-dns.com/dns-query`. Ordinary queries go to Google and Cloudflare over DoH. `servers=icann-root` is handled inside json-doh-proxy, which this repository does not build.

`icann` points json-doh-proxy at `172.30.53.60`. `DOH_SERVERS` and `LOCAL_ICANN_ROOT` are both that address. `is-this-you-icann-resolver` runs Unbound from Alpine 3.24. It holds `.` as an `auth-zone`, transferred from the ICANN transfer servers `192.0.32.132` and `192.0.47.132` and from `c` and `f` root, with `zonemd-check`, `for-downstream` and `for-upstream` on, and DNSSEC validation with the root trust anchor shipped in the image. `rd=0` queries for data in that zone (`. SOA`, `com. DS`) are authoritative. A query for a name below a delegation is a referral from this copy of the root. Until `jamesstevens/is-this-you-icann-resolver` is published, build it locally with `is-this-you-icann-resolver/dkmk`. This repository does not push the image.

`handshake` keeps the previous environment. `DOH_SERVERS` is `172.30.53.20`. `LOCAL_ICANN_ROOT` is unset.

The JSON API container is always named `json-doh-proxy`. Compose needs a separate service key per mode because the environment differs. The keys are `json-doh-proxy` (`handshake`), `json-doh-proxy-json` (`json`) and `json-doh-proxy-icann` (`icann`). `docker logs json-doh-proxy` follows the container, whichever mode is running.

## Traffic path

The path below is the `handshake` profile.

HTTPS arrives at optional easy-nginx, which terminates TLS and proxies plain HTTP:

- `api.isthisyou.org` → `json-doh-proxy` port 80 (JSON API)
- `doh.isthisyou.org` → `handshake-volume-resolver` port 80 (binary DoH)

`json-doh-proxy` sends the query to dnsdist over UDP/53, and over TCP/53 when the answer is truncated. Binary DoH is served by dnsdist. HAProxy sits in front of it because nginx cannot speak to dnsdist directly. HAProxy forwards to dnsdist with `proto h2` on `127.0.0.1:800`. Classic DNS on port 53 goes straight to dnsdist.

dnsdist splits on the RD flag. RD=1 goes to the BIND `recursive` view. RD=0 goes to root_proxy. Root-zone queries from the recursive view also go to root_proxy.

root_proxy asks the BIND `root` view first. When that answer is NXDOMAIN, it sends the same query to the Handshake full node and returns that answer. An NXDOMAIN for an RD=0 query on the root zone therefore carries the Handshake SOA.

## .eth

Port 53, binary DoH, and the JSON API all arrive at dnsdist.

dnsdist sends RD=1 to the BIND `recursive` view. That view has a static-stub for `eth.` when `ETH_MASTERS` is set. The stub asks `172.30.53.50` on UDP port 53. That address is `ethereum-dns-gateway`.

The gateway treats every name it is asked as an ENS name.

RD=0 does not use the gateway. Those queries go to root_proxy.

The gateway does not listen on TCP. BIND asks it over UDP. If an answer is too big, BIND may retry on TCP, and that retry fails. WALLET, PTR, URI, and TXT stay small, so they stay on UDP.

`ETH_MASTERS` is already in the volume-resolver image. No change to that image is required for `.eth`.

handshake-volume-resolver PR #15 is not on `master` yet (`60ed633` on `dev`). It deletes the `forever` zone from `etc/with_eth.inc`. Until that image is rebuilt and pushed, `ETH_MASTERS` also sends `forever.` to the gateway.

## Requirements

- Docker Engine with Compose v2
- For the `handshake` profile, about 45 to 50 GB free for the Handshake chain, on the filesystem that holds the data directory (below). The `json` and `icann` profiles use very little disk
- For the `handshake` and `icann` profiles, UDP and TCP port 53 free on the host. The `json` profile does not publish port 53
- For the `tls` profile, TCP ports 80 and 443, and a PEM (below)

`handshake-volume-resolver` and `is-this-you-icann-resolver` each transfer the ICANN root zone, so the host needs outbound DNS to those servers. The full node needs outbound access to the Handshake network. The gateway needs outbound HTTPS to its Ethereum RPC host. With both RPC variables empty, that host is `ethereum.publicnode.com`. Client networks often block or intercept outbound port 53; HTTPS / DoH is the reliable way to query this service.

## Run

From this directory, pass one mode profile. The commands are in [Modes](#modes). `docker compose up -d` on its own starts nothing.

With `--profile handshake`, the full node, the resolver, and json-doh-proxy start. easy-nginx stays off unless you also pass `--profile tls`.

Handshake names wait until the full node has caught up with the chain. ICANN answers in that profile wait until BIND has loaded the root zone. In the `icann` profile they wait until Unbound has loaded its `auth-zone`.

To stop, without deleting the chain data:

```bash
docker compose down
```

That leaves the host directories in place. Deleting `data/handshake-full-node` (or the same directory under `DATA_DIR`) makes the node fetch the chain again.

Host state for every container that needs a disk lives under one directory, `./data` by default:

| Host path | Container | Mounted at |
| --- | --- | --- |
| `data/handshake-full-node` | `handshake-full-node` | `/opt/data` (chain in `hsd/`) |
| `data/ethereum-dns-gateway` | `ethereum-dns-gateway` | `/opt/data` |
| `data/handshake-volume-resolver` | `handshake-volume-resolver` | `/opt/data` |
| `data/is-this-you-icann-resolver` | `is-this-you-icann-resolver` | `/opt/data` |
| `data/easy-nginx` | `easy-nginx` | `/opt/data` |

To put that whole tree on another disk, set `DATA_DIR` to an absolute host path. Compose reads it when it interpolates the bind mounts. It is not an environment variable inside a container. Copy the committed `data/` tree to the new root first, so `easy-nginx/etc/nginx.input` is still present, then add your PEMs there.

```bash
DATA_DIR=/srv/isthisyou docker compose --profile handshake up -d
```

Logs:

```bash
docker compose --profile handshake logs -f handshake-full-node
docker compose --profile handshake logs -f json-doh-proxy
```

`handshake-volume-resolver` writes syslog to `logs/messages` inside its data directory (on the host: `data/handshake-volume-resolver/logs/messages`). `ethereum-dns-gateway`, `is-this-you-icann-resolver` and easy-nginx do the same under their own `data/` directories. `SYSLOG_STDOUT` is unset on the gateway and on `is-this-you-icann-resolver`, so they match the other services.

A local check of classic DNS, once the root zone is loaded:

```bash
dig @127.0.0.1 example.com A
dig @127.0.0.1 bitsofcode.eth WALLET
```

The second check needs the Python gateway image from PR #2, and outbound HTTPS to Ethereum.

A local check of the JSON API, from inside json-doh-proxy (the image includes `curl`):

```bash
docker compose exec json-doh-proxy curl -fsS 'http://127.0.0.1/dns/api/v1.0/resolv?name=example.com'
```

## Public endpoints

- JSON API: <https://api.isthisyou.org/>. The parameters `servers` and `rd` exist only on this API. `servers` is the name used by json-doh-proxy.
- Binary DoH: <https://doh.isthisyou.org/>. Those parameters are not accepted here.
- Classic DNS on the same host names, port 53, TCP and UDP.

json-doh-proxy also answers `/dns/api/v1.0/resolv` and `/resolv`, as described in its own README.

Only the JSON API (json-doh-proxy) accepts UTF-8 names in `name=` and converts them to Punycode. Binary DoH and port 53 need Punycode first. Clients should convert the name themselves, and should not use an ICANN-strict IDN converter, because Handshake names often contain Unicode that ICANN rules reject. Emoji names are common.

## TLS profile

Enable easy-nginx only when this stack should terminate TLS on the host. Pass `--profile tls` together with one mode. A cloud-provider TLS shedder, or any other proxy on the instance, uses the plain HTTP ports published by that mode, whether or not `tls` is on:

- host port 8080 → `json-doh-proxy` port 80, the JSON API (every mode)
- host port 8081 → `handshake-volume-resolver` port 80, binary DoH (`handshake` only)

Both are plain HTTP. Limit them to the external shedder, with a security group or the equivalent. The `doh.isthisyou.org` line in `nginx.input` proxies to `172.30.53.20`, which is up only in the `handshake` profile.

Start TLS with the full stack:

```bash
docker compose --profile handshake --profile tls up -d
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

`172.30.53.30` is `json-doh-proxy` and `172.30.53.20` is `handshake-volume-resolver`. Both listen on port 80, which is what an `http://` URL with no port uses. These addresses are the static addresses in `compose.yaml`. If those addresses change, change these lines to match. The cert name `isthisyou.org` is the basename of the PEM.

### PEM

Put one file at:

```text
data/easy-nginx/pems/isthisyou.org.pem
```

Inside the container that path is `/opt/data/pems/isthisyou.org.pem`. The file holds the private key and the certificate together. easy-nginx uses that same file as both the certificate and the key. It must be valid for `api.isthisyou.org` and `doh.isthisyou.org`.

Supply `data/easy-nginx/pems/<domain>.pem` on the host. The cert-name field is `<domain>`. Do not commit these files. Each one contains the private key. This repository ignores `data/easy-nginx/pems/*.pem` and any `*.pem` elsewhere. The `pems` directory in git contains only `.gitkeep`.

Place the file before the first start of the profile. If you add it later:

```bash
docker compose --profile handshake --profile tls restart easy-nginx
```

The same host directory is scratch space. The container creates directories there, including `logs` and `htdocs`.

`dkrun` in that repository sets `NGINX_PLAIN_WEB=Y`, which serves files from `/opt/data/htdocs` and does not load the proxy map. This compose file leaves that variable unset, so the proxy map is used. No easy-nginx variables are set here, because that README lists none.

## Volumes

| Mount under `./data` (or `DATA_DIR`) | Container path | Purpose |
| --- | --- | --- |
| `handshake-full-node/` | `/opt/data` | Handshake chain data, in `hsd/` inside that directory. Allow 45 to 50 GB. The container also writes `logs/` here. |
| `ethereum-dns-gateway/` | `/opt/data` | Gateway syslog, in `logs/`. |
| `handshake-volume-resolver/` | `/opt/data` | Resolver state and syslog. Optional authoritative zones go in `auth_zones/`, one file per zone, file name equal to the zone name. handshake-volume-resolver PR #13 (merge `e7ccf5b`, 11 November 2026) fixed `start_named` so an empty `/opt/data/auth_zones` no longer loads a zone named `*`. The fix reaches Docker Hub `latest` only after that image is rebuilt and pushed. Until the published image includes the fix, create `auth_zones` only when it contains zone files. |
| `is-this-you-icann-resolver/` | `/opt/data` | Root zone file (`root.zone`) and syslog, in `logs/`. Profile `icann` only. |
| `easy-nginx/` | `/opt/data` | easy-nginx scratch space, `etc/nginx.input`, and `pems/`. Profile `tls` only. |

handshake-full-node stores the chain in `/opt/data/hsd` (`bin/run_hsd`; `master` and `dev` are both `42957c8`) and changes that directory's owner to the `hsd` user. `rd_bit_proxy` listens on port 53. hsd itself still uses a separate authoritative port (root zone only) and a recursive port; the proxy is how both are reached, split on the RD bit.

## Environment

Set here, so the services can reach each other:

| Variable | Service | Value | Why |
| --- | --- | --- | --- |
| `HSD_MASTERS` | `handshake-volume-resolver` | `172.30.53.10` | Required list of Handshake nodes. `172.30.53.10` is `handshake-full-node`. No port is set, so root_proxy uses port 53, where `rd_bit_proxy` listens. |
| `ETH_MASTERS` | `handshake-volume-resolver` | `172.30.53.50` | ENS gateway addresses, separated by `;`. `172.30.53.50` is `ethereum-dns-gateway`. No port is set, so BIND uses UDP port 53. This builds the `eth.` static-stub. |
| `DOH_SERVERS` | `json-doh-proxy` | `172.30.53.20` in `handshake`. `172.30.53.60` in `icann`. `https://dns.google/dns-query,https://cloudflare-dns.com/dns-query` in `json` | Where ordinary queries go. In `handshake`, `172.30.53.20` is `handshake-volume-resolver`. In `icann`, `172.30.53.60` is `is-this-you-icann-resolver`. In `json`, the two values are Google and Cloudflare DoH. |
| `LOCAL_ICANN_ROOT` | `json-doh-proxy` | unset, except `172.30.53.60` in `icann` | Local root for `servers=icann-root`. Unset in `json` and `handshake`, so that parameter queries roots `d`, `f`, `j` and `k` with `rd=0` and `do=1`. Set in `icann` to the Unbound address. |
| `ETH_RPC_URL` | `ethereum-dns-gateway` | empty unless set on the host | Optional JSON-RPC URL. When set, this wins. |
| `ALCHEMY_API_CODE` | `ethereum-dns-gateway` | empty unless set on the host | Optional Alchemy key. Used when `ETH_RPC_URL` is empty. Calls go to `https://eth-mainnet.g.alchemy.com/v2/<key>`. |

If `ETH_RPC_URL` and `ALCHEMY_API_CODE` are both empty, the gateway uses `https://ethereum.publicnode.com`.

The network `resolver` is `172.30.53.0/24`. root_proxy (`HSD_MASTERS`) accepts numeric IPv4 addresses with an optional `:port` only, not host names. That is why the network uses fixed addresses in this subnet, which also sits inside the image's default BIND allow list (`172.16.0.0/12`). Assigned addresses: `.10` full node, `.20` volume resolver, `.30` json-doh-proxy, `.40` easy-nginx, `.50` ethereum-dns-gateway, `.60` is-this-you-icann-resolver.

Left at the image defaults, and documented by those READMEs:

- `HSD_LOG_LEVEL` (default `info`) and `HSD_ADDITIONAL_PARAMS` (default `--no-sig0 --no-wallet`, plus the migrate flags in `run_hsd`). The handshake-full-node syslog script reads `SYSLOG_SERVER` and `SYSLOG_STDOUT`; with both unset, logs go to `/opt/data/logs/messages` (`data/handshake-full-node/logs/messages` on the host).
- `DOH_SESSIONS` (json-doh-proxy worker count)
- `DNSDIST_STATS_KEY` and `DNSDIST_STATS_ACL` — set both to open dnsdist metrics on port 8083. This file does not choose a password.
- `SYSLOG_STDOUT` and `SYSLOG_SERVER` on the gateway and on `is-this-you-icann-resolver`. Both stay unset, so logs go to `/opt/data/logs/messages`.

## Ports on the host

| Published | Goes to |
| --- | --- |
| `53/tcp`, `53/udp` | `handshake`: dnsdist in `handshake-volume-resolver`. `icann`: Unbound in `is-this-you-icann-resolver`. Not published in `json` |
| `8080` | `json-doh-proxy` port 80, JSON API. Plain HTTP. Published in every mode. |
| `8081` | `handshake-volume-resolver` port 80, binary DoH. Plain HTTP. `handshake` only |
| `127.0.0.1:9119` | BIND metrics |
| `127.0.0.1:8405` | HAProxy metrics |
| `127.0.0.1:8083` | dnsdist metrics, only after the two stats variables above are set |
| `80`, `443` | easy-nginx, profile `tls` only |

The gateway's UDP port 53 is not published. Only BIND on the `resolver` network sends queries there. Client TCP to host port 53 still works. The TCP limit is the last hop, from BIND to the gateway.

Host port 8080 stays published when the `tls` profile is on. Port 8081 stays published in `handshake` when `tls` is on. easy-nginx still uses host ports 80 and 443. Limit 8080 and 8081 to the external TLS shedder, with a security group or the equivalent.

Handshake peer port 12038 is not published by `compose.yaml`. The node still syncs over outbound connections. Without inbound 12038 it is a private node, not a public one. To run a public node, publish `12038/tcp` on `handshake-full-node` and open it in the firewall.

Containers use `restart: unless-stopped`. The component `dkrun` scripts are interactive and do not set a restart policy.
