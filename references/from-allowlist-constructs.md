# Constructs that decide what a FROM resolves to

The FROM gate is two scripts. `scripts/check-from-lines.sh` reads every FROM
line textually, reachable or not, by reimplementing the parsing rules below.
`scripts/check-from-oracle.sh` asks BuildKit itself, by evaluating the file
with `timeout -k 30 600 docker buildx build --call=outline --progress=plain`
and checking every reference the builder resolves for the given target and
platform. The oracle covers exactly what the build will pull; the textual
check also covers stages the target does not reach. A migration passes only
when both pass.

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
- [ARG scope and overrides](#arg-scope-and-overrides)
- [Automatic platform arguments](#automatic-platform-arguments)
- [Variable expansion forms](#variable-expansion-forms)
- [FROM syntax](#from-syntax)

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
| bare `<<` at end of line | not a heredoc | same | covered inside the separated-form fixtures (existing) |
| marker whose rest contains `<` | not a heredoc | same | covered by the marker shape rule (existing round-1 verification) |
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
| `# syntax=` beyond stable docker/dockerfile:1 | replaces the parser | exit 1 naming the frontend | non-stable syntax directive fails closed (existing) |

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
because buildx 0.37 drops `--platform` on `--call` runs.

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| automatic argument read by a global ARG default or FROM | value available undeclared | seeded with --platform; exit 1 asking for --platform without it | automatic TARGETARCH reaches a global ARG default; automatic platform argument without --platform fails closed |
| `$BUILDPLATFORM` inside a FROM `--platform=` flag | names a manifest platform, not an image | flag skipped, no --platform needed | BUILDPLATFORM in a FROM flag needs no --platform |
| TARGETVARIANT on a variantless platform | set to the empty string; `:-` and `:+` treat empty as unset | same | TARGETVARIANT is empty-set on a variantless platform |
| platform normalization | x86_64 and aarch64 to amd64 and arm64, i386 to 386, armhf and armel to arm/v7 and arm/v6, arm64/v8 drops v8, bare arm gains v7 | same rules | arm64/v8 normalizes to an empty TARGETVARIANT; arm/v7 keeps its TARGETVARIANT; x86_64 normalizes to amd64 |
| bare global `ARG TARGETARCH` | keeps the automatic value | same | bare global ARG redeclaration keeps the automatic value |
| global `ARG TARGETARCH=value` | the default replaces the automatic value | same | global ARG default replaces the automatic value |
| `--build-arg TARGETARCH=...` undeclared | overrides the automatic value | same | build-arg overrides an automatic argument undeclared |
| BUILD* on a cross-platform build | the builder's own platform | target platform unless --build-platform is passed; a documented deviation | BUILDARCH follows --build-platform on a cross build; BUILDARCH defaults to the target platform without --build-platform |
| TARGETSTAGE | the --target stage name, else the final stage's | seeded from --target; exit 1 asking for --target when read without it | TARGETSTAGE carries the --target stage name; TARGETSTAGE without --target fails closed |
| multi-platform `--platform` value | one frontend evaluation per platform | exit 2, run once per platform | multi-platform value is refused |

## Variable expansion forms

| Construct | BuildKit | Gate | Fixture |
|---|---|---|---|
| `$NAME`, `${NAME}` | expanded | same | public cgr.dev via ARG default is allowed (existing) |
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
| `AS alias` stage names | letters, digits, `_ . -`, starting with a letter; case-insensitive reuse | same, image-shaped aliases rejected | image-shaped alias with slash is rejected (existing) |
| FROM of an earlier alias | stage reference, not a pull | same | stage alias is allowed (existing) |
| `scratch` | no metadata load | allowed by name | scratch is allowed (existing) |
