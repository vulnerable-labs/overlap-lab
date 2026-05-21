# Overlap

A small, self-contained vulnerable lab for training on web recon, command injection, and Docker socket pivoting.

## Chain

1. A forgotten backup file exposes the portal token and the phase 1 flag.
2. The management portal contains a deliberately unsafe diagnostic ping form.
3. The container has the Docker socket mounted so students can enumerate internal services and reach the phase 3 flag vault.
4. The final flag lives in a training volume that stands in for a host root filesystem.

## Run

```powershell
docker compose up -d --build
```

Open the portal at:

```text
http://localhost:8080
```

The leaked backup is available at:

```text
http://localhost:8080/.env.bak
```

## Reset

```powershell
docker compose down -v --remove-orphans
```

## Notes

- The Docker socket mount is intentional for the lab.
- The final "host" root is simulated with a named volume so the exercise stays isolated.
- Run this only on a disposable VM or lab host.
