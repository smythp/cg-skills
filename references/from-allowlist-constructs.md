# Constructs that decide what a FROM resolves to

The FROM gate exists to catch mistakes in a migration, not to guarantee
that a Dockerfile written to defeat it cannot pass; the oracle decides
with BuildKit's own resolution, and the textual check advises.

The gate is two scripts. `scripts/check-from-lines.sh` reads every FROM
line textually, reachable or not, by reimplementing the parsing rules
below. It exits 1 with a REJECTED line only for a base known to resolve
outside the allowlist; a construct it cannot verify is reported on an
UNVERIFIED line for the report's Warnings and the run exits 3, with the
oracle deciding what the build resolves. In the tables below, a Gate cell
saying "same" is a rule the textual check implements as BuildKit does
(verified), "hard" is a REJECTED exit 1, and "advisory" is an UNVERIFIED
exit 3.

`scripts/check-from-oracle.sh` asks BuildKit itself, in two bounded calls.
`timeout -k 30 600 docker buildx build --call=targets,format=json
--progress=plain` returns every stage with its base exactly as written,
from BuildKit's own parse; the script expands each base with the rules
below (global ARGs, the user's overrides, the automatic arguments as
seeded with a declared default beating the seeded value and a --build-arg
beating both, single-quoted defaults literal), substitutes the named build
contexts, and requires every base in that FROM set to be on the allowlist,
failing closed on anything it cannot expand or classify. Then
`timeout -k 30 600 docker buildx build --call=outline,format=json
--progress=plain` resolves the file; any line containing "load metadata
for" is a reference whatever its bracketed step label, a load matching the
FROM set is a base already checked, and every other load is printed as a
WARNING naming it an external artifact source with the linkage reason and
allowed (see the artifact sources section),
unless the file has no instruction that can pull an image other than FROM,
in which case such a load fails the run, the
fallback for any divergence between the oracle's scan and the frontend:
REJECTED when the load is off the allowlist, because the build really
resolves it there whatever the scan misread, and a refusal naming an
unexplained load when it is on the allowlist, since an allowed load is
not a rejected base but the disagreement is not a pass either.
The scan reads parser directives as the textual gate does (VT and FF
normalized to spaces); a syntax directive pinning a frontend runs under
that frontend with one WARNING that the expansion assumes the rolling
syntax, and a pin whose frontend cannot answer the subrequests is not a
pass.
Both calls must show positive evidence they ran (the load-build-definition
step plus their JSON result), and the script refuses to answer when a
BuildKit source policy
is configured in the environment. The oracle
covers every stage the file declares, like the textual check. The oracle's
OK plus no textual REJECTED lets the run proceed; the textual check's
UNVERIFIED lines are carried into the report's Warnings.

Sourcing the options for both scripts in step 9: pass `--platform` from
the captured invocation, or the daemon's default from
`docker version --format '{{.Server.Os}}/{{.Server.Arch}}'` when the
invocation names none, because BuildKit sets the automatic platform
arguments on every build and a FROM can read them; when the invocation
lists several platforms, run the gate once per platform. Pass every
`--build-arg` and every `--build-context` from the captured invocation,
exactly as captured: the build honors the overrides over the Dockerfile's
ARG defaults, and BuildKit replaces a FROM whose reference or stage name
matches a context name, so a gate run without them checks a different
file than the one being built. When the invocation has `--target`, pass
it too, and when the build platform differs from the target platform, add
`--build-platform` with the daemon's platform.

Every construct below was enumerated from the Dockerfile frontend vendored
in the Docker 29.8 daemon (BuildKit's `frontend/dockerfile` at the moby
commit the daemon ships), and every fixture's expected result was checked
against that daemon before it was written. The fixture names refer to
`scripts/tests/test-check-from-lines.sh`.

## Contents

- [Tokenization and quoting on heredoc lines](#tokenization-and-quoting-on-heredoc-lines)
- [Heredoc forms](#heredoc-forms)
- [Escape directive and line continuation](#escape-directive-and-line-continuation)
- [Parser directives](#parser-directives)
- [Physical line structure](#physical-line-structure)
- [ARG scope and overrides](#arg-scope-and-overrides)
- [Automatic platform arguments](#automatic-platform-arguments)
- [Variable expansion forms](#variable-expansion-forms)
- [FROM syntax](#from-syntax)
- [Named build contexts](#named-build-contexts)
- [Artifact sources](#artifact-sources)

## Tokenization and quoting on heredoc lines

BuildKit finds heredoc markers by lexing the whole logical RUN, COPY, ADD,
or ONBUILD line into shell words and testing each word. The lexer hardcodes
backslash as its escape character, even when the escape directive selects
the backtick.

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| `<<` inside double quotes | plain text, no heredoc | same | heredoc marker inside double quotes is plain text |
| `<<` inside single quotes | plain text, no heredoc | same | heredoc marker inside single quotes is plain text |
| real heredoc after a quoted string on the same line | heredoc opens | same | real heredoc after a quoted string still opens |
| escaped quote before a marker (`\" <<EOF`) | quote is escaped, heredoc opens | same | escaped quote before a heredoc marker |
| backslash under `# escape=`` ` on a heredoc line | still the heredoc lexer's escape | same | heredoc lexing escapes with backslash even under escape=backtick |
| unbalanced quote on a heredoc-capable line | lexer errors, silently scans no heredocs | advisory naming the line, then no heredoc opens there, matching BuildKit, and the scan continues | unbalanced quote alone is unverified; unbalanced quote then a bad FROM is still rejected |
| `${...}` beyond `${NAME}`, `${NAME:-word}`, `${NAME:+word}` on a heredoc-capable line | value can shift word boundaries or disable the heredoc scan | advisory naming the expansion; the scan stops there, because later lines cannot be told apart from heredoc content | expansion with whitespace on a heredoc line is unverified |
| Unicode space character on a heredoc-capable line | splits words like ASCII space | advisory naming the line; the scan stops there | Unicode space bespoke case |

## Heredoc forms

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| `<<NAME`, `<<-NAME`, `<<'NAME'`, `<<"NAME"` | heredoc; body is content, not instructions | same | single-quoted heredoc name is recognized and terminated, double-quoted heredoc name is recognized (existing) |
| `2<<NAME` file descriptor prefix | heredoc | same | file-descriptor heredoc marker is recognized (existing) |
| `<< NAME` separated | whitespace glued, heredoc | same | separated << NAME heredoc is recognized (existing) |
| `<<- NAME` separated | not a heredoc | same | separated <<- NAME is not a heredoc (existing) |
| `<< -NAME` | heredoc named -NAME | same | separated delimiter starting with a dash |
| bare `<<` at end of line | not a heredoc | same | bare << at end of line is not a heredoc |
| marker whose rest contains `<` | not a heredoc | same | marker with an additional < is not a heredoc |
| delimiter line with trailing whitespace | does not terminate | same | delimiter line with trailing whitespace does not terminate (existing) |
| `<<-` tab chomping of the delimiter | tabs stripped before comparison | same | tab-indented delimiter ends a <<- heredoc (existing) |
| two heredocs on one line | bodies consumed in order | same | COPY with two heredocs consumes both bodies in order (existing) |
| heredoc on a continued line | detected on the joined line | same | heredoc on a continued instruction line (existing) |
| ONBUILD RUN/COPY/ADD heredoc | heredoc like the plain forms | same | ONBUILD heredoc body is content |
| unterminated heredoc | build error | advisory (the build pulls nothing) | unterminated heredoc is unverified |
| marker with `$`, mixed quotes, or other unusual delimiters | delimiter still parsed | advisory naming the marker; the scan stops there | heredoc marker with a dollar sign is unverified |
| FROM inside a heredoc body | content, registers nothing | same | heredoc body cannot launder a stage alias (existing) |

## Escape directive and line continuation

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| `# escape=\` or `` # escape=` `` | sets the continuation escape | same | escape directive enables backtick continuation (existing) |
| invalid escape value | build error | advisory, the previous escape character is kept | invalid escape directive value is unverified |
| line ending in two escape characters | no continuation | same | line ending in two escape characters does not continue (existing) |
| trailing whitespace after the escape | still continues | same | trailing whitespace after the escape still continues (existing) |
| joined lines | concatenated with no separator | same | continuation joins without a separator (existing) |
| blank line inside a continuation | warning, continuation goes on | same | empty continuation line does not end the instruction (existing) |
| comment line inside a continuation | dropped, continuation goes on | same | comment inside a continuation does not end it |

## Parser directives

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| UTF-8 byte order mark before directives | discarded | same | byte order mark bespoke case |
| leading whitespace before a directive | allowed | same | parser directive with leading whitespace is honored |
| directive keys case-insensitive | honored | same | escape directive key is case-insensitive (existing) |
| `# check=...` | known key, block continues | same | check directive does not end the directive block |
| unknown key or plain comment | ends the directive block | same for a plain comment; a line in directive shape with an unknown key is advisory naming the key, then read as the comment the rolling frontend reads it as | escape directive after a plain comment is inert (existing); unknown directive-shaped key is unverified |
| duplicate directive | build error | advisory, the first value is kept | duplicate escape directive is unverified |
| `# syntax=` with any value other than the rolling `docker/dockerfile:1` tag (an optional `docker.io/` prefix allowed), matched byte for byte | replaces the parser with the pin's rules. Under 1.0 a heredoc body is ordinary instructions (a real build of the reproduction fails on unknown instruction EOT) and subrequests are unsupported; under 1.4.0 buildx answers the subrequests through a different frontend (docker/dockerfile:1.8.1 by digest, re-confirmed 2026-09-17); 1.6 answers them itself; 1.99 fails to pull; an uppercase spelling is an invalid reference | advisory in the textual check, naming the pin, with the rest of the file read under the rolling rules as a best effort; the oracle runs the pinned frontend with one WARNING and is not a pass when the frontend cannot answer the subrequests | non-rolling syntax directive is unverified; pinned rolling-era frontend with a Chainguard FROM is unverified; rolling syntax tag with the docker.io prefix is accepted; pinned syntax tag 1.0 is unverified before heredoc parsing; pinned syntax tag 1.3 is unverified; pinned syntax tag 1.4.0 is unverified; pinned syntax tag 1.99 is unverified; uppercase syntax directive value is unverified; oracle cases 1f and 1g; oracle shim case: a pinned syntax directive runs both calls with one warning |
| VT or FF inside a parser directive line | treated as whitespace, the directive is honored | same, both scripts normalize them to spaces before the match | oracle test case 11 (a VT-prefixed escape directive resolves alpine through the continuation it enables) |

## Physical line structure

Both scripts scan the raw bytes (through od, before awk reads the file)
for a NUL anywhere and a CR that is not immediately followed by LF, naming
the line. BuildKit keeps both bytes inside the surrounding line where a
line reader would split it, so the textual check reports the byte as
advisory without scanning the file, and the oracle refuses to answer,
because its own expansion scan is line-based too.

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| CRLF line endings | accepted, the CR leaves with the LF | same | CRLF line endings are accepted |
| CR not followed by LF inside a line | kept in the line; the two-FROM reproduction fails with "FROM requires either one or three arguments" | advisory naming the line, without scanning; the oracle exits 1 | bare CR joining two FROMs is unverified |
| NUL byte | kept in the line; the reproduction fails the same way | advisory naming the line, without scanning; the oracle exits 1 | NUL byte in a FROM line is unverified |
| CR as the final byte with no LF | accepted as an ordinary line ending | advisory naming the line, without scanning (a record reader cannot tell it from a CRLF ending) | CR as the final byte with no LF is unverified |

## ARG scope and overrides

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| global ARG before the first FROM | usable in FROM resolution | same | public cgr.dev via ARG default is allowed (existing) |
| ARG after a FROM | stage scope, not FROM resolution | same | stage ARG cannot override global ARG used by later FROM (existing) |
| bare redeclaration after a FROM | reuses the global value inside the stage | same | global ARG default can be reused by a later FROM (existing) |
| several assignments on one ARG line | all processed | same | second assignment on an ARG line is processed (existing) |
| `--build-arg` override of a declared ARG | beats the default | same | build-arg override to a forbidden registry is rejected (existing) |
| `--build-arg` with no declaration | ignored (automatic arguments excepted) | same | build-arg with no matching ARG declaration is ignored (existing) |
| quoted value spanning whitespace, escape characters in ARG tokens | reassembled by the parser (real builds pin both directions: ARG A="x y" B=alpine assigns B, ARG OTHER=a\ B=alpine swallows B= into the value of OTHER, and the reassembled line reassigns names earlier lines declared: ARG BASE=alpine then ARG OTHER="x y" BASE=cgr.dev/chainguard/wolfi-base resolves the Chainguard base, pinned); a `--build-arg` applies only to a name the file declares with a global ARG, so it beats whatever such a line assigns a declared name while a name the file never declares ignores it (both pinned) | advisory naming the token; every later variable read is unverified until the name is assigned again, the value an earlier line gave a name included, so a FROM reading a variable after such a line is unverified while a literal FROM stays verifiable; a `--build-arg` override keeps a name certain through such a line only when a trusted line already declared it, and a name declared only on the unverifiable line, or not yet declared, is unverified until a trusted line declares it and the override value applies from there | quoted ARG value spanning whitespace is unverified; variable FROM after an unverifiable ARG line is unverified; assignment after an unverifiable ARG line is certain again; tainted ARG line does not leave an earlier value trusted; override of a name declared only on an unverifiable line is unverified; override of a name the unverifiable line may not declare is unverified; ARG default reading an override the taint covers is unverified; the bespoke case that an overridden name declared by a trusted line stays certain; escape character in an ARG value is unverified; variable FROM after an escaped ARG line is unverified |

## Automatic platform arguments

BuildKit seeds TARGETPLATFORM, TARGETOS, TARGETARCH, TARGETVARIANT,
TARGETOSVERSION, TARGETSTAGE, BUILDPLATFORM, BUILDOS, BUILDARCH,
BUILDVARIANT, and BUILDOSVERSION in the global scope on every build. The
textual gate seeds the same values from `--platform`, `--build-platform`,
and `--target`; the oracle passes them to BuildKit as explicit overrides,
because buildx 0.37 drops `--platform` on `--call` runs (verified on both
the docker driver and a docker-container builder, for `--call=outline` and
`--call=targets` alike). BuildKit lets a global ARG that declares a
default for one of these names beat the automatic value, while a
`--build-arg` beats the default (each pinned with real builds, TARGETSTAGE
against `--target` included), and both scripts apply that precedence: the
textual gate lets the declared default replace its seeded value, and the
oracle omits the synthetic override for a name the file gives a declared
default, so BuildKit applies the default exactly as the real build does.
A bare redeclaration is not a default and keeps the automatic value.
The omission is faithful only while no read of the name sits above its
declaring line; the oracle refuses that order, and a self-referential
default, instead of answering (the row below).

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| automatic argument read by a global ARG default or FROM | value available undeclared | seeded with --platform; advisory asking for --platform without it (the oracle exits 1 asking the same) | automatic TARGETARCH reaches a global ARG default; automatic platform argument without --platform is unverified |
| `$BUILDPLATFORM` inside a FROM `--platform=` flag | names a manifest platform, not an image | flag skipped, no --platform needed | BUILDPLATFORM in a FROM flag needs no --platform |
| TARGETVARIANT on a variantless platform | set to the empty string; `:-` and `:+` treat empty as unset | same | TARGETVARIANT is empty-set on a variantless platform |
| platform normalization | containerd platforms.Normalize: x86_64 and x86-64 to amd64, aarch64 to arm64, i386 to 386 dropping any variant, armhf to arm/v7 and armel to arm/v6 replacing any variant, amd64 drops a v1 variant, arm64 drops an 8 or v8 variant, bare arm gains v7, the numeric arm variants 5, 6, 7, 8 gain the v prefix, every other variant passes through | same rules | amd64/v1 normalizes to an empty TARGETVARIANT; amd64/v2 keeps its TARGETVARIANT; arm64/v8 and arm64/8 normalize to an empty TARGETVARIANT; bare arm gains the v7 variant; arm/5 through arm/8 normalize to the v5 through v8 variants; arm/v8 keeps its TARGETVARIANT; x86_64 and x86-64 normalize to amd64; aarch64 normalizes to arm64; armhf normalizes to arm/v7 (with or without a variant); armel normalizes to arm/v6; i386 normalizes to 386 and drops any variant; arm/v7 keeps its TARGETVARIANT |
| bare global `ARG TARGETARCH` | keeps the automatic value | same | bare global ARG redeclaration keeps the automatic value |
| global `ARG TARGETARCH=value` | the default replaces the automatic value; a --build-arg replaces the default (pinned with real builds) | applied with the same precedence in both scripts; the oracle omits the synthetic override for the name, so the frontend applies the declared default; hard only when the resolved base is off the allowlist | declared default for an automatic argument resolves the FROM; benign declared default on an automatic argument passes; benign declared default read by the FROM passes; declared automatic default with a single-quoted literal resolves alpine (amd64, arm64); oracle cases 1d and 1d2; oracle shim case: a declared automatic default omits its synthetic override |
| declared default below a line that already reads the name, or a default that reads its own name | the read takes the automatic value and the declaration replaces it from its line onward (a real arm/v7 build of `ARG BASE=${TARGETVARIANT:+cgr.dev/chainguard/wolfi-base}`, `ARG TARGETVARIANT=`, `FROM ${BASE:-alpine}` resolves the Chainguard base, pinned, the self-referential shape likewise) | the textual gate applies the same per-line precedence; the oracle cannot reproduce that order in one buildx call, so it exits 1 naming the argument and both lines, and declaring the default above its first use lets the gate run. A read inside the default of a global ARG the user overrides with `--build-arg` does not count, because the override replaces that default and the automatic value never reaches the build through it (a real build of `ARG BASE=${TARGETARCH}`, `ARG TARGETARCH=amd64`, `FROM ${BASE}` with the BASE override resolves only the override value, pinned); a read in a FROM line, or in the default of a name without an override, still counts | oracle cases 1h, 1i, and 1j |
| `--build-arg TARGETARCH=...` undeclared | overrides the automatic value | same | build-arg overrides an automatic argument undeclared |
| BUILD* on a cross-platform build | the builder's own platform | target platform unless --build-platform is passed; a documented deviation | BUILDARCH follows --build-platform on a cross build; BUILDARCH defaults to the target platform without --build-platform |
| TARGETSTAGE | the --target stage name, else the final stage's; a declared default beats it | seeded from --target; advisory asking for --target when read without it (the oracle exits 1 asking the same) | TARGETSTAGE carries the --target stage name; TARGETSTAGE without --target is unverified |
| multi-platform `--platform` value | one frontend evaluation per platform | exit 2, run once per platform | multi-platform value is refused |

## Variable expansion forms

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| `$NAME`, `${NAME}` | expanded | same | public cgr.dev via ARG default is allowed (existing) |
| single-quoted ARG default (`ARG A='${X}'`) | kept literal, no expansion inside single quotes; double-quoted and unquoted defaults expand | same | single-quoted ARG default keeps its variable text literal; oracle test case 1e |
| `${NAME:-default}` | default when unset or empty | same | colon-dash default applies when unset (existing) |
| `${NAME:+alt}` | alt when set and non-empty | same | colon-plus substitutes when set (existing) |
| `${NAME-d}`, `${NAME+a}` colon-less | unset test only, empty counts as set | advisory naming the modifier, and the value is unknown from then on | colon-less minus modifier is unverified, not emulated |
| `${NAME%pat}`, `${NAME#pat}`, `${NAME/p/r}`, `${NAME:?}` and the rest | expanded per shell rules | advisory naming the modifier, never expanded to an empty string; a FROM reading the value is unverified too (the oracle exits 1 on the modifier) | unsupported modifier in FROM is unverified, not emptied |
| variable in a FROM ref that no global ARG and no override gives a value | expands to the empty string (FROM alpine${UNSET} resolves docker.io/library/alpine, pinned with a real build), and a wholly empty base fails the build (base name should not be blank, pinned) | the same expansion; the reference that remains is classified like any other, hard when it is off the allowlist, and a reference that expands wholly empty is advisory naming the empty result (the oracle exits 1, unable to expand the FROM set) | undeclared variable suffix leaves alpine and is rejected; FROM that expands to an empty base is unverified; FROM of an undeclared variable is an empty base, unverified; empty expansion inside a cgr.dev path is unverified; empty expansion at the start of a FROM is unverified |

## FROM syntax

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| instruction keywords in any case | case-insensitive | same | lowercase from is still a FROM |
| FROM flags (`--platform=...`) | consumed before the reference | skipped the same way | platform flag with cgr image is allowed (existing) |
| reference with tag | resolved as written | prefix-checked as written | public cgr.dev/chainguard is allowed (existing) |
| reference with tag and digest | resolved as written | prefix-checked as written | digest-pinned cgr.dev reference is allowed |
| reference outside the distribution grammar: an invalid tag or digest (`alpine:--`, `alpine@sha256:zzz`), a path component outside lowercase alphanumerics joined by a single dot, a single underscore, a double underscore, or one or more hyphens (`alpine..x`, an uppercase component), a host with a non-numeric port or a malformed domain (`example.com:abc/alpine`), or a normalized path over 255 characters, the domain excluded | fails to parse the stage name with invalid reference format (each shape pinned with real builds, the 255-character path boundary on both sides); a valid host with a numeric port (`localhost:5000/alpine`) parses and pulls | advisory naming the reference, never hard, because no base pulls from a reference BuildKit refuses; an allowed prefix is not vouched for either when the reference is invalid, and both scripts apply the same grammar in norm_ref (the oracle refuses a FROM-set member outside it by name, with no REJECTED line) | invalid tag is a reference BuildKit refuses, unverified; malformed digest is a reference BuildKit refuses, unverified; double-dot path component is a reference BuildKit refuses, unverified; double-dot component under the allowlist prefix is unverified; non-numeric registry port is a reference BuildKit refuses, unverified; non-numeric port on the allowlist host is unverified; uppercase path component is a reference BuildKit refuses, unverified; uppercase path component under the allowlist prefix is unverified; valid numeric registry port off the allowlist is rejected; normalized path of exactly 255 characters off the allowlist is rejected; normalized path over 255 characters is a reference BuildKit refuses, unverified; empty expansion inside a cgr.dev path is unverified; oracle shim cases: a FROM member outside the reference grammar is refused, not REJECTED |
| one pair of quotes around the reference | quotes stripped | advisory, a quoted spelling is not a reference this check verifies (the oracle refuses the JSON escape the quotes become in the targets output) | quoted FROM reference is unverified |
| backslashes and quotes elsewhere in a reference | processed by the shell lexer; a real build of `FROM my\ncorp.example.io/cg/python:latest-dev` strips the backslash and loads myncorp.example.io/cg/python:latest-dev, a host the written spelling does not name (pinned) | passed through textually; a backslash never passes the reference grammar, so such a spelling is advisory, never an OK an allowed prefix vouches for and never a REJECTED | mirror value with a backslash sequence is not decoded |
| FROM token count after flags | one image reference, or reference AS name; every other count fails with "FROM requires either one or three arguments" (three tokens whose middle one is not AS draw the same message) | advisory quoting the line, because no base pulls from a line BuildKit fails | FROM with two extra tokens is unverified; FROM followed by a bare AS is unverified; FROM with a reference and an AS name stays allowed |
| `AS alias` stage names | letters, digits, `_ . -`, starting with a letter; case-insensitive reuse | same; an alias outside the shape is hard, because the alias table decides what every later FROM means | image-shaped alias with slash is rejected (existing) |
| FROM of an earlier alias | stage reference, not a pull | same | stage alias is allowed (existing) |
| FROM of a later stage (forward reference) | stage reference too; BuildKit resolves stage names anywhere in the file (verified with an outline run that loads only the later stage's base) | advisory, decided at the end of the scan when every stage name is known, because a sequential scan cannot verify a forward reference; the oracle treats a base matching any other stage's name as a stage reference | forward stage reference is unverified (lines suite); oracle test case 12: a forward stage reference is a stage reference, not a pull; oracle shim case: a base naming an earlier stage is an alias, not a pull |
| a base identical to its own stage name (`FROM alpine AS alpine`) | a stage cannot be its own base, so the name resolves to the image; with another stage of that name it resolves to that stage | both scripts treat it as a pull and check the allowlist, hard when it is off the list | oracle live case: the self-named stage is rejected; a base naming a sibling stage passes; a base identical to its own stage name is rejected (lines suite) |
| `scratch` | the empty base for the lowercase spelling only, no metadata load; FROM SCRATCH fails to parse as a stage name (repository name library/SCRATCH must be lowercase) | matched case-sensitively; another spelling is a reference, hard when BuildKit accepts it and the allowlist does not, advisory when BuildKit refuses it, because nothing pulls from it | scratch is allowed (existing); FROM SCRATCH is unverified as a reference BuildKit refuses |
| BuildKit source policy (`EXPERIMENTAL_BUILDKIT_SOURCE_POLICY` in the environment) | converts a reference after the log names the original | the oracle exits 1 naming the variable when it is set; the textual gate reads no environment beyond its own inputs | source policy shim case in test-check-from-oracle.sh |

## Named build contexts

Both scripts take a repeatable `--build-context NAME=SOURCE`, and step 9
passes every named context from the captured invocation to both. BuildKit
matches a context name against the expanded FROM reference and against
stage names after docker reference normalization on both sides, and it
applies a name matching a stage's AS name at the stage's definition,
replacing that stage's base even when no FROM references the name, so a
gate run without the contexts checks a different base than the build
resolves.
The oracle passes each context through to buildx unchanged; the overridden
load prints as `#N [context NAME] load metadata for REF`, which the
label-agnostic parsing reads like any other reference. Every rule below
was pinned with an outline run, and the scratch row with a real cacheonly
build, on Docker 29.8.0 with buildx v0.37.0.

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| context name matching a FROM reference | the docker-image:// source replaces the base; other source kinds (local directory, git, oci-layout, target) build the base from that source; an empty or invalid docker-image:// reference fails the build with invalid reference format (pinned for an empty reference and for alpine:--) | docker-image://REF puts REF through the allowlist in place of the FROM after checking REF parses, hard when a valid REF is off the list; an empty or invalid REF is advisory naming it in the textual check (the oracle refuses it by name), and any other source kind for a FROM name is advisory in the textual check, because the base has no registry reference to verify, and the oracle exits 1 on it | build context overriding a Chainguard FROM to alpine is rejected; build context overriding a FROM to another Chainguard image is allowed; local-directory context for a FROM name is unverified; empty docker-image context source is unverified; invalid docker-image context source is unverified; invalid docker-image source for a stage name is unverified; oracle test case 6; oracle shim cases: invalid and empty docker-image context references are refused by name |
| matching normalization | reference normalization on both sides: a bare name gains docker.io/library/ and :latest, index.docker.io maps to docker.io only in that exact lowercase spelling, the host keeps its case from splitDockerDomain and compares byte-exact, and a dotless first component that is not all-lowercase is a domain (Foo/bar is domain Foo, path bar) | same rules in norm_ref, shared by both scripts | context name with a tag matches an untagged FROM; fully qualified context name matches a short FROM; index.docker.io context name matches a short FROM; context name with a different tag does not match; uppercase-host context name does not match a lowercase FROM; lowercase-host context name matches the FROM the uppercase one missed; uppercase index.docker.io context name does not map or match; dotless uppercase first component is a domain and matches its context; lowercased context does not match an uppercase-domain FROM; oracle test case 10 |
| matching against the expanded reference | the context match sees the FROM after ARG expansion | same | context matching happens after ARG expansion |
| context name matching a stage name | applied at the stage's definition: the stage's base is replaced even when no FROM references the name, with reference normalization on the name, and the stage-name match beats a context matching the base reference; at a FROM, the context beats the stage wherever it is referenced | same, checked at each AS name and at each FROM; a non-docker-image source for a stage name is advisory in the textual check and exits 1 in the oracle, like the FROM-name row | stage-name context overriding a Chainguard stage to alpine is rejected; stage-name context overriding a stage to a Chainguard image is allowed; normalized stage-name context still overrides the stage; local-directory context for a stage name is unverified; context overriding a stage alias to alpine is rejected; context overriding a stage alias to a Chainguard image is allowed; oracle test case 9 |
| context named scratch | `FROM scratch` stays the empty base; a named context cannot override scratch by the base name, but a context matching the stage's AS name replaces even a scratch base (pinned by a real cacheonly build) | same | scratch cannot be overridden by a context; stage-name context replaces a scratch base |
| digest-pinned FROM | matches a context only on the exact digest string; the bare name does not match | same | context with the exact digest string overrides the FROM; bare context name does not match a digest-pinned FROM |
| repeated context name | the last value wins | same | repeated context name applies the last value (allowed, rejected) |
| context name matching no FROM and no stage name | ignored for bases (a COPY --from source may still use it, including from a local directory) | same | context whose name matches nothing is ignored; local-directory context for a copy source is ignored by the FROM gate |
| context name that is not a valid reference | buildx refuses the invocation (invalid context name: the lowercase repository rule, an invalid tag such as dep:--, both verified) | usage error (exit 2) naming the context in the textual check; the oracle exits 1 | invalid context name is refused as a usage error; context name with an invalid tag is refused as a usage error |

## Artifact sources

`COPY --from=IMAGE`, `RUN --mount=from=IMAGE`, and ADD from an image pull
an external artifact into the build without making it a base.
`references/from-and-registry-rules.md` permits artifact copies, asks the
migration to try the Chainguard image of the same name first, and asks
the report to name what remains, so the gate does not reject them. Only
the FROM set meets the allowlist; the oracle prints every non-base load
as a WARNING naming it an external artifact source with the linkage
reason (a binary copied from another distribution's image links against
that distribution's libraries), but only when the file contains
at least one instruction that can pull an image other than FROM. With
none present, an off-set load fails the run: REJECTED when it is off the
allowlist, an unexplained-load refusal when it is on it.

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| `COPY --from=IMAGE`, `RUN --mount=from=IMAGE`, ADD from an image | a metadata load, indistinguishable from a base load by its step label (verified; both print as [internal]) | the load is matched against the FROM set from the targets call; a non-base load is printed as an external artifact source WARNING with the linkage reason and allowed | oracle test case 7; external COPY --from artifact source is not a base; external RUN mount source is not a base; bracketed-label shim case |
| a reference that is both a FROM base and a copy source | one load serves both | it is in the FROM set, so it is checked as a base; the artifact allowance cannot launder it | a base doubling as a copy source is still a base; oracle test case 7 |
| a load outside the FROM set in a file with no COPY --from= and no RUN --mount= carrying a from= source that could pull an image | only a FROM can have pulled it, so it is a base the scan expanded differently than the frontend | exit 1 naming the load, the fallback for any divergence between the oracle's scan and the frontend: REJECTED when the load is off the allowlist, a refusal naming an unexplained load when it is on it, so the REJECTED line always means a base known off the allowlist | oracle shim cases: off-set load with no artifact-capable instruction is an unexpanded base, allowed off-set load is an unexplained load; the bracketed-label shim case is the artifact-report pair |
| `COPY --from=STAGE`, `RUN --mount=from=STAGE` naming a declared stage | resolves the stage, pulls nothing | not artifact-capable for the fallback count; the source is matched by AS alias case-insensitively and by numeric stage index, after the global ARG expansion the FROM set uses, and mount keys match case-insensitively as BuildKit lowercases them (`FROM=`, `Type=`, and `From=` all build, verified with real cacheonly builds) | oracle shim cases: a copy or mount source naming a stage is not artifact-capable, the image copy source pair, and the uppercase-mount-key live case |
| an artifact source that fails to resolve | the build fails | the outline run fails, which is not a pass | covered by the unresolvable-base oracle case (same failure path) |
