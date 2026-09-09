# Users, entrypoints, and paths

## Contents

- [USER discipline](#user-discipline)
- [File ownership for the non-root user](#file-ownership-for-the-non-root-user)
- [Internal consistency when a package is dropped](#internal-consistency-when-a-package-is-dropped)
- [ENTRYPOINT and CMD on purpose-built images](#entrypoint-and-cmd-on-purpose-built-images)
- [Do not add base-image defaults the original overrides](#do-not-add-base-image-defaults-the-original-overrides)
- [Postgres init scripts](#postgres-init-scripts)
- [PHP and composer](#php-and-composer)

## USER discipline

Most Chainguard images run as a non-root user (usually UID 65532, named
`nonroot` in many images, `node` in the node image, and so on). Read the
actual value from the chosen image's config:

```sh
docker inspect --format='{{.Config.User}}' cgr.dev/chainguard/python:latest
```

If the value is empty, the image runs as root and no USER handling is needed.
Otherwise, every RUN that needs root (any `apk add`, most chown/chmod) gets
wrapped in the same emitted block:

```dockerfile
USER root
RUN apk add --no-cache wget
USER 65532
```

The trailing USER restores exactly what `docker inspect` returned — do not
reconstruct it from the original Dockerfile's `useradd` lines or guess a
name. A wrap without the trailing USER silently leaves every later layer, and
the final image, running as root, because `USER root` persists until changed.
When writing new USER or `--chown` values yourself, prefer the numeric UID
over the name — the UID works even where /etc/passwd is absent.

**Stage-end invariant**: however the privileged RUNs were grouped, every
stage that emitted `USER root` at any point must end with the image user
before the next FROM or end of file. If the final stage is
`FROM <alias> AS default` and the aliased stage ended as root, the default
stage inherits root — emit the USER line in the default stage too. A final
image running as root is a security regression that undoes a large part of
the migration's value.

Correct:

```dockerfile
FROM cgr.dev/chainguard/nginx:latest
USER root
RUN apk add --no-cache curl
USER 65532
```

Wrong (later layers and the final image run as root):

```dockerfile
FROM cgr.dev/chainguard/nginx:latest
USER root
RUN apk add --no-cache curl
```

## File ownership for the non-root user

Files created as root in a build stage are unreadable to the runtime user in
the final stage. Set ownership at copy time:

```dockerfile
COPY --from=builder --chown=65532:65532 /app /app
```

The same applies to directories the application writes at runtime
(`mkdir -p /app/data && chown -R 65532:65532 /app/data`). "Permission
denied" at container start is almost always this.

## Internal consistency when a package is dropped

When a package has no equivalent and is dropped, the Dockerfile lines that
existed only for it must go too:

- Remove earlier `ENV` and `ARG` lines that name it.
- Remove symlinks pointing at its binaries.
- Fix or remove later RUN lines that invoke it.

A dropped package with its ENV still set produces a file that builds but
lies: later readers, and the application itself, act on paths that lead
nowhere. When placing helper binaries or symlinks of your own, put them in a
directory the target image's PATH already lists (`docker inspect` shows the
Env including PATH); a binary outside PATH works in your test command with an
absolute path and then fails in the user's entrypoint.

## ENTRYPOINT and CMD on purpose-built images

Purpose-built Chainguard images set ENTRYPOINT to the runtime binary
(`/usr/bin/node`, `/usr/bin/python`, `java`...), not to a shell wrapper. CMD
values are passed as arguments to that ENTRYPOINT. A Dockerfile written for
an upstream image whose entrypoint delegates to CMD breaks silently:

- Original: `FROM node:20-alpine` (entrypoint script delegates to CMD),
  `CMD ["npm", "start"]`
- Migrated to `cgr.dev/chainguard/node` (ENTRYPOINT `/usr/bin/node`): the
  container runs `node npm start`, and node treats `npm` as a script path.

Whenever the migrated FROM is a purpose-built image, read its ENTRYPOINT
with `docker inspect` and check it against the original file's CMD. If the
CMD is not valid arguments to the new ENTRYPOINT, fix it — default: adjust
CMD to be arguments to the entrypoint binary (`CMD ["app.js"]` under the node
entrypoint). Named exception: when the CMD runs a different program entirely
(`npm start`), reset the entrypoint instead:

```dockerfile
ENTRYPOINT []
CMD ["npm", "start"]
```

If the original Dockerfile sets no CMD and no ENTRYPOINT, it inherits the
image's — verify the inherited pair actually starts the application.

Distroless (non-dev) images have no shell, so shell-form instructions
(`CMD npm start` without brackets) cannot run at all — convert to exec form.

## Do not add base-image defaults the original overrides

When replicating the original base image's configuration (USER, ENV, WORKDIR,
CMD, ENTRYPOINT, SHELL), check the whole original Dockerfile first. If the
original sets its own CMD later, do not add a CMD "to match the base" — the
later instruction overrides it and the added line is pure noise. The same for
ENTRYPOINT, USER, WORKDIR, and SHELL. ENV is the exception: base-image
environment variables (PATH additions, `LANG`, interpreter version markers)
can be needed even when the original sets other ENV values, because ENV is
additive rather than overriding.

## Postgres init scripts

Chainguard's postgres image — and images built on it, such as postgis and
timescaledb — reads initialization scripts from `/var/lib/postgres/initdb`,
not upstream's `/docker-entrypoint-initdb.d`. A COPY to the old path
silently no-ops: the image builds, the database starts healthy, and the
schemas and seed data are never applied. Builds and startup probes do not
catch this; only the path rewrite does.

Correct: `COPY schema.sql /var/lib/postgres/initdb/01-schema.sql`
Wrong: `COPY schema.sql /docker-entrypoint-initdb.d/01-schema.sql`

This remap applies only to the postgres family. mysql and mariadb keep
`/docker-entrypoint-initdb.d` — do not rewrite paths for those.

## PHP and composer

The Chainguard `php` image's `-dev` tags include composer. Remove separate
composer installs such as:

```dockerfile
COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer
```

Keeping the line pulls an upstream artifact the image already provides.
