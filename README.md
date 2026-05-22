# Overlap Lab

Overlap Lab is a multi-stage security challenge built around a leaked backup, an authenticated management portal, and an optional Docker socket pivot.

The scenario starts with a public backup file that leaks a portal token. Once the portal is unlocked, the diagnostic feature becomes the next target and can be abused in vulnerable mode. If the optional vulnerable compose override is enabled, the challenge extends into container pivoting and host-level access.

## Skills Tested

- Finding exposed secrets in public files
- Understanding basic authentication flow
- Recognizing and abusing command injection
- Working with Docker-based attack paths
- Reasoning about privilege boundaries in containerized environments
- Following a multi-stage exploitation chain

## Lab Theme

This lab is designed to feel like a realistic infrastructure-focused web challenge. It combines web exposure, container security, and post-exploitation reasoning into a single chain.
