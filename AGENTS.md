# AGENTS.md

Contexte et règles de travail pour les agents (Claude Code) intervenant sur ce dépôt.

## Objectif du projet

Déploiement déclaratif d'une instance **n8n auto-hébergée**, entièrement décrite dans ce dépôt Git privé. L'ensemble doit être redéployable sur une VM neuve à partir du seul dépôt + les volumes de données restaurés.

## Architecture cible

Deux VM distinctes, toutes deux sous **Ubuntu LTS** :

| VM | Hôte | Rôle | Ressources |
|---|---|---|---|
| n8n | `workflow` | n8n + PostgreSQL (Docker Compose) | 8 Go RAM |
| IA | `ai` — `192.168.0.106` | Ollama, mutualisable avec d'autres projets | 8 vCPU, 16 Go RAM, CPU uniquement |

- Un reverse proxy externe (déjà en place) assure le TLS devant n8n.
- n8n joint Ollama via `http://192.168.0.106:11434`.
- L'API Ollama **n'a aucune authentification** : le pare-feu privé est la seule protection. Ne jamais l'exposer publiquement.

## Structure du dépôt

```
.
├── docker-compose.yml      # n8n + PostgreSQL — toute la config non secrète
├── Dockerfile              # image n8n + nœuds communautaires
├── community-nodes.txt     # nœuds communautaires, un par ligne, versions figées
├── docker-entrypoint-custom.sh  # copie les nœuds de l'image vers le volume
├── docker/postgres/        # création du rôle applicatif à l'initialisation
├── .sops.yaml              # règles de chiffrement (destinataires age)
├── .env.sops.yaml          # secrets chiffrés (SOPS) — seul env versionné
├── .env.example            # toutes les clés attendues, documentées, sans valeur
├── deploy.sh               # déploiement idempotent, aussi le point d'entrée CI
├── Makefile                # raccourcis vers scripts/
├── scripts/                # secrets / backup / restore / export / healthcheck
│   └── systemd/            # timer de sauvegarde système
├── workflows/              # JSON alimentés par le source control natif n8n
├── templates/              # modèles de workflows réutilisables
└── docs/                   # notes d'exploitation
```

Les scripts sont la source de vérité opérationnelle : `make help` les liste tous.
Détails dans `docs/deployment.md`, `docs/ollama.md`, `docs/backup-restore.md`,
`docs/troubleshooting.md`.

## Règles impératives

1. **Aucun secret en clair.** Tout passe par SOPS. Ne jamais committer un `.env` déchiffré, ne jamais afficher une valeur déchiffrée dans un commentaire ou un log.
2. **`N8N_ENCRYPTION_KEY` est critique.** Sa perte rend tous les credentials n8n irrécupérables. Elle est chiffrée dans le dépôt et sauvegardée hors-ligne. Ne jamais la régénérer sans instruction explicite.
3. **Ne pas éditer les JSON de `workflows/` à la main.** Ils contiennent des identifiants de nœuds et des coordonnées de positionnement. Le flux nominal est : édition dans l'interface n8n → commit depuis n8n (source control natif). Les fichiers de `templates/` sont en revanche éditables.
4. **Pas de dumps ni de binaires dans Git.** Le dépôt ne contient que de la configuration. Les sauvegardes vont vers l'outil de backup existant (Restic/Borg), pas ici.
5. **Versionner les nœuds communautaires** dans le `Dockerfile` (ou via `N8N_COMMUNITY_PACKAGES`), jamais d'installation manuelle dans le conteneur.

## VM Ollama — état installé

Installation via le script officiel (`curl -fsSL https://ollama.com/install.sh | sh`), service systemd `ollama.service`.

Override systemd (`systemctl edit ollama.service`) :

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=-1"
```

- **Ne pas redéfinir `OLLAMA_MODELS`.** Le chemin par défaut est `/usr/share/ollama/.ollama/models`, home de l'utilisateur système `ollama`. Pointer ailleurs sans créer le répertoire ni ajuster les droits fait échouer le service au démarrage (exit code 1 en quelques dizaines de ms). C'est le piège déjà rencontré.
- Un `ollama serve` lancé manuellement en root utilise `/root/.ollama/models` et occupe le port 11434 : les deux ne partagent pas les modèles et s'empêchent mutuellement de démarrer.
- `OLLAMA_KEEP_ALIVE=-1` garde le modèle résident indéfiniment (`expires_at` affiche alors une date lointaine, aux alentours de l'an 2318 — c'est normal). Coût : ~9 Go de RAM occupés en permanence sur les 16.
- Pare-feu : port 11434 ouvert uniquement depuis l'IP de la VM n8n.

## Modèle et performances

Modèles présents sur la VM (relevé du 2026-09-10, Ollama 0.34.0) :

| Modèle | Paramètres | Quantisation | Contexte | Réflexion |
|---|---|---|---|---|
| `qwen3:14b` | 14,8 B | Q4_K_M | 40 960 | oui |
| `qwen2.5:14b` | 14,8 B | Q4_K_M | 32 768 | **non** |
| `gemma4:latest` | 8,0 B | Q4_K_M | — | oui |

- Débit mesuré sur `qwen2.5:14b` : **~4,2 tokens/s**, chargement initial ~35 s. C'est la norme attendue pour un 14B quantifié sur 8 cœurs CPU.
- Un seul modèle reste résident à la fois avec `OLLAMA_KEEP_ALIVE=-1` : alterner `qwen3:14b` et `gemma4` dans le même lot nocturne paie ~35 s de chargement à chaque bascule. Grouper les workflows par modèle.
- **Le swap est fatal.** Avec une allocation RAM insuffisante, le débit mesuré était de 0,02 tok/s (12 minutes pour répondre « Bonjour »), soit un facteur ~190. Avant tout diagnostic de lenteur : vérifier `free -h` et l'allocation réelle côté hyperviseur, pas seulement la valeur configurée.
- Ordre de grandeur pour le design des workflows : une réponse de 500 tokens ≈ 2 minutes. Éviter les nœuds qui génèrent de longs textes en série.
- Exécution en **batch nocturne** : la latence n'est pas un critère, la qualité de sortie prime.

## Réflexion (thinking)

- **`qwen2.5` n'est pas un modèle à réflexion.** Ne pas y envoyer de paramètre `think` : Ollama renvoie une erreur explicite plutôt que de l'ignorer. `qwen3:14b` et `gemma4` sont installés et annoncent la capacité `thinking` : c'est vers eux qu'il faut se tourner quand la réflexion est utile.
- Pour les modèles compatibles (qwen3, gpt-oss, deepseek-r1…), le champ `think` se place **au premier niveau** de la requête, à côté de `model` et `messages` — pas dans l'objet `options`.
- Valeurs acceptées par l'API : `true`, `false`, `low`, `medium`, `high`.
- La réflexion est **activée par défaut** en CLI comme en API pour les modèles qui la supportent. Il faut expliciter `"think": false` pour la couper.
- Les niveaux (`low`/`medium`/`high`) sont le mécanisme de GPT-OSS, qui ignore les booléens. Qwen3 est documenté comme binaire : un niveau peut être accepté par l'API puis ignoré par le template. Vérifier en comparant `eval_count` entre deux appels sur le même prompt.
- Règle de conception : réflexion active pour les workflows d'analyse nocturnes, désactivée pour la classification et l'extraction où elle ne rapporte rien.

## Sauvegarde

- **Dump PostgreSQL quotidien** + export CLI des workflows (`n8n export:workflow --all`), archivés et repris par l'outil de backup existant.
- **Snapshot mensuel** de la VM au niveau hyperviseur (filet de sécurité, pas la stratégie principale).
- Le workflow de sauvegarde peut être orchestré par n8n lui-même, mais **un cron système doit rester en doublon** : dépendance circulaire assumée mais couverte.
- Les volumes de données (base PostgreSQL, modèles Ollama téléchargés) ne vivent pas dans le dépôt.

## Diagnostic rapide

```bash
sudo journalctl -u ollama -n 30 --no-pager   # cause d'un échec de démarrage
sudo ss -tlnp | grep 11434                   # port déjà occupé ?
curl http://192.168.0.106:11434/api/tags     # modèles visibles depuis n8n
curl http://192.168.0.106:11434/api/ps       # modèle résident + expires_at
nproc && free -h                             # cœurs et swap
```

Les champs `load_duration`, `prompt_eval_duration` et `eval_duration` des réponses API sont en **nanosecondes** : ce sont les premiers indicateurs à lire pour distinguer un problème de chargement d'un problème de génération.

## Conventions

- Toute modification d'infrastructure passe par le dépôt, jamais en direct sur la VM.
- Épingler les versions d'images Docker (pas de `latest`). En service : n8n **2.38.6** (ce que résolvait le tag `stable`), PostgreSQL **17.11-alpine**. Une montée de version est un commit explicite — voir `docs/deployment.md`.
- Les migrations de base n8n sont jouées au démarrage et **ne sont pas réversibles** : le repli après une montée de version majeure est la restauration du dump pré-déploiement que prend `deploy.sh`.
- Ne pas monter `./backups` dans le conteneur n8n : les droits d'écriture dépendraient du propriétaire du répertoire hôte, qui diffère entre Docker rootful et rootless. Les exports CLI passent par `docker compose cp`.
- `n8n export:workflow --all` sort en **code non nul** quand il n'y a rien à exporter. Tout script qui l'enchaîne doit tolérer ce cas, sinon une instance vide casse la sauvegarde.
- Un JSON de `templates/` doit porter un `id` de premier niveau, sinon `n8n import:workflow` échoue sur `null value in column "id"`.
- Garder la même distribution sur les deux VM pour éviter de jongler entre écosystèmes.
- Documenter dans `docs/` toute décision d'exploitation non évidente.
