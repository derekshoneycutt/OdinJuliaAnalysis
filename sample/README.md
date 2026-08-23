# Odin-Julia Analysis Sample

This directory is the reference consumer integration for `OdinJuliaAnalysis`. The Odin
and Julia programs intentionally remain hello-world sized; the sample's purpose is to
show how a repository owns analysis settings, verification phases, report artifacts,
and a trusted extension without copying analyzer internals.

## Requirements

- Julia 1.12
- Odin dev-2026-08 or newer
- A local `OdinJuliaAnalysis` checkout

While the sample lives inside the analyzer checkout, `make.jl` finds the analyzer in its
parent directory. After moving this directory into a dedicated repository, set
`ODIN_JULIA_ANALYSIS_PROJECT` to the analyzer package checkout.

## Commands

```sh
./make.jl build
./make.jl run
./make.jl unit
./make.jl check
./make.jl test
```

`check` invokes the analyzer directly with this repository's settings. `test` is the
recommended verification gate: it builds both programs, runs both native test suites,
and analyzes the complete repository. Progress is written to stderr, while the text or
JSON verification report is written to stdout. Build and analysis artifacts stay
beneath `.build/`.

The complete gate supports the same presentation controls as the main project:

```sh
./make.jl test --verbosity=1 --color=never
./make.jl test --verbose
./make.jl test --format=json
./make.jl test --report=.build/reports/analysis.md
./make.jl test \
  --report=.build/reports/analysis.md \
  --full-report=.build/reports/analysis-full.md
```

The compact report is intended for routine review. The comprehensive report adds the
complete parser-backed inventories and analysis evidence for audit or debugging. JSON
mode uses a stable verification envelope containing each phase's status, elapsed time,
captured output, and metadata; the repository-analysis phase retains the canonical
analysis report in its metadata.

## Integration Files

| File | Repository-owned responsibility |
| --- | --- |
| [`make.jl`](make.jl) | Dispatch build, run, unit, direct analysis, and full verification commands |
| [`tools/verify.jl`](tools/verify.jl) | Define build, unit-test, and analysis operations and their metadata |
| [`analysis_settings.jl`](analysis_settings.jl) | Compose all current analyzer settings and project-specific policy |
| [`analysis_extension.jl`](analysis_extension.jl) | Register and execute one trusted repository rule |

The verification driver includes the analyzer's shared
`tools/Verification.jl` module through `ODIN_JULIA_ANALYSIS_PROJECT`. That module owns
phase execution, progress, ANSI color, text tables, JSON serialization, diagnostics,
and code-statistics presentation. The sample owns commands, phase definitions, option
policy, report paths, and the sections included in text output.

This split is deliberate: consumers reuse presentation contracts without importing the
analyzer package's private implementation or maintaining a fork of the verification
framework.

## Analysis Settings

[`analysis_settings.jl`](analysis_settings.jl) starts from the packaged rule registry
and thresholds, then supplies project-owned configuration for every current
`AnalysisSettings` field. The sample demonstrates:

- a repository scan profile and explicit failure threshold;
- all built-in rules plus one extension-owned rule;
- a concrete Julia JET callable and argument tuple;
- a strict analytical Odin build target;
- recognized Odin allocator-source patterns;
- explicit call roots for extension methods and the Odin test procedure invoked by
  framework dispatch rather than parser-visible call edges;
- architecture, resource lifetime, security, coverage, and documentation settings,
  using empty defaults where the hello-world repository has no honest policy to declare.

Empty defaults are preferable to invented architecture, security, coverage, or bridge
contracts. Replace them only with evidence from the consuming repository. In
particular, configure `CallRootSettings` for externally invoked bridge or callback
symbols; conventional `main`, test, JET, and Odin `@(init)` roots are inferred by the
analyzer.

## Extension Example

`analysis_extension.jl` implements the trusted extension API. Its repository-phase rule
requires the analyzed project to contain both Julia and Odin source files and publishes
the discovered language list as a generic report artifact. It demonstrates stable
extension identity, explicit API `2.0.0` compatibility, declared rule ownership,
lifecycle selection, diagnostics, and JSON-serializable artifacts. Extensions inspect
the same nested `context.files` hierarchy serialized by report schema `4.0.0`: each file
owns its functions and file-scope evidence, and each function owns its source-scoped
evidence. Core remains responsible for sorting, response mapping, report rendering, and
exit semantics.

## Using an External Checkout

While the sample is nested in this repository, it discovers the analyzer one directory
above itself. An external consumer should set the package checkout explicitly:

```sh
ODIN_JULIA_ANALYSIS_PROJECT=/path/to/OdinJuliaAnalysis ./make.jl test
```

The same value locates `analyze.jl`, the package environment, packaged base settings,
and the shared verification module. A consuming repository should keep its own
`analysis_settings.jl` and extension files under source control.
