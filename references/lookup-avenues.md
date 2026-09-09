# Lookup avenues

Every data question the migration asks, with one default command and one
named exception. The skill's rules all live in this directory; only data —
package indexes, image configs, tag lists, SBOMs — comes from the network.

## Contents

- [Does package X exist? What provides binary or library Y?](#does-package-x-exist-what-provides-binary-or-library-y)
- [Does image X exist in a Chainguard registry, and which tags?](#does-image-x-exist-in-a-chainguard-registry-and-which-tags)
- [Does image X exist on the external mirror, and what is its digest?](#does-image-x-exist-on-the-external-mirror-and-what-is-its-digest)
- [What is an image's user, entrypoint, cmd, env, workdir?](#what-is-an-images-user-entrypoint-cmd-env-workdir)
- [Debian or Fedora package name to Wolfi name?](#debian-or-fedora-package-name-to-wolfi-name)
- [Compare two images?](#compare-two-images)
- [Org tokens](#org-tokens)

## Does package X exist? What provides binary or library Y?

Default: `scripts/apk-lookup.sh`, which runs apk inside a Chainguard
container against the same index the migrated build will use:

```sh
scripts/apk-lookup.sh exact shadow            # exact name, exit 1 if absent
scripts/apk-lookup.sh exact curl git jq       # batch: one container run
scripts/apk-lookup.sh search openblas         # substring search
scripts/apk-lookup.sh cmd useradd             # which package provides a binary
scripts/apk-lookup.sh so libssl.so.3          # which package provides a library
scripts/apk-lookup.sh --org example-org exact mypkg   # org index, authenticated
```

The public index (apk.cgr.dev/chainguard) needs no auth. An organization
index needs a token — the script mints and passes it itself; see
[Org tokens](#org-tokens).

Exception: when the agent has the cg-apk MCP server
(`cg-apk:search_packages`), use it for name lookups. It has no
provides-search, so `cmd:` and `so:` questions still go through the script.

If Docker cannot run a lookup container at all (it can, if preflight passed),
the raw index is at `https://apk.cgr.dev/chainguard/<arch>/APKINDEX.tar.gz` —
download, extract, and grep the APKINDEX text for `P:<name>` entries.

## Does image X exist in a Chainguard registry, and which tags?

Default: chainctl. Tag listings include the digest per tag, which is what the
digest rule pins.

```sh
chainctl images repos list --public --repo python     # does the repo exist (public catalog)
chainctl images tags list --public --repo python      # tags + digests (public catalog)
chainctl images repos list --parent example-org --repo python   # org catalog
chainctl images tags list --parent example-org --repo python
```

Exception: the cg-oci MCP server (`cg-oci:list_tags`, `cg-oci:get_config`)
when present. Prefer single-image lookups over unbounded catalog listings in
either avenue — enumerate a specific repo's tags, not the whole org.

## Does image X exist on the external mirror, and what is its digest?

Default, and only avenue: docker.

```sh
docker pull my-corp.example.io/chainguard-remote/python:latest-dev
docker inspect --format '{{index .RepoDigests 0}}' my-corp.example.io/chainguard-remote/python:latest-dev
```

If RepoDigests is empty, the mirror reports no digest — drop the digest from
the migrated FROM and record a warning. There is no exception: chainctl and
the Chainguard MCP servers do not index arbitrary mirrors, so asking them
about a mirror path returns nothing useful.

## What is an image's user, entrypoint, cmd, env, workdir?

Default: pull and inspect.

```sh
docker pull cgr.dev/chainguard/python:latest
docker inspect --format '{{json .Config}}' cgr.dev/chainguard/python:latest
```

The `.Config` object carries User, Env (including PATH), Entrypoint, Cmd,
WorkingDir, ExposedPorts, Volumes, Labels, and Shell — everything the
config comparison and the USER discipline need.

Exception: `cg-oci:get_config` when the MCP server is present, which answers
without pulling the image.

## Debian or Fedora package name to Wolfi name?

Default: the tables and rename patterns in
`references/package-translation.md`, confirmed with `scripts/apk-lookup.sh` —
the table proposes, the index disposes.

Exception: when the open-source dfc CLI is installed, its built-in mappings
answer the same question (`dfc ./Dockerfile` applies them wholesale; see the
optional draft step in SKILL.md).

## Compare two images?

Default, and only avenue: `scripts/compare-images.sh <original> <migrated>`.
It inventories packages via an SBOM scan (syft binary if installed, else a
syft container over a `docker save` archive) and files and shared libraries
via `docker create` + `docker export` — it never executes anything inside
either image, because distroless runtime images have no shell to execute
with. If no scanner path works, the script exits non-zero and says the
comparison was not performed; treat that as a failed gate, never as "no
differences".

## Org tokens

An organization's apk index requires auth. Mint a short-lived token and pass
it as an environment variable:

```sh
HTTP_AUTH="basic:apk.cgr.dev:user:$(chainctl auth token --audience apk.cgr.dev)"
```

`apk-lookup.sh --org <org>` does exactly this and exports HTTP_AUTH into the
lookup container's environment. Never echo the token, never write it to a
file, never put it on a command line where other processes can read it —
passing it as an inherited environment variable to `docker run -e HTTP_AUTH`
(value taken from the environment, not the command line) keeps it out of
process listings.
