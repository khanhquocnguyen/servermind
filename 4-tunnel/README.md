# tunnel

Public entry for a machine **without a public IP** (a dev laptop, a home server). A server with a public IP does not
need it: there Cloudflare points straight at `<PUBLIC_IP>:443`.

```
Browser ⇄ Cloudflare ⇄ tunnel ⇄ cloudflared (container) ⇄ https://traefik:443 on traefik-proxy-network ⇄ app
```

Everything behind Traefik stays the same as on a server: apps keep their `Host()` labels, nothing publishes a port,
and the machine accepts no inbound connection at all (cloudflared dials out).

```
tunnel/
├── docker-compose.yml   # cloudflared, pinned; on traefik-proxy-network, no ports
├── config.yml           # one catch-all rule → https://traefik:443 (same on every machine)
├── tunnel.sh            # zone / init / route / status
├── credentials.json     # tunnel secret, written by tunnel.sh init (gitignored, 600)
├── .env                 # TUNNEL_ID + uid/gid for the container, written by tunnel.sh init (gitignored)
└── zones/<zone>.pem     # origin cert per Cloudflare zone, for `route` (gitignored, 600)
```

## Setup (once per machine)

Needs Traefik running (`3-traefik`) and the `cloudflared` CLI on the host (`brew install cloudflared`, or the
Cloudflare apt repo) for the one-off commands below; the tunnel itself runs in the container.

```bash
bash tunnel.sh zone example.com              # browser login, pick the zone → zones/example.com.pem
bash tunnel.sh init                          # create a tunnel named after this machine
#   or: bash tunnel.sh init ~/.cloudflared/<id>.json   — adopt a tunnel that already exists
docker compose up -d
docker compose logs cloudflared              # 4 × "Registered tunnel connection"
```

## Adding a hostname

```bash
bash tunnel.sh zone other-zone.com           # first hostname of a new zone only
bash tunnel.sh route app.example.com         # proxied CNAME → <tunnel-id>.cfargotunnel.com (overwrites)
```

`route` picks the zone from `zones/`. `cloudflared tunnel route dns` writes into the zone of the cert it is given,
and a cert from another zone silently creates `app.example.com.other-zone.com`; hence one cert per zone, and the
script fails loudly when that happens. Then deploy the app with a `Host()` rule for that hostname as usual.

Cloudflare zone settings are the same as for a server: SSL/TLS **Full (strict)**, **Always Use HTTPS**.

## Notes

- Requests reach Traefik from the cloudflared container's address on `traefik-proxy-network`, not from a Cloudflare
  IP. `CF-Connecting-IP` still carries the visitor's IP.
- `noTLSVerify`: the hop never leaves the docker network, and Origin CA certs are not publicly trusted anyway. Without
  an origin cert Traefik serves its self-signed default, which is fine here.
- One tunnel per machine. Two machines running the same tunnel would share its traffic (replicas), not split it.
- Upgrading: bump the tag in `docker-compose.yml`, `docker compose pull && docker compose up -d`.
