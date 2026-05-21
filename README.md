Run

```powershell
# (recommended) let the GCP startup script provision runtime secrets and start the lab
# from the instance: gcp-startup.sh will set DEV_PORTAL_TOKEN and SECRET_KEY at runtime.
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

## Production / Multi-tenant Guidance

- This repository defaults to a *secure* runtime mode. The vulnerable behavior is gated by an environment variable `LAB_MODE` which defaults to `secure`.
- To run the interactive vulnerable lab, set `LAB_MODE=vulnerable` **only** on isolated, disposable hosts (never on production or multi-tenant shared machines).
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
- Do NOT enable `LAB_MODE=vulnerable` on shared infrastructure. Only enable it in isolated student environments.

## Reset

```powershell
docker compose down -v --remove-orphans
```

## Notes

- The Docker socket mount is intentional for the lab.
- The final "host" root is simulated with a named volume so the exercise stays isolated.
- Run this only on a disposable VM or lab host.
