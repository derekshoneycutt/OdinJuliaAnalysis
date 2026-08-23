#!/usr/bin/env julia

import Pkg

const SELF_TEST_ROOT = @__DIR__
Pkg.activate(SELF_TEST_ROOT; io=devnull)

module OdinJuliaAnalysisSelfTest

using JSON3

include(joinpath(@__DIR__, "tools", "Verification.jl"))
using .Verification

const REPOSITORY_ROOT = normpath(joinpath(@__DIR__))
const ANALYZER_SCRIPT = joinpath(REPOSITORY_ROOT, "analyze.jl")
const DEFAULT_SETTINGS = joinpath(REPOSITORY_ROOT, "settings.jl")
const COUNT_MARKER = "__ODIN_JULIA_ANALYSIS_TEST_COUNTS__"

struct OutputPolicy
    verbosity::Verbosity
    color::Symbol
    format::String
    settings_path::String
    report_path::Union{Nothing, String}
end

mutable struct OptionState
    verbosity::Verbosity
    color::Symbol
    format::String
    settings_path::String
    report_path::Union{Nothing, String}
end

"""Print self-test command usage."""
function usage(io::IO=stdout)
    println(io, "Usage: julia self-test.jl [OPTIONS]")
    println(io)
    println(io, "Run the analyzer unit tests and analyze the analyzer repository.")
    println(io, "Options:")
    println(io, "  --verbosity=0|1|2       Summary, details, or complete trace output")
    println(io, "  --verbose               Alias for --verbosity=2")
    println(io, "  --color=auto|always|never")
    println(io, "  --format=text|json      Select human or complete machine output")
    println(io, "  --settings=PATH         Load analyzer settings from PATH")
    println(io, "  --report=PATH           Write the canonical Markdown analysis report")
    println(io, "  -h, --help              Show this help")
end

"""Parse and validate self-test options."""
function parse_options(arguments::Vector{String})
    state = OptionState(Summary, :auto, "text", DEFAULT_SETTINGS, nothing)
    for argument in arguments
        argument in ("-h", "--help") && return :help
        error = apply_option!(state, argument)
        error === nothing || return error
    end
    state.color in (:auto, :always, :never) ||
        return "unsupported color mode: $(state.color)"
    state.format in ("text", "json") ||
        return "unsupported format: $(state.format)"
    isempty(state.settings_path) && return "settings path must not be empty"
    state.report_path === nothing || !isempty(state.report_path) ||
        return "report path must not be empty"
    return OutputPolicy(
        state.verbosity,
        state.color,
        state.format,
        state.settings_path,
        state.report_path)
end

"""Apply one command-line option to mutable parser state."""
function apply_option!(state::OptionState, argument::String)
    if argument == "--verbose"
        state.verbosity = Trace
    elseif startswith(argument, "--verbosity=")
        value = split(argument, "="; limit=2)[2]
        value in ("0", "1", "2") || return "invalid verbosity: $value"
        state.verbosity = Verbosity(parse(Int, value))
    elseif startswith(argument, "--color=")
        state.color = Symbol(split(argument, "="; limit=2)[2])
    elseif startswith(argument, "--format=")
        state.format = String(split(argument, "="; limit=2)[2])
    elseif startswith(argument, "--settings=")
        state.settings_path = resolve_path(split(argument, "="; limit=2)[2])
    elseif startswith(argument, "--report=")
        state.report_path = resolve_path(split(argument, "="; limit=2)[2])
    else
        return "unknown option: $argument"
    end
    return nothing
end

"""Resolve a command-line path relative to the repository root."""
function resolve_path(path::AbstractString)
    isempty(path) && return path
    resolved = isabspath(path) ? normpath(path) :
        normpath(joinpath(REPOSITORY_ROOT, path))
    return String(resolved)
end

"""Discard successful test chatter preceding the first test failure."""
function concise_test_failure(output::String)
    failure = findfirst(r"(?m)^.*: Test Failed at ", output)
    failure === nothing && return output
    return output[first(failure):end]
end

"""Run analyzer tests directly and extract Julia's structured test counts."""
function run_test_phase(trace::Bool=false)
    test_file = joinpath(REPOSITORY_ROOT, "test", "runtests.jl")
    expression = "using Test, JSON3; result=include($(repr(test_file))); " *
        "counts=Test.get_test_counts(result); println(\"$COUNT_MARKER\", " *
        "JSON3.write(Dict(" *
        "\"passed\"=>counts.passes + counts.cumulative_passes, " *
        "\"failed\"=>counts.fails + counts.cumulative_fails, " *
        "\"errors\"=>counts.errors + counts.cumulative_errors, " *
        "\"broken\"=>counts.broken + counts.cumulative_broken)))"
    base_command = Cmd(
        `$(Base.julia_cmd()) --project=$REPOSITORY_ROOT -e $expression`;
        dir=REPOSITORY_ROOT)
    command = addenv(
        base_command,
        "ODIN_JULIA_ANALYSIS_TEST_VERBOSE" => string(trace))
    result = capture_command(command)
    counts = parse_test_counts(result.output)
    tests = sum(get(counts, key, 0) for key in ("passed", "failed", "errors", "broken"))
    detail = isempty(counts) ? "test process failed" : "$tests tests"
    output = !trace && result.exit_code != 0 ?
        concise_test_failure(result.output) : result.output
    return PhaseResult(
        "Analyzer tests",
        detail,
        result.elapsed_ns,
        result.exit_code == 0 ? "PASS" : "FAIL",
        output,
        Dict{String, Any}("exit_code" => result.exit_code, "counts" => counts))
end

"""Extract the machine-readable test count marker from process output."""
function parse_test_counts(output::String)
    marker = findlast(COUNT_MARKER, output)
    marker === nothing && return Dict{String, Any}()
    return try
        Dict{String, Any}(String(key) => value
            for (key, value) in pairs(JSON3.read(output[last(marker) + 1:end])))
    catch exception
        @debug "Unable to parse analyzer test counts" exception
        Dict{String, Any}()
    end
end

"""Analyze this repository through the analyzer's canonical command-line path."""
function run_analysis_phase(policy::OutputPolicy; stream_progress::Bool=false)
    arguments = [
        Base.julia_cmd().exec...,
        ANALYZER_SCRIPT,
        "check",
        REPOSITORY_ROOT,
        "--settings=$(policy.settings_path)",
        "--format=json",
    ]
    stream_progress && push!(arguments, "--progress=always")
    policy.report_path === nothing || push!(arguments, "--report=$(policy.report_path)")
    result = capture_command_streams(
        Cmd(Cmd(arguments); dir=REPOSITORY_ROOT);
        stream_errors=stream_progress)
    report = parse_json_report(result.output)
    diagnostics = report === nothing ? Any[] : collect(report.diagnostics)
    warnings = count(item -> lowercase(String(item.response)) == "warn", diagnostics)
    failures = count(item -> lowercase(String(item.response)) == "fail", diagnostics)
    files = report === nothing ? 0 : Int(report.files_analyzed)
    detail = report === nothing ? "analysis failed" :
        "$files files, $warnings warnings, $failures failures"
    metadata = Dict{String, Any}(
        "exit_code" => result.exit_code,
        "warnings" => warnings,
        "failures" => failures,
        "report" => report)
    phase_output = isempty(result.errors) ? result.output : result.errors * result.output
    return PhaseResult(
        "Analyzer self-analysis",
        detail,
        result.elapsed_ns,
        result.exit_code == 0 ? "PASS" : "FAIL",
        phase_output,
        metadata)
end

"""Parse one analyzer JSON report, returning nothing for malformed output."""
function parse_json_report(output::String)
    return try
        JSON3.read(output)
    catch exception
        @debug "Unable to parse analyzer JSON report" exception
        nothing
    end
end

"""Run the two analyzer self-verification phases."""
function run_self_test_phases(policy::OutputPolicy; progress_io=stderr)
    phases = [
        ("Run analyzer unit tests", () -> run_test_phase(policy.verbosity == Trace)),
        ("Analyze the analyzer repository",
            () -> run_analysis_phase(policy; stream_progress=progress_io !== nothing)),
    ]
    return Verification.run_phases(
        phases;
        heading="Run analyzer self-verification",
        progress_io)
end

"""Write structured phase details for level-one output."""
function write_details(io::IO, results::Vector{PhaseResult}, _use_color::Bool)
    println(io)
    tests = only(filter(result -> result.name == "Analyzer tests", results))
    counts = tests.metadata["counts"]
    println(io, "Analyzer tests: ", isempty(counts) ? "counts unavailable" :
        join(("$key=$(get(counts, key, 0))"
            for key in ("passed", "failed", "errors", "broken")), ", "))
    analysis = only(filter(
        result -> result.name == "Analyzer self-analysis",
        results))
    report = analysis.metadata["report"]
    report === nothing && return
    println(io, "Analysis: $(length(report.engines)) engines, " *
        "$(length(report.rules)) rules")
end

"""Return the canonical report from the analyzer phase."""
function analysis_report(results::Vector{PhaseResult})
    analysis = only(filter(
        result -> result.name == "Analyzer self-analysis",
        results))
    return analysis.metadata["report"]
end

"""Write the standard analyzer statistics section."""
function write_statistics(io::IO, results::Vector{PhaseResult}, use_color::Bool)
    write_code_statistics(io, analysis_report(results), use_color)
end

"""Write the standard analyzer diagnostics section."""
function write_diagnostics(io::IO, results::Vector{PhaseResult}, use_color::Bool)
    write_analysis_diagnostics(io, analysis_report(results), use_color)
end

"""Return caller-selected sections for the standard text report."""
function report_sections(policy::OutputPolicy)
    sections = Function[write_statistics]
    policy.verbosity >= Details && push!(sections, write_details)
    push!(sections, write_diagnostics)
    return sections
end

"""Run the analyzer self-verification command."""
function main(arguments::Vector{String})
    policy = parse_options(arguments)
    if policy === :help
        usage()
        return 0
    elseif policy isa String
        println(stderr, "self-test.jl: $policy")
        return 2
    end
    results = run_self_test_phases(policy)
    write_report(
        stdout,
        results;
        format=policy.format,
        color=policy.color,
        verbosity=policy.verbosity,
        sections=report_sections(policy))
    return all(result -> result.status == "PASS", results) ? 0 : 1
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(OdinJuliaAnalysisSelfTest.main(ARGS))
end
