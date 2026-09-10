# n8n — self-hosted, declarative

Everything needed to rebuild a self-hosted **n8n** instance from this repository
alone, plus restored data volumes. Nothing is configured by hand on the VM.

```
             ┌──────────── external reverse proxy (TLS) ────────────┐
             │                                                      │
   https://<N8N_HOST>/                                              │
             │                                                      ▼
   ┌─────────┴──────────────────┐              ┌──────────────────────────┐
   │  VM `workflow`  · 8 GB     │              │  VM `ai` · 192.168.0.106 │
   │                            │   HTTP       │  8 vCPU · 16 GB · CPU    │
   │  n8n  127.0.0.1:5678  ─────┼──── :11434 ─►│  Ollama 0.34.0           │
   │   └── PostgreSQL 17        │  (no auth,   │   qwen3:14b · qwen2.5:14b│
   │       (private network)    │   firewalled)│   gemma4                 │
   └────────────────────────────┘              └──────────────────────────┘
```

## Quick start

```bash
make help          # every available target
make deploy        # full idempotent deployment (what CI runs)
make health        # diagnose the stack and the Ollama VM
make backup        # PostgreSQL dump + CLI export into backups/
make logs
```

First install, upgrades and fresh-VM rebuild: **[docs/deployment.md](docs/deployment.md)**.

## Layout

| Path | What it is |
|---|---|
| `docker-compose.yml` | n8n + PostgreSQL. All non-secret configuration lives here. |
| `Dockerfile` | n8n image with community nodes baked in. |
| `community-nodes.txt` | Community packages, one per line, versions pinned. |
| `.env.sops.yaml` | Secrets, SOPS/age encrypted. The only env file in Git. |
| `.env.example` | Every expected key, documented, with no value. |
| `deploy.sh` | Idempotent deployment. Also the CI entry point. |
| `scripts/` | secrets, backup, restore, export, healthcheck, systemd units. |
| `workflows/` | Workflow JSON, written by n8n's native source control. |
| `templates/` | Reusable, hand-editable workflow skeletons. |
| `docs/` | Operations notes. |

## Rules that matter

1. **No plaintext secret, ever.** Everything goes through SOPS. `.env` is
   generated at deploy time and gitignored.
2. **`N8N_ENCRYPTION_KEY` is the single point of failure.** Lose it and every
   stored credential is unrecoverable — a database backup without it is worthless.
   It is kept offline, separately from the backups. Never regenerate it on a live
   instance.
3. **Never hand-edit `workflows/*.json`.** They carry node ids and canvas
   coordinates. Edit in the n8n UI, commit from n8n. `templates/` is the editable
   part.
4. **No dumps, no binaries in Git.** Configuration only. Backups go to the
   existing Restic/Borg setup.
5. **Pin everything.** Docker image tags, community node versions. No `latest`.
6. **The VM is never modified directly.** Every change lands in this repository
   first.

## Docs

- [Deployment](docs/deployment.md) — prerequisites, VM decryption key, first
  deploy, upgrades, rebuilding from scratch.
- [Ollama](docs/ollama.md) — installed state, models, performance, `think`, the
  traps already hit.
- [Backup & restore](docs/backup-restore.md) — what is saved, the restore drill.
- [Troubleshooting](docs/troubleshooting.md) — symptom → cause.
- [AGENTS.md](AGENTS.md) — context and rules for agents working on this repo.
