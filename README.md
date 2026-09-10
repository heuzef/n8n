# n8n — self-hosted

n8n + PostgreSQL on a private VM, served over HTTPS by an external Caddy.

## Install

On the VM :

```bash
cp .env.example .env
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'   # N8N_ENCRYPTION_KEY
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'   # N8N_RUNNERS_AUTH_TOKEN
$EDITOR .env
docker compose up -d
```

Fill in all eight keys. Only four of them stop Compose when left empty, and an empty `N8N_BIND_ADDRESS` silently publishes n8n on every interface.

## Code node

The Code node runs user code in the `task-runners` sidecar (`n8nio/runners`), which
carries the JavaScript and the native Python 3 runners. n8n itself is Node/Alpine and
has no Python, so without this sidecar the Python mode fails with *Python runner
unavailable*.

- The `n8nio/runners` tag must be **exactly** the `n8nio/n8n` tag. A mismatch breaks the
  Code node.
- `N8N_RUNNERS_AUTH_TOKEN` is the shared secret between n8n (the broker) and the sidecar.
  Both containers read the same `.env` value; it never belongs in the compose file.
- Broker port `5679` is reachable only on the Compose network. Never publish it.

## Deploy

Push to `main`, or run the workflow from the Actions tab. The VM does a `git reset --hard`, then `docker compose down`, `pull`, `up -d`.

## Warnings

- **`N8N_ENCRYPTION_KEY` is the single point of failure.** It encrypts every stored credential. Lose it and they are unrecoverable.
- **PostgreSQL tracks `latest`.** A deploy can cross a major version and PostgreSQL then refuses an older data directory. `n8n` and `runners` are pinned, so bumping n8n is a deliberate edit here — and n8n runs irreversible migrations on a major bump.
