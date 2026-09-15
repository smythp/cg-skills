# Constructs that decide what a FROM resolves to

The FROM gate is two scripts. `scripts/check-from-lines.sh` reads every FROM
line textually, reachable or not, by reimplementing the parsing rules below.
`scripts/check-from-oracle.sh` asks BuildKit itself, in two bounded calls.
`timeout -k 30 600 docker buildx build --call=targets,format=json
--progress=plain` returns every stage with its base exactly as written,
from BuildKit's own parse; the script expands each base with the rules
below (global ARGs, the user's overrides, the automatic arguments as
seeded, single-quoted defaults literal), substitutes the named build
contexts, and requires every base in that FROM set to be on the allowlist,
failing closed on anything it cannot expand or classify. Then
`timeout -k 30 600 docker buildx build --call=outline,format=json
--progress=plain` resolves the file; any line containing "load metadata
for" is a reference whatever its bracketed step label, a load matching the
FROM set is a base already checked, and every other load is printed as an
external artifact source and allowed (see the artifact sources section),
unless the file has no instruction that can pull an image other than FROM,
in which case such a load is an unexpanded base and fails the run, the
fallback for any divergence between the oracle's scan and the frontend.
The scan reads parser directives as the textual gate does (VT and FF
normalized to spaces) and rejects a syntax directive naming any frontend
other than the rolling tag before either buildx call.
Both calls must show positive evidence they ran (the load-build-definition
step plus their JSON result), and the script refuses to answer when a
BuildKit source policy
is configured in the environment. The oracle
covers every stage the file declares, like the textual check. A migration
passes only when both pass.

Every construct below was enumerated from the Dockerfile frontend vendored
in the Docker 29.8 daemon (BuildKit's `frontend/dockerfile` at the moby
commit the daemon ships), and every fixture's expected result was checked
against that daemon before it was written. The fixture names refer to
`scripts/tests/test-check-from-lines.sh`. Where the textual gate cannot
match BuildKit it exits 1 naming the construct; those rows say so.

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
| unbalanced quote on a heredoc-capable line | lexer errors, silently scans no heredocs | exit 1 naming the line | unbalanced quote on a heredoc-capable line fails closed |
| `${...}` beyond `${NAME}`, `${NAME:-word}`, `${NAME:+word}` on a heredoc-capable line | value can shift word boundaries or disable the heredoc scan | exit 1 naming the expansion | expansion with whitespace on a heredoc line fails closed |
| Unicode space character on a heredoc-capable line | splits words like ASCII space | exit 1 naming the line | Unicode space bespoke case |

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
| unterminated heredoc | build error | exit 1 | unterminated heredoc is rejected (existing) |
| marker with `$`, mixed quotes, or other unusual delimiters | delimiter still parsed | exit 1 naming the marker | heredoc marker with a dollar sign fails closed (existing) |
| FROM inside a heredoc body | content, registers nothing | same | heredoc body cannot launder a stage alias (existing) |

## Escape directive and line continuation

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| `# escape=\` or `` # escape=` `` | sets the continuation escape | same | escape directive enables backtick continuation (existing) |
| invalid escape value | build error | exit 1 | invalid escape directive value is rejected (existing) |
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
| unknown key or plain comment | ends the directive block | same | escape directive after a plain comment is inert (existing) |
| duplicate directive | build error | exit 1 | duplicate escape directive is rejected (existing) |
| `# syntax=` with any value other than the rolling `docker/dockerfile:1` tag (an optional `docker.io/` prefix allowed), matched byte for byte | replaces the parser with the pin's rules. Under 1.0 a heredoc body is ordinary instructions (a real build of the reproduction fails on unknown instruction EOT) and the outline subrequest does not exist; under 1.4.0 buildx answers the outline through a different frontend (docker/dockerfile:1.8.1 by digest), so an outline pass vouches for the wrong parser; 1.99 fails to pull; an uppercase spelling is an invalid reference | exit 1 naming the frontend, in both scripts; the oracle rejects it before either buildx call | non-stable syntax directive fails closed (existing); rolling syntax tag with the docker.io prefix is accepted; pinned syntax tag 1.0 is rejected before heredoc parsing; pinned syntax tag 1.3 is rejected; pinned syntax tag 1.4.0 is rejected; pinned syntax tag 1.99 is rejected; uppercase syntax directive value is rejected; oracle shim case: pinned syntax directive fails before either buildx call |
| VT or FF inside a parser directive line | treated as whitespace, the directive is honored | same, both scripts normalize them to spaces before the match | oracle test case 11 (a VT-prefixed escape directive resolves alpine through the continuation it enables) |

## Physical line structure

The gate scans the raw bytes (through od, before awk reads the file) and
rejects a NUL anywhere and a CR that is not immediately followed by LF,
naming the line. BuildKit keeps both bytes inside the surrounding line where
the gate's line reader would split it.

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| CRLF line endings | accepted, the CR leaves with the LF | same | CRLF line endings are accepted |
| CR not followed by LF inside a line | kept in the line; the two-FROM reproduction fails with "FROM requires either one or three arguments" | exit 1 naming the line | bare CR joining two FROMs is rejected |
| NUL byte | kept in the line; the reproduction fails the same way | exit 1 naming the line | NUL byte in a FROM line is rejected |
| CR as the final byte with no LF | accepted as an ordinary line ending | exit 1 naming the line; a conservative rejection, stated in the header | CR as the final byte with no LF is rejected |

## ARG scope and overrides

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| global ARG before the first FROM | usable in FROM resolution | same | public cgr.dev via ARG default is allowed (existing) |
| ARG after a FROM | stage scope, not FROM resolution | same | stage ARG cannot override global ARG used by later FROM (existing) |
| bare redeclaration after a FROM | reuses the global value inside the stage | same | global ARG default can be reused by a later FROM (existing) |
| several assignments on one ARG line | all processed | same | second assignment on an ARG line is processed (existing) |
| `--build-arg` override of a declared ARG | beats the default | same | build-arg override to a forbidden registry is rejected (existing) |
| `--build-arg` with no declaration | ignored (automatic arguments excepted) | same | build-arg with no matching ARG declaration is ignored (existing) |
| quoted value spanning whitespace, escape characters in ARG tokens | reassembled by the parser | exit 1 naming the token | quoted ARG value spanning whitespace fails closed (existing) |

## Automatic platform arguments

BuildKit seeds TARGETPLATFORM, TARGETOS, TARGETARCH, TARGETVARIANT,
TARGETOSVERSION, TARGETSTAGE, BUILDPLATFORM, BUILDOS, BUILDARCH,
BUILDVARIANT, and BUILDOSVERSION in the global scope on every build. The
textual gate seeds the same values from `--platform`, `--build-platform`,
and `--target`; the oracle passes them to BuildKit as explicit overrides,
because buildx 0.37 drops `--platform` on `--call` runs (verified on both
the docker driver and a docker-container builder, for `--call=outline` and
`--call=targets` alike). The overrides carry one precedence difference
from a real build. BuildKit lets a global ARG that declares a default for
one of these names beat the automatic value, while a `--build-arg` beats
the default, so the oracle's overrides would reverse what the build
resolves for such a file. Both scripts therefore exit 1 naming the line
when a global ARG gives any of the eleven names a default; a bare
redeclaration stays allowed.

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| automatic argument read by a global ARG default or FROM | value available undeclared | seeded with --platform; exit 1 asking for --platform without it | automatic TARGETARCH reaches a global ARG default; automatic platform argument without --platform fails closed |
| `$BUILDPLATFORM` inside a FROM `--platform=` flag | names a manifest platform, not an image | flag skipped, no --platform needed | BUILDPLATFORM in a FROM flag needs no --platform |
| TARGETVARIANT on a variantless platform | set to the empty string; `:-` and `:+` treat empty as unset | same | TARGETVARIANT is empty-set on a variantless platform |
| platform normalization | containerd platforms.Normalize: x86_64 and x86-64 to amd64, aarch64 to arm64, i386 to 386 dropping any variant, armhf to arm/v7 and armel to arm/v6 replacing any variant, amd64 drops a v1 variant, arm64 drops an 8 or v8 variant, bare arm gains v7, the numeric arm variants 5, 6, 7, 8 gain the v prefix, every other variant passes through | same rules | amd64/v1 normalizes to an empty TARGETVARIANT; amd64/v2 keeps its TARGETVARIANT; arm64/v8 and arm64/8 normalize to an empty TARGETVARIANT; bare arm gains the v7 variant; arm/5 through arm/8 normalize to the v5 through v8 variants; arm/v8 keeps its TARGETVARIANT; x86_64 and x86-64 normalize to amd64; aarch64 normalizes to arm64; armhf normalizes to arm/v7 (with or without a variant); armel normalizes to arm/v6; i386 normalizes to 386 and drops any variant; arm/v7 keeps its TARGETVARIANT |
| bare global `ARG TARGETARCH` | keeps the automatic value | same | bare global ARG redeclaration keeps the automatic value |
| global `ARG TARGETARCH=value` | the default replaces the automatic value; a --build-arg replaces the default | exit 1 naming the line, in both scripts; the gate can pass a platform only as overrides, which would reverse that precedence | global ARG default for an automatic argument name is rejected; declared automatic default with a single-quoted literal is rejected (amd64, arm64); oracle test case 1d |
| `--build-arg TARGETARCH=...` undeclared | overrides the automatic value | same | build-arg overrides an automatic argument undeclared |
| BUILD* on a cross-platform build | the builder's own platform | target platform unless --build-platform is passed; a documented deviation | BUILDARCH follows --build-platform on a cross build; BUILDARCH defaults to the target platform without --build-platform |
| TARGETSTAGE | the --target stage name, else the final stage's | seeded from --target; exit 1 asking for --target when read without it | TARGETSTAGE carries the --target stage name; TARGETSTAGE without --target fails closed |
| multi-platform `--platform` value | one frontend evaluation per platform | exit 2, run once per platform | multi-platform value is refused |

## Variable expansion forms

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| `$NAME`, `${NAME}` | expanded | same | public cgr.dev via ARG default is allowed (existing) |
| single-quoted ARG default (`ARG A='${X}'`) | kept literal, no expansion inside single quotes; double-quoted and unquoted defaults expand | same | single-quoted ARG default keeps its variable text literal; oracle test case 1e |
| `${NAME:-default}` | default when unset or empty | same | colon-dash default applies when unset (existing) |
| `${NAME:+alt}` | alt when set and non-empty | same | colon-plus substitutes when set (existing) |
| `${NAME-d}`, `${NAME+a}` colon-less | unset test only, empty counts as set | exit 1 naming the modifier | colon-less minus modifier is rejected, not emulated |
| `${NAME%pat}`, `${NAME#pat}`, `${NAME/p/r}`, `${NAME:?}` and the rest | expanded per shell rules | exit 1 naming the modifier | unsupported modifier in FROM is rejected, not emptied (existing) |
| unresolved variable in a FROM ref | expands to the empty string | exit 1 naming the variable | unresolved ARG base is rejected (existing) |

## FROM syntax

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| instruction keywords in any case | case-insensitive | same | lowercase from is still a FROM |
| FROM flags (`--platform=...`) | consumed before the reference | skipped the same way | platform flag with cgr image is allowed (existing) |
| reference with tag | resolved as written | prefix-checked as written | public cgr.dev/chainguard is allowed (existing) |
| reference with tag and digest | resolved as written | prefix-checked as written | digest-pinned cgr.dev reference is allowed |
| one pair of quotes around the reference | quotes stripped | exit 1, quoted refs never match the allowlist | quoted FROM reference fails closed |
| backslashes and quotes elsewhere in a reference | processed by the shell lexer | passed through textually; removal of quote or escape characters cannot change the host a prefix check sees, so no allowed prefix can be forged | covered by the prefix rule (no fixture) |
| FROM token count after flags | one image reference, or reference AS name; every other count fails with "FROM requires either one or three arguments" (three tokens whose middle one is not AS draw the same message) | same, quoting the line | FROM with two extra tokens is rejected; FROM followed by a bare AS is rejected; FROM with a reference and an AS name stays allowed |
| `AS alias` stage names | letters, digits, `_ . -`, starting with a letter; case-insensitive reuse | same, image-shaped aliases rejected | image-shaped alias with slash is rejected (existing) |
| FROM of an earlier alias | stage reference, not a pull | same | stage alias is allowed (existing) |
| FROM of a later stage (forward reference) | stage reference too; BuildKit resolves stage names anywhere in the file (verified with an outline run that loads only the later stage's base) | the textual gate rejects it, a conservative sequential-alias rule; the oracle treats a base matching any other stage's name as a stage reference | forward stage reference fails closed (lines suite); oracle test case 12: a forward stage reference is a stage reference, not a pull; oracle shim case: a base naming an earlier stage is an alias, not a pull |
| a base identical to its own stage name (`FROM alpine AS alpine`) | a stage cannot be its own base, so the name resolves to the image; with another stage of that name it resolves to that stage | the oracle treats it as a pull and checks the allowlist; the textual gate rejects it since no prior alias exists | oracle live case: the self-named stage is rejected; a base naming a sibling stage passes |
| `scratch` | the empty base for the lowercase spelling only, no metadata load; FROM SCRATCH fails to parse as a stage name (repository name library/SCRATCH must be lowercase) | matched case-sensitively; other spellings fall through to the allowlist check and are rejected | scratch is allowed (existing); FROM SCRATCH is rejected as an image reference |
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
| context name matching a FROM reference | the docker-image:// source replaces the base; other source kinds (local directory, git, oci-layout, target) build the base from that source | docker-image://REF puts REF through the allowlist in place of the FROM; any other source kind for a FROM name exits 1 as unsupported for a base | build context overriding a Chainguard FROM to alpine is rejected; build context overriding a FROM to another Chainguard image is allowed; local-directory context for a FROM name is rejected; oracle test case 6 |
| matching normalization | reference normalization on both sides: a bare name gains docker.io/library/ and :latest, index.docker.io maps to docker.io only in that exact lowercase spelling, the host keeps its case from splitDockerDomain and compares byte-exact, and a dotless first component that is not all-lowercase is a domain (Foo/bar is domain Foo, path bar) | same rules in norm_ref, shared by both scripts | context name with a tag matches an untagged FROM; fully qualified context name matches a short FROM; index.docker.io context name matches a short FROM; context name with a different tag does not match; uppercase-host context name does not match a lowercase FROM; lowercase-host context name matches the FROM the uppercase one missed; uppercase index.docker.io context name does not map or match; dotless uppercase first component is a domain and matches its context; lowercased context does not match an uppercase-domain FROM; oracle test case 10 |
| matching against the expanded reference | the context match sees the FROM after ARG expansion | same | context matching happens after ARG expansion |
| context name matching a stage name | applied at the stage's definition: the stage's base is replaced even when no FROM references the name, with reference normalization on the name, and the stage-name match beats a context matching the base reference; at a FROM, the context beats the stage wherever it is referenced | same, checked at each AS name and at each FROM | stage-name context overriding a Chainguard stage to alpine is rejected; stage-name context overriding a stage to a Chainguard image is allowed; normalized stage-name context still overrides the stage; local-directory context for a stage name is rejected; context overriding a stage alias to alpine is rejected; context overriding a stage alias to a Chainguard image is allowed; oracle test case 9 |
| context named scratch | `FROM scratch` stays the empty base; a named context cannot override scratch by the base name, but a context matching the stage's AS name replaces even a scratch base (pinned by a real cacheonly build) | same | scratch cannot be overridden by a context; stage-name context replaces a scratch base |
| digest-pinned FROM | matches a context only on the exact digest string; the bare name does not match | same | context with the exact digest string overrides the FROM; bare context name does not match a digest-pinned FROM |
| repeated context name | the last value wins | same | repeated context name applies the last value (allowed, rejected) |
| context name matching no FROM and no stage name | ignored for bases (a COPY --from source may still use it, including from a local directory) | same | context whose name matches nothing is ignored; local-directory context for a copy source is ignored by the FROM gate |
| context name that is not a valid reference | buildx refuses the invocation (invalid context name, lowercase repository rule) | exit 1 naming the context | invalid context name is refused |

## Artifact sources

`COPY --from=IMAGE`, `RUN --mount=from=IMAGE`, and ADD from an image pull
an external artifact into the build without making it a base.
`references/from-and-registry-rules.md` permits artifact copies and asks
the report to name them, so the gate does not reject them. Only the FROM
set meets the allowlist; the oracle prints every non-base load as an
external artifact source for the report, but only when the file contains
at least one instruction that can pull an image other than FROM. With
none present, an off-set load is an unexpanded base and fails the run.

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| `COPY --from=IMAGE`, `RUN --mount=from=IMAGE`, ADD from an image | a metadata load, indistinguishable from a base load by its step label (verified; both print as [internal]) | the load is matched against the FROM set from the targets call; a non-base load is printed as an external artifact source and allowed | oracle test case 7; external COPY --from artifact source is not a base; external RUN mount source is not a base; bracketed-label shim case |
| a reference that is both a FROM base and a copy source | one load serves both | it is in the FROM set, so it is checked as a base; the artifact allowance cannot launder it | a base doubling as a copy source is still a base; oracle test case 7 |
| a load outside the FROM set in a file with no COPY --from= and no RUN --mount= carrying a from= source that could pull an image | only a FROM can have pulled it, so it is a base the scan expanded differently than the frontend | exit 1 naming the load; the fallback for any divergence between the oracle's scan and the frontend | oracle shim case: off-set load with no artifact-capable instruction is an unexpanded base; the bracketed-label shim case is the artifact-report pair |
| `COPY --from=STAGE`, `RUN --mount=from=STAGE` naming a declared stage | resolves the stage, pulls nothing | not artifact-capable for the fallback count; the source is matched by AS alias case-insensitively and by numeric stage index, after the global ARG expansion the FROM set uses, and mount keys match case-insensitively as BuildKit lowercases them (`FROM=`, `Type=`, and `From=` all build, verified with real cacheonly builds) | oracle shim cases: a copy or mount source naming a stage is not artifact-capable, the image copy source pair, and the uppercase-mount-key live case |
| an artifact source that fails to resolve | the build fails | the outline run fails, which is not a pass | covered by the unresolvable-base oracle case (same failure path) |
