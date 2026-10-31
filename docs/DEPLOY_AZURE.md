# Online deployment on one Azure VM

FaceTrack runs online on a single Azure virtual machine. Data stays in the hosted Supabase project; the VM runs the API, Redis, the Celery worker and the agent in Docker, plus Caddy for HTTPS and the two web apps.

| What | Address |
|---|---|
| Teacher web | https://facetrack.centralindia.cloudapp.azure.com/teacher/ |
| Student web | https://facetrack.centralindia.cloudapp.azure.com/student/ |
| API (for the apps) | https://facetrack.centralindia.cloudapp.azure.com |
| Health | https://facetrack.centralindia.cloudapp.azure.com/health/ready |

## The server

- Azure for Students subscription, resource group `facetrack-rg`, VM `facetrack-vm`, Central India, `Standard_B2as_v2` (2 vCPU, 8 GB, burstable), Ubuntu 24.04, 64 GB Standard SSD, static public IP with DNS label `facetrack`. About US$45 a month from student credit.
- Firewall: 80 and 443 open; SSH (22) only from the operator's IP. Port 8000 is never opened: the API listens on `127.0.0.1` and Caddy fronts it.
- Login: `ssh -i ~/.ssh/facetrack_azure azureuser@facetrack.centralindia.cloudapp.azure.com`. The key exists only on the operator's Mac.
- Layout: code in `/opt/facetrack` (from `git archive origin/main`), web builds in `/srv/facetrack/{teacher,student}`, Caddy config in `/etc/caddy/Caddyfile` (copy of [deploy/azure/Caddyfile](../deploy/azure/Caddyfile)).
- Private files copied over SSH: `services/api/.env`, `services/worker/.env`, `.local/spike/models/buffalo_sc/` and `.local/spike/profiles/frozen-phase1b-v1.json`. On the server, `MIGRATION_DATABASE_URL` is removed from the API `.env` (the runtime never uses the owner credential) and `CORS_ORIGINS` includes the public origin.
- Caddy blocks `/internal/*` (the agent reaches the API on the private Docker network) and the OpenAPI docs pages.

## One backend only

The VM's agent claims processing jobs from the shared hosted database. Run **either** the VM worker/agent **or** a local one, never both. Local apps and the local API can keep running: jobs they create are processed by the VM.

- Move processing back to a Mac: `ssh … 'cd /opt/facetrack && docker compose stop worker agent'`, then start the local worker and agent.
- Move it to the VM again: stop the local worker and agent, then `docker compose up -d worker agent` on the VM.

## Updating

From the Mac, after pushing to `main` (the script starts the VM if it is deallocated and allows SSH from your current IP first):

```sh
deploy/azure/deploy.sh            # ships origin/main, rebuilds containers and both web apps
deploy/azure/deploy.sh --web-only # only the web apps
```

It needs `.local/flutter/production.json` (a copy of `development.json` with `API_BASE_URL` set to the public address). It never ships uncommitted local edits and never touches the server's `.env` or model files. No migration runs on deploy.

## Day-to-day

```sh
ssh -i ~/.ssh/facetrack_azure azureuser@facetrack.centralindia.cloudapp.azure.com
cd /opt/facetrack
docker compose ps                              # api, redis, worker, agent should be running
docker compose logs --tail 100 api worker agent
```

- Containers restart automatically after a reboot.
- Pause billing: `az vm deallocate -g facetrack-rg -n facetrack-vm`; resume: `az vm start -g facetrack-rg -n facetrack-vm` (the IP and name stay).
- SSH refused after the operator's IP changes: `az network nsg rule update -g facetrack-rg --nsg-name facetrack-vmNSG -n default-allow-ssh --source-address-prefixes <new-ip>/32`.
- The worker credential is time-limited. The current one expires on **22 November 2026 (06:23 UTC)**. When it is rejected the agent logs "Worker credential rejected or expired" every minute and processing pauses (uploads still succeed and wait in the queue). The owner reissues it with the provisioning tool and replaces `WORKER_TOKEN` in `services/worker/.env` on the VM, then runs `docker compose up -d worker agent`. That is a deliberate owner action, never part of routine deploys. Do not reseed or reprovision.
- "Enrolment agent waiting for local API/broker" means the agent cannot reach the API or Redis (network or startup), not a credential problem.

## Limits to state honestly

- B-series VMs are burstable: long recognition jobs can slow down once CPU credits run out.
- The InsightFace model permission covers the non-commercial academic demonstration only.
- The phone app still points wherever its APK was built for; a phone build against this server needs `--dart-define-from-file=.local/flutter/production.json`.
- Student credit expires on 13 April 2027.
