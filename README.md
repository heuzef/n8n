# n8n — self-hosted

n8n + PostgreSQL on a private VM, served over HTTPS by an external Caddy.

## Install

On the VM :

```bash
cp .env.example .env
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'   # N8N_ENCRYPTION_KEY
$EDITOR .env
docker compose up -d
```

Fill in all seven keys. Only three of them stop Compose when left empty, and an empty `N8N_BIND_ADDRESS` silently publishes n8n on every interface.

## Deploy

Push to `main`, or run the workflow from the Actions tab. The VM does a `git reset --hard`, then `docker compose down`, `pull`, `up -d`.

## Warnings

- **`N8N_ENCRYPTION_KEY` is the single point of failure.** It encrypts every stored credential. Lose it and they are unrecoverable.
- **Both images track `latest`.** A deploy can cross a major version: n8n runs irreversible migrations, PostgreSQL refuses an older data directory.
