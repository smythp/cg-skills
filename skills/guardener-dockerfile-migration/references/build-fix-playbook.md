# Build-fix playbook

When a build of the migrated file fails, read the actual error and the log
lines around it before changing anything — the last line of BuildKit output
is often a summary, and the cause is a few lines up. Keep the build log (the
workflow already saves it in the working directory) and grep it rather than
re-running the build to see the error again.

## Contents

- [Error signatures and their fixes](#error-signatures-and-their-fixes)
- [Never swap registries](#never-swap-registries)
- [Rebuild before done](#rebuild-before-done)

## Error signatures and their fixes

| Error contains | Cause | Fix |
|---|---|---|
| `apt-get: not found`, `apt: not found`, `dnf: not found`, `yum: not found` | Debian/Fedora package command left in a Chainguard stage | Translate the line to `apk add --no-cache` with Wolfi package names, or move it to the stage it belongs to |
| `apk: not found` | apk emitted into a non-Chainguard stage, or a distroless (non-dev) image | Move the install to a `-dev` build stage, or switch this stage's tag to `-dev` if it legitimately needs a shell |
| `ERROR: unable to select packages:` / `no such package` | Package name wrong for Wolfi | Look the name up (`scripts/apk-lookup.sh`), try the rename patterns, check the original file for the intended spelling |
| `/bin/sh: not found`, `runc run failed: ... exec: "/bin/sh"` | RUN line in a distroless stage | Same as `apk: not found`: RUN lines belong in `-dev` stages |
| `adduser: unrecognized option`, `useradd: not found` | Alpine BusyBox user-management flags on Wolfi | Install `shadow` and translate the flags to `useradd`/`groupadd` |
| `Permission denied` during `apk add` or file writes | RUN executing as the image's non-root user | Wrap in `USER root` ... `USER <image user>` in the same emitted block |
| Container starts then exits with the CMD's first word treated as a file path | CMD passed as arguments to a purpose-built image's ENTRYPOINT | Rewrite the CMD as arguments to the image's ENTRYPOINT, or reset `ENTRYPOINT []` when the CMD runs a different program |
| `pip install` fails compiling a wheel (`gcc: not found`, missing `.h`) | Build toolchain absent in the migrated stage | Add `build-base` and the relevant `-dev` packages to that stage, or move the install to a `-dev` build stage |
| `manifest unknown`, `not found` on the FROM pull | The chosen tag does not exist in this registry | Pick a different tag on the same registry from the real tag list; never change the registry to fix a tag |
| `no matching manifest for platform` | Image has no manifest for the build platform | Pass the original build's `--platform`, or pick a tag that has the platform |
| `401 Unauthorized`, `403 Forbidden`, TLS or proxy errors on pull | Auth or network environment problem | Stop and report the underlying error to the user; this is theirs to fix |

## Never swap registries

A failed pull or build is never a license to change where images come from.
Do not substitute `ghcr.io/chainguard-images/*`, `docker.io/chainguard/*`,
`public.ecr.aws/chainguard/*`, an upstream distro image, or any other host —
they are not the same images even when they look identical, and the swap
produces a migration that quietly stopped being a migration. The FROM gate
(`scripts/check-from-lines.sh`) rejects the result anyway, so the swap also
wastes the build. When the error is registry, auth, cache, or network, report
it and stop.

`FROM scratch` is not a fallback for a failing base either: scratch is only
for stages that ship a single static binary on purpose. Putting a shell-using
stage on scratch trades a pull error for a stage that cannot run anything.

Correct response to a pull failure:

> The build failed pulling cgr.dev/example-org/python:3.12-dev: 403 Forbidden.
> Your identity does not have access to the example-org registry. I have not
> changed the FROM line; once access is fixed, rerun the build.

Wrong response (swapping the registry to make the error go away):

```dockerfile
FROM ghcr.io/chainguard-images/python:3.12-dev
```

## Rebuild before done

After every fix, rebuild before moving on, and only ever emit lines that were
part of the last successful build. Do not re-add a line the successful build
did not contain, and do not carry an untested "improvement" into the final
file. The gap between what was tested and what was emitted is the most common
cause of a final build that fails after every layer looked fine.
