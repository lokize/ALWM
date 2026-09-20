# Docker

Full Docker + Compose manager on the ALWM workspace bar.

## Containers
- Chip: `running/total` (e.g. `3/7`)
- Start / stop / restart / pause / unpause
- Change restart policy (`no`, `always`, `unless-stopped`, `on-failure`)
- Export / backup container filesystem (`.tar`)
- Remove container · view recent logs

## Compose
- Save Compose projects (YAML + optional Dockerfile)
- Up / down / stop / start / pull
- Open project folder in Finder
- Stored under `~/.config/alwm/plugins/docker-compose-projects/`

Requires Docker Desktop (or Engine) with `docker` / `docker compose` on PATH.

Enable under **Settings → Plugins**.

License: **GPL-3.0** (same as ALWM).
