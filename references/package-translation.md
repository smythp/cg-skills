# Package translation

## Contents

- [Never install: ca-certificates](#never-install-ca-certificates)
- [Already in wolfi-base and chainguard-base](#already-in-wolfi-base-and-chainguard-base)
- [Provided by BusyBox](#provided-by-busybox)
- [Not preinstalled: must be added](#not-preinstalled-must-be-added)
- [Wolfi naming patterns](#wolfi-naming-patterns)
- [Converting the package manager command](#converting-the-package-manager-command)
- [Name tables](#name-tables)
- [User and group creation](#user-and-group-creation)
- [Validating names before building](#validating-names-before-building)
- [Version pinning](#version-pinning)
- [Language package managers](#language-package-managers)

## Never install: ca-certificates

Remove `ca-certificates` and `ca-certificates-bundle` from every translated
`apk add`. The certificate bundle ships in every Chainguard image at
`/etc/ssl/certs/`; installing it again adds noise, and the extra package can
shadow the image's managed bundle.

Correct: `apk add --no-cache curl`
Wrong: `apk add --no-cache ca-certificates curl`

## Already in wolfi-base and chainguard-base

Do not reinstall: `apk-tools`, `busybox`, `ca-certificates-bundle`, `glibc`,
`libcrypto3`, `libssl3`, `zlib`.

## Provided by BusyBox

No install needed for common file operations (`ls`, `cp`, `mv`, `rm`,
`mkdir`, `cat`, `chmod`, `find`), text tools (`grep`, `sed`, `awk`, `sort`),
archive tools (`tar`, `gzip`), basic network tools (`ping`, `netstat`),
BusyBox's own `adduser`/`addgroup`, and the `sh`/`ash` shells.

## Not preinstalled: must be added

These are commonly assumed present but are not in the base images: `wget`,
`curl`, `git`, `bash` (only `sh`/`ash` ship), `tzdata` (timezone data is not
preinstalled), `jq`, `make`, `gcc`, `python3`, `nodejs`. If the original
Dockerfile or its RUN lines need them, install them explicitly.

Packages with identical names in Alpine, Debian, and Wolfi — `git`, `wget`,
`curl`, `bash`, `jq`, `make`, `gcc` — translate directly; the only edit is
removing `ca-certificates` from the same line.

## Wolfi naming patterns

When a name lookup fails, try these renames before concluding the package is
missing:

- `python3-X` → `py3-X`; the version-specific form is `py3.12-X`
- `libX1-dev`, `libX-dev` (Debian) → `X-dev`
- `X-devel` (Fedora/RHEL) → `X-dev`
- Dev headers are `<package>-dev`; docs are `<package>-doc`

## Converting the package manager command

Convert `apt-get`, `apt`, `yum`, `dnf`, and `microdnf` installs to
`apk add --no-cache`. Replace, do not delete: dropping an install line
silently removes packages the application needs, and the loss only surfaces
at runtime.

Correct:

```dockerfile
# Original:
# RUN apt-get update && apt-get install -y curl git && rm -rf /var/lib/apt/lists/*
RUN apk add --no-cache curl git
```

Wrong (line deleted instead of translated; curl and git are now missing):

```dockerfile
# (nothing)
```

The cache-cleanup suffixes (`rm -rf /var/lib/apt/lists/*`, `yum clean all`,
`dnf clean all`, `rm -rf /var/cache/*`) are unnecessary with `--no-cache`;
drop them.

Each stage of a multi-stage build has its own base and its own package
manager. Only stages whose FROM is a Chainguard image use apk. Never emit
`apt-get` into a Chainguard stage or `apk` into a stage that (before
migration) you are still reasoning about as Debian or Fedora — the command
does not exist there and the build fails.

## Name tables

Debian/Ubuntu → Wolfi:

| Debian/Ubuntu | Wolfi |
|---------------|-------|
| `libssl-dev` | `openssl-dev` |
| `build-essential` | `build-base` |
| `python3-pip` | `py3-pip` |
| `python3-dev` | `python3-dev` |
| `libpq-dev` | `libpq-dev` |
| `libffi-dev` | `libffi-dev` |
| `libc6-dev` | `glibc-dev` |
| `pkg-config` | `pkgconf` |
| `ca-certificates` | (skip — preinstalled) |

Alpine → Wolfi (most names map 1:1; Wolfi uses glibc, not musl, so binaries
compiled against musl may need recompilation):

| Alpine | Wolfi |
|--------|-------|
| `musl-dev` | `glibc-dev` |
| `alpine-sdk` | `build-base` |
| `libressl-dev` | `openssl-dev` |

Fedora/RHEL → Wolfi:

| Fedora/RHEL | Wolfi |
|-------------|-------|
| `openssl-devel` | `openssl-dev` |
| `libffi-devel` | `libffi-dev` |
| `zlib-devel` | `zlib-dev` |
| `gcc-c++` | `gcc` (g++ is included) |
| `shadow-utils` | `shadow` |
| `hostname` | (BusyBox provides it) |

These tables are starting points. Confirm every translated name with
`scripts/apk-lookup.sh` before building — a wrong guess costs a failed build,
which is slower than the lookup.

## User and group creation

Alpine's BusyBox `adduser`/`addgroup` flags differ from the standard shadow
tools. Translate to the `shadow` package's `useradd`/`groupadd`, which behave
the same across Wolfi images:

- `addgroup -g GID name` → `groupadd -g GID name`
- `adduser -u UID -G group -D user` → `useradd -u UID -g group -m -s /bin/sh user`
- `adduser -S -G group user` → `useradd -r -g group -s /sbin/nologin user`

Correct:

```dockerfile
# Original (Alpine):
# RUN addgroup -g 1000 appgroup && adduser -u 1000 -G appgroup -D appuser
RUN apk add --no-cache shadow && groupadd -g 1000 appgroup && useradd -u 1000 -g appgroup -m -s /bin/sh appuser
```

Wrong (Alpine flags passed to a base where adduser is BusyBox's variant with
different semantics, or absent in distroless images):

```dockerfile
RUN adduser -u 1000 -G appgroup -D appuser
```

Verify the result, not the process: run `id appuser` in the built image
rather than re-reading the RUN line.

## Validating names before building

Builds cost 30–60 seconds each; a name lookup costs two. Validate every
translated package name with `scripts/apk-lookup.sh` before the build:

1. Exact name: `scripts/apk-lookup.sh exact <name>` (batch several names in
   one call: `scripts/apk-lookup.sh exact pkg1 pkg2 pkg3`).
2. Not found: try the naming patterns above, then look up again.
3. Still not found: search by what the package provides —
   `scripts/apk-lookup.sh cmd <binary>` (which package provides
   `/usr/bin/<binary>`) or `scripts/apk-lookup.sh so <libname.so.N>` (which
   package provides a shared library).
4. Only build after every name in the line resolves.

When a package has no Wolfi equivalent at all, decide with the user whether
to drop it, build it from source in a builder stage, or stop. If it is
dropped, apply the internal-consistency rule in
`references/users-entrypoints-paths.md`.

## Version pinning

Wolfi is a rolling distribution: there are no frozen release trees, and
version-pinned installs (`apk add package=1.2.3-r0`) break when the pinned
build rotates out of the index. Default: translate pinned Debian/Alpine
versions to unpinned Wolfi installs and record the substitution in the
report. Exception: when the user explicitly requires a version lock, keep the
pin and warn that it will need maintenance.

## Language package managers

When the Dockerfile runs `pip`, `npm`, or `mvn`, the base-image migration
does not touch those dependencies — they still resolve from public indexes.
Add one line to the report pointing the user at Chainguard Libraries
(libraries.cgr.dev) for the language-dependency side. Nothing more; Libraries
setup is out of scope for this skill.
