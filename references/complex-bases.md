# Complex base images

A complex base is one that is itself a deep build — robotics and ML stacks
(`ros:foxy`, `tensorflow/tensorflow`), vendor-assembled application images,
or an internal base another team maintains. There is no one-line Chainguard
equivalent, so the migration has to take the base apart.

## Inspect the base first

Pull it and read what it is made of — no Guardener server tools needed:

```sh
scripts/run-bounded.sh --absolute 600 -- docker pull ros:foxy
docker history --no-trunc --format '{{.CreatedBy}}' ros:foxy
docker inspect --format '{{json .Config}}' ros:foxy
```

The pull runs under the workflow's 10-minute pull bound via
`scripts/run-bounded.sh`; `docker history` and `docker inspect` read local
metadata and need no bound.

`docker history` lists the build steps newest-first (reverse it to read in
build order); `docker inspect` gives the user, env, entrypoint, cmd, workdir,
and exposed ports you will need to replicate. For files the history does not
explain, `docker create` a container from the image and `docker cp` the file
out — this never executes the image.

## Choosing a strategy

Default: **upgrade**. Research (with your own web search) whether a newer
upstream version exists whose dependencies align with current Wolfi packages
(Python 3.10+, OpenSSL 3). An EOL base is usually why the stack is hard to
migrate, and moving to a supported version fixes the migration and the
application's maintenance story at once. Upgrading changes the application's
dependencies, so put it to the user before acting on it. When running
unattended, prefer any real migration path — including auto-selecting the
upgrade — over keeping the original image.

Exception — no viable upgrade path: **decompose**. Translate the base's own
build steps (from `docker history`) into Wolfi equivalents, layer by layer,
inside the same migration loop: the base's `apt-get install` lines become
translated `apk add` lines in your Dockerfile, its environment setup becomes
ENV lines, and so on.

When only built artifacts are needed rather than the whole environment,
decompose into a build stage: reproduce the producing steps on an allowed
Chainguard base in a named stage, then `COPY --from=<that-stage>` the
artifacts into the runtime stage. The source stage's FROM must itself pass
the FROM allowlist — never introduce `FROM ros:foxy AS donor` as a copy
source; that reintroduces the upstream image the migration exists to remove.

Correct:

```dockerfile
FROM cgr.dev/chainguard/wolfi-base AS toolbuild
RUN apk add --no-cache build-base cmake git && \
    git clone --depth 1 https://github.com/example/tool /src && \
    cmake -B /build /src && cmake --build /build

FROM cgr.dev/chainguard/wolfi-base
COPY --from=toolbuild /build/tool /usr/local/bin/tool
```

Wrong (an upstream image smuggled back in as a donor stage):

```dockerfile
FROM ros:foxy AS donor
FROM cgr.dev/chainguard/wolfi-base
COPY --from=donor /opt/ros /opt/ros
```

## When rebuilt binaries misbehave

Rebuilt or repackaged binaries hitting SONAME or runtime-version mismatches
(a library compiled against a different glibc or OpenSSL) is a signal to stop
hand-porting and use a language-level or cross-distro package manager the
project supports — pip wheels, conda, or pixi — installed inside the
Chainguard stage. Research the project's supported install paths before
building more of the stack by hand.
