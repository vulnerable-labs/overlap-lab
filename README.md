## Challenge Brief

Overlap Lab is a multi-stage Docker challenge built around a leaked backup, a weak management portal, and an optional Docker socket pivot. Start the stack, leak the token, unlock the portal, and move through the chain until you reach the final host-root artifact.

## Quick Start

```powershell
docker compose up -d --build
```

Open the portal at `http://localhost`.

The leaked backup is available at `http://localhost/.env.bak`.

## Expected Workflow

1. Start the lab and fetch `/.env.bak`.
2. Use the leaked token to unlock `/login`.
3. Abuse the diagnostic on `/portal` to reach the Phase 2 flag.
4. If `docker-compose.vuln.yml` is enabled, pivot through the Docker socket for the final host-root flag.

## Reset

```powershell
docker compose down -v --remove-orphans
```

## Deployment Notes

- This repository defaults to a *secure* runtime mode. The vulnerable behavior is gated by an environment variable `LAB_MODE` which defaults to `secure`.
- The docker compose file no longer mounts the host Docker socket. That mount is dangerous on multi-tenant hosts; the lab preserves the learning objectives while avoiding host socket escalation by default.
- Runtime secrets (portal token, flags, flask `SECRET_KEY`) are generated at instance startup by `gcp-startup.sh`. Do not commit real secrets to VCS. Files under `app/static/.env.bak` and `app/flags/` are ignored by `.gitignore`.
- Container runtime hardening applied:
	- non-root `appuser` in the web image
	- read-only root filesystem for the web container
	- dropped capabilities except `NET_RAW` (ping needs this)
	- `no-new-privileges` enabled

Use `gcp-startup.sh` as a plain startup script for a GCE VM running Ubuntu 22.04. The script installs Docker, clones the repo, generates runtime secrets, and starts the lab stack. After the VM is healthy, you can create your own custom image from that instance in the normal GCP console or with `gcloud compute images create`.

If you want a reusable image, the simplest workflow is:

1. Create a VM instance with `metadata-from-file=startup-script=gcp-startup.sh`.
2. Wait for `/var/log/overlap-startup.log` to show `Startup complete.`
3. Stop the VM and create an image from its boot disk.

The startup script defaults `SECURE_COOKIES=0` for plain HTTP access from a GCE VM. If you harden the deployment with HTTPS, override that value before starting the stack.

## Notes

- The Docker socket mount is only enabled by `docker-compose.vuln.yml` for the optional pivot phase.
- The final "host" root is simulated with a named volume so the exercise stays isolated.

## Infrastructure Overview

- `gcp-startup.sh` is the VM bootstrap path for Ubuntu 22.04. It installs Docker, clones the repository, seeds runtime artifacts, and starts the lab stack.
- `docker-compose.yml` is the default lab topology. It runs the web app plus two supporting seed services that generate the phase flags and host-root artifact.
- `docker-compose.vuln.yml` is an optional override for isolated training environments. It re-enables the Docker socket path and sets `LAB_MODE=vulnerable`.
- The web service is intentionally hardened for multi-tenant use. The vulnerable behavior is opt-in rather than the default.

## Solution Walkthrough

This section is intentionally brief so the challenge brief stays front and center.

1. Leak the portal token from `/.env.bak`.
2. Unlock `/login` and reach the diagnostic page at `/portal`.
3. Use the command-injection path to recover the Phase 2 flag.
4. If the vulnerable compose override is enabled, pivot through the Docker socket and recover the final host-root artifact.

The full command sequence is intentionally omitted here so students have to reason through the lab instead of following a copy-paste solve.

## Instructor Notes

- Use the provided `docker-compose.vuln.yml` only on isolated lab hosts where you intend to allow the socket pivot. The default `docker-compose.yml` is configured for safer operation and does not expose the Docker socket.
- If you want to temporarily enable the socket on a running deployment, add the volume and `LAB_MODE=vulnerable` to the `web` service and then recreate the service.

## Troubleshooting

- If the Phase 2 diagnostic returns no useful output, ensure you are authenticated (session cookie) and that the `ip` field is submitted exactly as shown (metacharacters need to be URL-encoded if you use them in scripts).
- If the Docker API calls fail when the socket is mounted, verify that the host's Docker daemon has the required images (the `alpine` image is used by the helper container — it will generally be present because the seed services use alpine).
