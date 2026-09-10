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
├── docker-compose.yml      # n8n + PostgreSQL
├── .env.sops.yaml          # secrets chiffrés (SOPS)
├── Dockerfile              # image n8n + nœuds communautaires
├── workflows/              # JSON alimentés par le source control natif n8n
├── templates/              # modèles de workflows réutilisables
├── scripts/                # backup / restore / export CLI
└── docs/                   # notes d'exploitation
```

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

- Modèle en service : **`qwen2.5:14b`** (Q4_K_M, 14,8 B, ~9 Go, contexte 32 768, capacités `completion` + `tools`).
- Débit mesuré : **~4,2 tokens/s**, chargement initial ~35 s. C'est la norme attendue pour un 14B quantifié sur 8 cœurs CPU.
- **Le swap est fatal.** Avec une allocation RAM insuffisante, le débit mesuré était de 0,02 tok/s (12 minutes pour répondre « Bonjour »), soit un facteur ~190. Avant tout diagnostic de lenteur : vérifier `free -h` et l'allocation réelle côté hyperviseur, pas seulement la valeur configurée.
- Ordre de grandeur pour le design des workflows : une réponse de 500 tokens ≈ 2 minutes. Éviter les nœuds qui génèrent de longs textes en série.
- Exécution en **batch nocturne** : la latence n'est pas un critère, la qualité de sortie prime.

## Réflexion (thinking)

- **`qwen2.5` n'est pas un modèle à réflexion.** Ne pas y envoyer de paramètre `think` : Ollama renvoie une erreur explicite plutôt que de l'ignorer.
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
- Épingler les versions d'images Docker (pas de `latest`).
- Garder la même distribution sur les deux VM pour éviter de jongler entre écosystèmes.
- Documenter dans `docs/` toute décision d'exploitation non évidente.
