#!/usr/bin/env julia

module SampleVerification

using JSON3

const REPOSITORY_ROOT = normpath(joinpath(@__DIR__, ".."))
const ANALYSIS_PROJECT = get(
    ENV,
    "ODIN_JULIA_ANALYSIS_PROJECT",
    normpath(joinpath(REPOSITORY_ROOT, "..")))
const ANALYZER_SCRIPT = joinpath(ANALYSIS_PROJECT, "analyze.jl")
const VERIFICATION_SCRIPT = joinpath(ANALYSIS_PROJECT, "tools", "Verification.jl")
const DEFAULT_SETTINGS_PATH = joinpath(REPOSITORY_ROOT, "analysis_settings.jl")
const BUILD_DIRECTORY = joinpath(REPOSITORY_ROOT, ".build")
const ODIN_BINARY = joinpath(BUILD_DIRECTORY, "hello-odin")
const TEST_COUNT_MARKER = "__SAMPLE_TEST_COUNTS__"

Base.include(@__MODULE__, VERIFICATION_SCRIPT)
using .Verification

struct OutputPolicy
    verbosity::Verbosity
    color::Symbol
    format::String
    settings_path::Union{Nothing, String}
    report_path::Union{Nothing, String}
    full_report_path::Union{Nothing, String}
end

mutable struct OptionState
    verbosity::Verbosity
    color::Symbol
    format::String
    settings_path::Union{Nothing, String}
    report_path::Union{Nothing, String}
    full_report_path::Union{Nothing, String}
end

"""Print verification runner usage."""
function usage(io::IO=stdout)
    println(io, "Usage: ./make.jl test [OPTIONS]")
    println(io)
    println(io, "Build, test, and analyze the sample repository.")
    println(io, "Options:")
    println(io, "  --verbosity=0|1|2       Summary, details, or complete trace output")
    println(io, "  --verbose               Alias for --verbosity=2")
    println(io, "  --color=auto|always|never")
    println(io, "  --format=text|json      Select human or complete machine output")
    println(io, "  --settings=PATH         Load alternate analyzer settings")
    println(io, "  --report=PATH           Write the compact Markdown report")
    println(io, "  --full-report=PATH      Write the comprehensive Markdown report")
    println(io, "  -h, --help              Show this help")
end

"""Parse and validate verification presentation options."""
function parse_options(arguments::Vector{String})
    state = OptionState(Summary, :auto, "text", nothing, nothing, nothing)
    for argument in arguments
        argument in ("-h", "--help") && return :help
        error = apply_option!(state, argument)
        error === nothing || return error
    end
    state.color in (:auto, :always, :never) ||
        return "unsupported color mode: $(state.color)"
    state.format in ("text", "json") ||
        return "unsupported format: $(state.format)"
    return OutputPolicy(
        state.verbosity,
        state.color,
        state.format,
        state.settings_path,
        state.report_path,
        state.full_report_path)
end

"""Apply one command-line option to the mutable parser state."""
function apply_option!(state::OptionState, argument::String)
    argument == "--verbose" && (state.verbosity = Trace; return nothing)
    name, value = split_option(argument)
    value === nothing && return "unknown option: $argument"
    isempty(value) && return "option value must not be empty: $name"
    if name == "--verbosity"
        value in ("0", "1", "2") || return "invalid verbosity: $value"
        state.verbosity = Verbosity(parse(Int, value))
    elseif name == "--color"
        state.color = Symbol(value)
    elseif name == "--format"
        state.format = value
    else
        return apply_path_option!(state, name, value, argument)
    end
    return nothing
end

"""Apply one path-bearing command-line option."""
function apply_path_option!(
    state::OptionState,
    name::AbstractString,
    value::AbstractString,
    argument::String)
    name == "--settings" && (state.settings_path = value; return nothing)
    name == "--report" && (state.report_path = value; return nothing)
    name == "--full-report" && (state.full_report_path = value; return nothing)
    return "unknown option: $argument"
end

"""Split one long option into its name and optional value."""
function split_option(argument::String)
    parts = split(argument, "="; limit=2)
    return length(parts) == 2 ? (parts[1], parts[2]) : (argument, nothing)
end

"""Resolve an optional repository-relative path."""
function resolve_path(path::Union{Nothing, AbstractString})
    path === nothing && return nothing
    return isabspath(path) ? normpath(path) : normpath(joinpath(REPOSITORY_ROOT, path))
end

"""Return strict compiler flags shared by Odin builds and tests."""
function odin_flags()
    return [
        "-vet",
        "-strict-style",
        "-disallow-do",
        "-warnings-as-errors",
        "-error-pos-style:unix",
    ]
end

"""Build the Odin executable and precompile the Julia package."""
function run_build_phase()
    mkpath(BUILD_DIRECTORY)
    started = time_ns()
    odin_command = Cmd(
        Cmd(vcat(["odin", "build", "src", "-out:$ODIN_BINARY"], odin_flags()));
        dir=REPOSITORY_ROOT)
    odin = capture_command(odin_command)
    julia_command = Cmd(
        `$(Base.julia_cmd()) --project=$REPOSITORY_ROOT -e "using HelloWorldSample"`;
        dir=REPOSITORY_ROOT)
    julia = odin.exit_code == 0 ? capture_command(julia_command) : nothing
    exit_code = julia === nothing ? odin.exit_code : julia.exit_code
    output = odin.output * (julia === nothing ? "" : julia.output)
    return PhaseResult(
        "Build",
        "Odin + Julia",
        UInt64(time_ns() - started),
        exit_code == 0 ? "PASS" : "FAIL",
        output,
        Dict{String, Any}("exit_code" => exit_code))
end

"""Run native unit tests and return their structured phase result."""
function run_unit_phase()
    started = time_ns()
    odin_command = Cmd(
        Cmd(vcat(["odin", "test", "src"], odin_flags()));
        dir=REPOSITORY_ROOT)
    odin = capture_command(odin_command)
    test_file = joinpath(REPOSITORY_ROOT, "test", "runtests.jl")
    expression = "using Test; result=include($(repr(test_file))); " *
        "counts=Test.get_test_counts(result); " *
        "println(\"$TEST_COUNT_MARKER\", counts.passes + counts.cumulative_passes)"
    julia_command = Cmd(
        `$(Base.julia_cmd()) --project=$REPOSITORY_ROOT -e $expression`;
        dir=REPOSITORY_ROOT)
    julia = odin.exit_code == 0 ? capture_command(julia_command) : nothing
    exit_code = julia === nothing ? odin.exit_code : julia.exit_code
    output = odin.output * (julia === nothing ? "" : julia.output)
    odin_match = match(r"Finished (\d+) tests?", odin.output)
    julia_match = julia === nothing ? nothing :
        match(Regex(TEST_COUNT_MARKER * raw"(\d+)"), julia.output)
    tests = odin_match === nothing || julia_match === nothing ? nothing :
        parse(Int, odin_match[1]) + parse(Int, julia_match[1])
    detail = tests === nothing ? "test process failed" : "$tests tests"
    return PhaseResult(
        "Unit tests",
        detail,
        UInt64(time_ns() - started),
        exit_code == 0 ? "PASS" : "FAIL",
        output,
        Dict{String, Any}("exit_code" => exit_code, "tests" => tests))
end

"""Summarize one canonical analyzer process result."""
function analysis_result_summary(result)
    report, parse_error = try
        (JSON3.read(result.output), nothing)
    catch exception
        (nothing, sprint(showerror, exception))
    end
    diagnostics = report === nothing ? Any[] : collect(report.diagnostics)
    warnings = count(item -> lowercase(String(item.response)) == "warn", diagnostics)
    failures = count(item -> lowercase(String(item.response)) == "fail", diagnostics)
    files = report === nothing ? 0 : Int(report.files_analyzed)
    detail = report === nothing ? "analysis failed" :
        "$files files, $warnings warnings, $failures failures"
    return (; report, warnings, failures, detail, parse_error)
end

"""Analyze the sample repository and retain the canonical machine report."""
function run_analysis_phase(policy::OutputPolicy)
    settings_path = something(resolve_path(policy.settings_path), DEFAULT_SETTINGS_PATH)
    arguments = [
        Base.julia_cmd().exec...,
        "--project=$ANALYSIS_PROJECT",
        ANALYZER_SCRIPT,
        "check",
        REPOSITORY_ROOT,
        "--format=json",
        "--progress=always",
        "--settings=$settings_path",
    ]
    report_path = resolve_path(policy.report_path)
    report_path === nothing || push!(arguments, "--report=$report_path")
    full_report_path = resolve_path(policy.full_report_path)
    full_report_path === nothing || push!(arguments, "--full-report=$full_report_path")
    result = capture_command_streams(
        Cmd(Cmd(arguments); dir=REPOSITORY_ROOT);
        stream_errors=true)
    summary = analysis_result_summary(result)
    metadata = Dict{String, Any}(
        "exit_code" => result.exit_code,
        "warnings" => summary.warnings,
        "failures" => summary.failures,
        "parse_error" => summary.parse_error,
        "report" => summary.report)
    return PhaseResult(
        "Repository analysis",
        summary.detail,
        result.elapsed_ns,
        result.exit_code == 0 ? "PASS" : "FAIL",
        result.output,
        metadata)
end

"""Return the analyzer report retained by the repository-analysis phase."""
function analysis_report(results::Vector{PhaseResult})
    analysis = only(filter(result -> result.name == "Repository analysis", results))
    return get(analysis.metadata, "report", nothing)
end

"""Write canonical code statistics from the retained analyzer report."""
function write_statistics(io::IO, results::Vector{PhaseResult}, use_color::Bool)
    write_code_statistics(io, analysis_report(results), use_color)
end

"""Write verification details requested at verbosity level one or greater."""
function write_details(io::IO, results::Vector{PhaseResult}, _use_color::Bool)
    units = only(filter(result -> result.name == "Unit tests", results))
    println(io)
    println(io, "Unit tests: ", something(units.metadata["tests"], "counts unavailable"))
    report = analysis_report(results)
    report === nothing && return
    println(io, "Analysis: $(length(report.engines)) engines, ",
        "$(length(report.rules)) rules")
end

"""Write analyzer warning and failure diagnostics from the retained report."""
function write_diagnostics(io::IO, results::Vector{PhaseResult}, use_color::Bool)
    write_analysis_diagnostics(io, analysis_report(results), use_color)
end

"""Select standardized report sections for the requested verbosity."""
function report_sections(policy::OutputPolicy)
    sections = Function[write_statistics]
    policy.verbosity >= Details && push!(sections, write_details)
    push!(sections, write_diagnostics)
    return sections
end

"""Run the sample repository verification command."""
function main(arguments::Vector{String})
    policy = parse_options(arguments)
    if policy === :help
        usage()
        return 0
    elseif policy isa String
        println(stderr, "verify.jl: $policy")
        return 2
    end
    phases = [
        ("Build Odin and Julia hello programs", run_build_phase),
        ("Run Odin and Julia unit tests", run_unit_phase),
        ("Analyze the sample repository", () -> run_analysis_phase(policy)),
    ]
    results = Verification.run_phases(phases; heading="Run complete verification")
    write_report(
        stdout,
        results;
        format=policy.format,
        color=policy.color,
        verbosity=policy.verbosity,
        title="VERIFICATION",
        sections=report_sections(policy))
    return all(result -> result.status == "PASS", results) ? 0 : 1
end

end


if abspath(PROGRAM_FILE) == @__FILE__
    exit(SampleVerification.main(ARGS))
end