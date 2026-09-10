# n8n — self-hosted

A self-hosted [n8n](https://n8n.io) instance with PostgreSQL, deployed by Docker
Compose on a private VM and served over HTTPS by an external Caddy.

Keep it stupidly simple: two images, one compose file, one `.env`.

## Architecture

```
  browser ──https://workflow.heuzef.com──►  Caddy  ──:5678──►  192.168.0.107
                                          (other host)         n8n + PostgreSQL
                                                                     │
                                                              :11434 ▼
                                                               192.168.0.106
                                                               Ollama (no auth,
                                                               private network)
```

Caddy terminates TLS on 443 and is the only public entry point. n8n listens on
5678 and is published on the LAN address only, never on `0.0.0.0`, so it can
never be reached directly without TLS.

## Files

| Path | What it is |
|---|---|
| `docker-compose.yml` | n8n + PostgreSQL, both on `latest`. |
| `.env.example` | Every variable the compose file expects. Copy to `.env`. |
| `.github/workflows/deploy.yml` | Pushes to `main` update the code on the VM. |
| `.gitignore` | Keeps `.env` out of Git. |

## First install

On the VM, in `/root/n8n`:

```bash
cp .env.example .env
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'   # N8N_ENCRYPTION_KEY
$EDITOR .env
docker compose up -d
docker compose logs -f n8n
```

`.env` is gitignored and carries no default values, so fill in all seven keys.

Only `N8N_ENCRYPTION_KEY`, `POSTGRES_PASSWORD` and `N8N_HOST` make Compose refuse
to start when empty. The other four are accepted blank and fail later — in
particular **an empty `N8N_BIND_ADDRESS` publishes n8n on every interface**,
which is the one thing binding to the LAN address was meant to prevent.

## Caddy

On the Caddy host:

```caddy
workflow.heuzef.com {
    reverse_proxy 192.168.0.107:5678
}
```

The port is required — without it Caddy would target port 80. Nothing else is
needed: Caddy handles WebSockets and `X-Forwarded-*` on its own, which is what
`N8N_PROXY_HOPS: 1` in the compose file expects.

## Deploying

Push to `main`, or run the workflow by hand from the Actions tab. The VM does a
`git reset --hard origin/main`, so anything modified directly on it is lost.

The workflow **updates the code but does not restart the stack**. After a change
to `docker-compose.yml`, apply it on the VM:

```bash
cd /root/n8n && docker compose up -d
```

## Worth knowing

- **`N8N_ENCRYPTION_KEY` is the single point of failure.** It encrypts every
  credential n8n stores. Lose it and they are all unrecoverable — a database
  backup without it is worthless. Keep a copy outside this VM, and never change
  it on a live instance.
- **Both images track `latest`.** A `docker compose pull` can therefore cross a
  major version: n8n would run irreversible database migrations, and PostgreSQL
  would refuse to start on a data directory from an older major
  (`database files are incompatible with server`). Pin a tag the day that matters.
- **The PostgreSQL volume is mounted at `/var/lib/postgresql`, not
  `.../data`.** PostgreSQL 18 images moved `PGDATA` to
  `/var/lib/postgresql/18/docker`. Mounting the parent covers both layouts;
  mounting `.../data` would silently send the data to an anonymous volume.
- **Nothing is backed up yet.** The `postgres_data` volume holds every workflow
  and credential.
