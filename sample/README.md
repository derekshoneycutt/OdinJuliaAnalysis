# Odin-Julia Analysis Sample

This project is a minimal consumer of `OdinJuliaAnalysis`. It contains equivalent
hello-world programs in Odin and Julia, native tests for both languages, an analytical
Odin build, a JET entry point, and one trusted project extension.

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

`test` builds both programs, runs both native test suites, and analyzes the complete
sample repository. It prints live phase progress followed by aligned verification and
code-statistics tables. Build and analysis artifacts stay beneath `.build/`.

The complete gate supports the same presentation controls as the main project:

```sh
./make.jl test --verbosity=1 --color=never
./make.jl test --verbose
./make.jl test --format=json
./make.jl test --report=.build/reports/analysis.md
```

## Extension Example

`analysis_extension.jl` implements the trusted extension API. Its repository-phase rule
requires the analyzed project to contain both Julia and Odin source files and publishes
the discovered language list as a generic report artifact.
