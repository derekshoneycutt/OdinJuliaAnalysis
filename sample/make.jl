#!/usr/bin/env julia

const RepositoryRoot = @__DIR__
const AnalysisProject = get(
    ENV,
    "ODIN_JULIA_ANALYSIS_PROJECT",
    normpath(joinpath(RepositoryRoot, "..")))
const AnalyzerScript = joinpath(AnalysisProject, "analyze.jl")
const AnalysisSettingsPath = joinpath(RepositoryRoot, "analysis_settings.jl")
const VerificationScript = joinpath(RepositoryRoot, "tools", "verify.jl")
const BuildDirectory = joinpath(RepositoryRoot, ".build")
const OdinBinary = joinpath(BuildDirectory, "hello-odin")

"""Write repository-driver usage information."""
function print_help(io::IO=stdout)
    println(io, "Odin-Julia analysis sample")
    println(io)
    println(io, "Usage: ./make.jl COMMAND [ARGUMENTS]")
    println(io)
    println(io, "Commands:")
    println(io,
        "  build         Build the Odin executable and precompile the Julia package")
    println(io, "  run           Build and run both hello-world programs")
    println(io, "  unit          Run Odin and Julia unit tests")
    println(io, "  check [OPTS]  Analyze the sample repository")
    println(io, "  test [OPTS]   Build, test, and analyze the sample repository")
    println(io)
    println(io, "Test options:")
    println(io, "  --verbosity=0|1|2  Summary, details, or complete trace")
    println(io, "  --verbose          Alias for --verbosity=2")
    println(io, "  --color=MODE       auto, always, or never")
    println(io, "  --format=FORMAT    text or complete JSON")
    println(io, "  --settings=PATH    Load alternate analyzer settings")
    println(io, "  --report=PATH      Write the compact Markdown report")
end

"""Run one command from the sample root and return its exit code."""
function run_step(label::String, command::Cmd)
    println("\n==> ", label)
    flush(stdout)
    return run(ignorestatus(command)).exitcode
end

"""Return the strict Odin compiler flags shared by builds and tests."""
function odin_flags()
    return [
        "-vet",
        "-strict-style",
        "-disallow-do",
        "-warnings-as-errors",
        "-error-pos-style:unix",
    ]
end

"""Build both language projects."""
function build_projects()
    mkpath(BuildDirectory)
    odin_command = Cmd(
        Cmd(vcat(["odin", "build", "src", "-out:$OdinBinary"], odin_flags()));
        dir=RepositoryRoot)
    status = run_step("Build Odin hello", odin_command)
    status == 0 || return status
    julia_command = Cmd(
        `$(Base.julia_cmd()) --project=$RepositoryRoot -e "using HelloWorldSample"`;
        dir=RepositoryRoot)
    return run_step("Precompile Julia hello", julia_command)
end

"""Build and run the Odin and Julia hello-world programs."""
function run_projects()
    status = build_projects()
    status == 0 || return status
    status = run_step(
        "Run Odin hello", Cmd(`$OdinBinary`; dir=RepositoryRoot))
    status == 0 || return status
    expression = "using HelloWorldSample; HelloWorldSample.main()"
    command = Cmd(
        `$(Base.julia_cmd()) --project=$RepositoryRoot -e $expression`;
        dir=RepositoryRoot)
    return run_step("Run Julia hello", command)
end

"""Run native tests for both languages."""
function test_units()
    odin_command = Cmd(
        Cmd(vcat(["odin", "test", "src"], odin_flags()));
        dir=RepositoryRoot)
    status = run_step("Test Odin hello", odin_command)
    status == 0 || return status
    expression = "using Pkg; Pkg.test()"
    julia_command = Cmd(
        `$(Base.julia_cmd()) --project=$RepositoryRoot -e $expression`;
        dir=RepositoryRoot)
    return run_step("Test Julia hello", julia_command)
end

"""Analyze the sample repository with its project settings."""
function check_repository(arguments::Vector{String}=String[])
    command = Cmd(
        Cmd(vcat([
            Base.julia_cmd().exec...,
            "--project=$AnalysisProject",
            AnalyzerScript,
            "check",
            RepositoryRoot,
            "--settings=$AnalysisSettingsPath",
        ], arguments));
        dir=RepositoryRoot)
    return run_step("Analyze sample repository", command)
end

"""Run the structured sample verification gate."""
function run_full_gate(arguments::Vector{String}=String[])
    command = Cmd(
        Cmd(vcat([
            Base.julia_cmd().exec...,
            "--project=$AnalysisProject",
            VerificationScript,
        ], arguments));
        dir=RepositoryRoot)
    println(stderr, "\n==> Run complete verification")
    flush(stderr)
    return run(ignorestatus(command)).exitcode
end

"""Parse one command and dispatch the requested repository operation."""
function main(arguments::Vector{String})
    isempty(arguments) && (print_help(); return 0)
    command = first(arguments)
    remaining = arguments[2:end]
    command in ("help", "-h", "--help") && (print_help(); return 0)
    command == "build" && return build_projects()
    command == "run" && return run_projects()
    command == "unit" && return test_units()
    command == "check" && return check_repository(remaining)
    command == "test" && return run_full_gate(remaining)
    println(stderr, "make.jl: unknown command: $command")
    return 2
end

exit(main(ARGS))