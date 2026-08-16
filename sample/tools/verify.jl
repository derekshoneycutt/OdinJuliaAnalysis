#!/usr/bin/env julia

module SampleVerification

using JSON3

const RepositoryRoot = normpath(joinpath(@__DIR__, ".."))
const AnalysisProject = get(
    ENV,
    "ODIN_JULIA_ANALYSIS_PROJECT",
    normpath(joinpath(RepositoryRoot, "..")))
const AnalyzerScript = joinpath(AnalysisProject, "analyze.jl")
const DefaultSettingsPath = joinpath(RepositoryRoot, "analysis_settings.jl")
const BuildDirectory = joinpath(RepositoryRoot, ".build")
const OdinBinary = joinpath(BuildDirectory, "hello-odin")
const TestCountMarker = "__SAMPLE_TEST_COUNTS__"
const AnsiReset = "\e[0m"
const AnsiBold = "\e[1m"
const AnsiGreen = "\e[1;32m"
const AnsiRed = "\e[1;31m"
const AnsiYellow = "\e[1;33m"

@enum Verbosity Summary=0 Details=1 Trace=2

struct OutputPolicy
    verbosity::Verbosity
    color::Symbol
    format::String
    report_path::Union{Nothing, String}
    settings_path::Union{Nothing, String}
end

struct PhaseResult
    name::String
    detail::String
    elapsed_ns::UInt64
    status::String
    output::String
    metadata::Dict{String, Any}
end

"""Print verification runner usage."""
function usage(io::IO=stdout)
    println(io, "Usage: ./make.jl test [OPTIONS]")
    println(io)
    println(io, "Options:")
    println(io, "  --verbosity=0|1|2       Summary, details, or complete trace output")
    println(io, "  --verbose               Alias for --verbosity=2")
    println(io, "  --color=auto|always|never")
    println(io, "  --format=text|json      Select human or complete machine output")
    println(io, "  --settings=PATH         Load alternate analyzer settings")
    println(io, "  --report=PATH           Write the comprehensive analysis report")
end

"""Parse verification presentation options."""
function parse_options(arguments::Vector{String})
    verbosity = Summary
    color = :auto
    format = "text"
    report_path = nothing
    settings_path = nothing
    for argument in arguments
        argument in ("-h", "--help") && return :help
        if argument == "--verbose"
            verbosity = Trace
        elseif startswith(argument, "--verbosity=")
            value = split(argument, "="; limit=2)[2]
            value in ("0", "1", "2") || return "invalid verbosity: $value"
            verbosity = Verbosity(parse(Int, value))
        elseif startswith(argument, "--color=")
            color = Symbol(split(argument, "="; limit=2)[2])
        elseif startswith(argument, "--format=")
            format = split(argument, "="; limit=2)[2]
        elseif startswith(argument, "--settings=")
            settings_path = split(argument, "="; limit=2)[2]
            isempty(settings_path) && return "settings path must not be empty"
        elseif startswith(argument, "--report=")
            report_path = split(argument, "="; limit=2)[2]
            isempty(report_path) && return "report path must not be empty"
        else
            return "unknown option: $argument"
        end
    end
    return validated_output_policy(
        verbosity, color, format, report_path, settings_path)
end

"""Validate parsed presentation modes and construct an output policy."""
function validated_output_policy(verbosity, color, format, report_path, settings_path)
    color in (:auto, :always, :never) || return "unsupported color mode: $color"
    format in ("text", "json") || return "unsupported format: $format"
    return OutputPolicy(verbosity, color, format, report_path, settings_path)
end

"""Resolve an optional repository-relative path."""
function resolve_path(path)
    path === nothing && return nothing
    return isabspath(path) ? normpath(path) : normpath(joinpath(RepositoryRoot, path))
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

"""Run a command while retaining its combined output and elapsed time."""
function capture_command(command::Cmd)
    output = IOBuffer()
    started = time_ns()
    process = run(pipeline(ignorestatus(command), stdout=output, stderr=output))
    return (
        exit_code=process.exitcode,
        elapsed_ns=UInt64(time_ns() - started),
        output=String(take!(output)))
end

"""Run a command while retaining stdout and optionally streaming stderr."""
function capture_command_streams(command::Cmd; stream_errors::Bool=false)
    output = IOBuffer()
    errors = stream_errors ? stderr : IOBuffer()
    started = time_ns()
    process = run(pipeline(ignorestatus(command), stdout=output, stderr=errors))
    return (
        exit_code=process.exitcode,
        elapsed_ns=UInt64(time_ns() - started),
        output=String(take!(output)),
        errors=stream_errors ? "" : String(take!(errors)))
end

"""Build the Odin executable and precompile the Julia package."""
function run_build_phase()
    mkpath(BuildDirectory)
    started = time_ns()
    odin_command = Cmd(
        Cmd(vcat(["odin", "build", "src", "-out:$OdinBinary"], odin_flags()));
        dir=RepositoryRoot)
    odin = capture_command(odin_command)
    julia_command = Cmd(
        `$(Base.julia_cmd()) --project=$RepositoryRoot -e "using HelloWorldSample"`;
        dir=RepositoryRoot)
    julia = odin.exit_code == 0 ? capture_command(julia_command) : nothing
    exit_code = julia === nothing ? odin.exit_code : julia.exit_code
    output = odin.output * (julia === nothing ? "" : julia.output)
    metadata = Dict{String, Any}("exit_code" => exit_code)
    return PhaseResult(
        "Build", "Odin + Julia", UInt64(time_ns() - started),
        exit_code == 0 ? "PASS" : "FAIL", output, metadata)
end

"""Run native unit tests and return their structured phase result."""
function run_unit_phase()
    started = time_ns()
    odin_command = Cmd(
        Cmd(vcat(["odin", "test", "src"], odin_flags()));
        dir=RepositoryRoot)
    odin = capture_command(odin_command)
    test_file = joinpath(RepositoryRoot, "test", "runtests.jl")
    expression = "using Test; result=include($(repr(test_file))); " *
        "counts=Test.get_test_counts(result); " *
        "println(\"$TestCountMarker\", counts.passes + counts.cumulative_passes)"
    julia_command = Cmd(
        `$(Base.julia_cmd()) --project=$RepositoryRoot -e $expression`;
        dir=RepositoryRoot)
    julia = odin.exit_code == 0 ? capture_command(julia_command) : nothing
    exit_code = julia === nothing ? odin.exit_code : julia.exit_code
    output = odin.output * (julia === nothing ? "" : julia.output)
    odin_match = match(r"Finished (\d+) tests?", odin.output)
    julia_match = julia === nothing ? nothing :
        match(Regex(TestCountMarker * raw"(\d+)"), julia.output)
    counts_available = odin_match !== nothing && julia_match !== nothing
    tests = counts_available ?
        parse(Int, odin_match[1]) + parse(Int, julia_match[1]) : nothing
    detail = tests === nothing ? "test process failed" : "$tests tests"
    metadata = Dict{String, Any}("exit_code" => exit_code, "tests" => tests)
    return PhaseResult(
        "Unit tests", detail, UInt64(time_ns() - started),
        exit_code == 0 ? "PASS" : "FAIL", output, metadata)
end

"""Summarize one canonical analyzer process result."""
function analysis_result_summary(result)
    report = try
        JSON3.read(result.output)
    catch
        nothing
    end
    diagnostics = report === nothing ? Any[] : collect(report.diagnostics)
    warnings = count(item -> lowercase(String(item.response)) == "warn", diagnostics)
    failures = count(item -> lowercase(String(item.response)) == "fail", diagnostics)
    files = report === nothing ? 0 : Int(report.files_analyzed)
    detail = report === nothing ? "analysis failed" :
        "$files files, $warnings warnings, $failures failures"
    return (; report, warnings, failures, detail)
end

"""Analyze the sample repository and retain the canonical machine report."""
function run_analysis_phase(policy::OutputPolicy; stream_progress::Bool=false)
    settings_path = something(resolve_path(policy.settings_path), DefaultSettingsPath)
    arguments = [
        Base.julia_cmd().exec...,
        "--project=$AnalysisProject",
        AnalyzerScript,
        "check",
        RepositoryRoot,
        "--format=json",
        "--settings=$settings_path",
    ]
    stream_progress && push!(arguments, "--progress=always")
    report_path = resolve_path(policy.report_path)
    report_path === nothing || push!(arguments, "--report=$report_path")
    result = capture_command_streams(
        Cmd(Cmd(arguments); dir=RepositoryRoot);
        stream_errors=stream_progress)
    summary = analysis_result_summary(result)
    metadata = Dict{String, Any}(
        "exit_code" => result.exit_code,
        "warnings" => summary.warnings,
        "failures" => summary.failures,
        "report" => summary.report)
    output = isempty(result.errors) ? result.output : result.errors * result.output
    return PhaseResult(
        "Repository analysis", summary.detail, result.elapsed_ns,
        result.exit_code == 0 ? "PASS" : "FAIL", output, metadata)
end

"""Return whether ANSI styling should be used for this stream."""
function color_enabled(io::IO, color::Symbol)
    color == :always && return true
    color == :never && return false
    return !haskey(ENV, "NO_COLOR") && get(io, :color, false)
end

"""Apply an ANSI style when color output is enabled."""
styled(text, style, enabled) = enabled ? style * text * AnsiReset : text

"""Select the ANSI style for a phase status."""
function status_style(status::String)
    status == "PASS" && return AnsiGreen
    status == "FAIL" && return AnsiRed
    return AnsiYellow
end

"""Format a nanosecond duration for human output."""
function format_duration(elapsed_ns::UInt64)
    elapsed_ms = elapsed_ns / 1_000_000
    elapsed_ms < 1 && return "<1 ms"
    elapsed_ms < 1_000 && return "$(round(Int, elapsed_ms)) ms"
    return "$(round(elapsed_ms / 1_000; digits=2)) s"
end

"""Render one aligned table row."""
function table_line(values, widths)
    cells = (rpad(string(value), width) for (value, width) in zip(values, widths))
    return "| " * join(cells, " | ") * " |"
end

"""Render the unified phase summary table."""
function write_table(io::IO, results::Vector{PhaseResult}, use_color::Bool)
    headers = ["Phase", "Result", "Time", "Status"]
    rows = [[
        result.name,
        result.detail,
        format_duration(result.elapsed_ns),
        result.status,
    ] for result in results]
    widths = [maximum(textwidth(string(row[column])) for row in vcat([headers], rows))
        for column in eachindex(headers)]
    separator = "+" * join((repeat("-", width + 2) for width in widths), "+") * "+"
    println(io, separator)
    println(io, table_line(headers, widths))
    println(io, separator)
    for (result, row) in zip(results, rows)
        prefix = table_line(row[1:end - 1], widths[1:end - 1])
        status = styled(
            rpad(row[end], widths[end]), status_style(result.status), use_color)
        println(io, prefix, " ", status, " |")
    end
    println(io, separator)
end

"""Return one compact code-statistics table row."""
function code_statistics_row(language, code)
    return Any[
        language,
        Int(code.files),
        Int(code.functions),
        Int(code.structs),
        Int(code.lines),
        Int(code.blank_lines),
        Int(code.comment_lines),
        Int(code.code_lines),
        Int(code.complexity),
        round(code.complexity_per_code_line; digits=3),
    ]
end

"""Write compact repository code statistics."""
function write_statistics(io::IO, analysis::PhaseResult, use_color::Bool)
    report = analysis.metadata["report"]
    report === nothing && return
    statistics = report.statistics
    headers = [
        "Language", "Files", "Functions", "Structs", "Lines", "Blank", "Comment",
        "Code", "Complexity", "Complexity/Code"]
    rows = [
        code_statistics_row("Odin", statistics.code_by_language.odin),
        code_statistics_row("Julia", statistics.code_by_language.julia),
        code_statistics_row("Total", statistics.code),
    ]
    widths = [maximum(textwidth(string(row[index])) for row in vcat([headers], rows))
        for index in eachindex(headers)]
    separator = "+" * join((repeat("-", width + 2) for width in widths), "+") * "+"
    println(io)
    println(io, styled("CODE STATISTICS", AnsiBold, use_color))
    println(io)
    println(io, separator)
    println(io, table_line(headers, widths))
    println(io, separator)
    for row in rows
        println(io, table_line(row, widths))
    end
    println(io, separator)
    write_estimate_summaries(io, statistics)
end

"""Write compact COCOMO and LOCOMO estimate summaries."""
function write_estimate_summaries(io, statistics)
    cocomo = statistics.cocomo
    locomo = statistics.locomo
    println(io, "COCOMO ($(cocomo.model)): \$", round(Int, cocomo.estimated_cost),
        ", ", round(cocomo.effort_person_months; digits=2), " person-months, ",
        round(cocomo.schedule_months; digits=2), " months, ",
        round(cocomo.people; digits=2), " people")
    println(io, "LOCOMO ($(locomo.preset)): \$",
        round(locomo.estimated_cost; digits=2), ", ",
        round(Int, locomo.input_tokens), " input / ",
        round(Int, locomo.output_tokens), " output tokens, ",
        round(locomo.estimated_cycles; digits=2), " cycles, ",
        round(locomo.generation_seconds / 3600; digits=2), " generation hours, ",
        round(locomo.review_hours; digits=2), " review hours")
end

"""Write curated unit and analysis details for level-one output."""
function write_details(io::IO, results::Vector{PhaseResult})
    units = only(filter(result -> result.name == "Unit tests", results))
    analysis = only(filter(result -> result.name == "Repository analysis", results))
    println(io, "Unit tests: ", something(units.metadata["tests"], "counts unavailable"))
    report = analysis.metadata["report"]
    report === nothing && return
    println(io, "Analysis: $(length(report.engines)) engines, ",
        "$(length(report.rules)) rules")
end

"""Write warning and failure diagnostics at every verbosity."""
function write_diagnostics(io::IO, analysis::PhaseResult, use_color::Bool)
    report = analysis.metadata["report"]
    report === nothing && return
    visible = filter(item -> lowercase(String(item.response)) in ("warn", "fail"),
        report.diagnostics)
    isempty(visible) && return
    println(io)
    println(io, styled("ANALYSIS DIAGNOSTICS", AnsiBold, use_color))
    for item in visible
        severity = uppercase(String(item.response))
        style = severity == "FAIL" ? AnsiRed : AnsiYellow
        location = "$(item.path):$(item.line):$(item.column)"
        println(io, styled(severity, style, use_color), " ", location,
            " [$(item.rule_id)] ", item.message)
    end
end

"""Replay complete captured phase output for trace verbosity."""
function write_trace(io::IO, results::Vector{PhaseResult}, use_color::Bool)
    for result in results
        println(io)
        println(io, styled("TRACE: $(uppercase(result.name))", AnsiBold, use_color))
        isempty(result.output) && (println(io, "(no output)"); continue)
        print(io, result.output)
        endswith(result.output, '\n') || println(io)
    end
end

"""Return whether a failed phase has unrepresented output worth replaying."""
function should_replay_failure_output(result::PhaseResult)
    result.name != "Repository analysis" && return true
    return get(result.metadata, "report", nothing) === nothing
end

"""Write the human-readable unified verification report."""
function write_text_report(io::IO, results::Vector{PhaseResult}, policy::OutputPolicy)
    use_color = color_enabled(io, policy.color)
    println(io, styled("VERIFICATION", AnsiBold, use_color))
    println(io)
    write_table(io, results, use_color)
    analysis = only(filter(result -> result.name == "Repository analysis", results))
    write_statistics(io, analysis, use_color)
    policy.verbosity >= Details && (println(io); write_details(io, results))
    write_diagnostics(io, analysis, use_color)
    failed = filter(result -> result.status == "FAIL", results)
    if policy.verbosity < Trace
        for result in filter(should_replay_failure_output, failed)
            println(io)
            println(io, styled("FAILURE: $(result.name)", AnsiRed, use_color))
            print(io, result.output)
            endswith(result.output, '\n') || println(io)
        end
    else
        write_trace(io, results, use_color)
    end
    println(io)
    overall = isempty(failed) ? "PASS" : "FAIL"
    println(io, styled("Verification: $overall", status_style(overall), use_color))
end

"""Convert a phase result to its complete machine representation."""
function phase_json(result::PhaseResult)
    return Dict(
        "name" => result.name,
        "detail" => result.detail,
        "elapsed_ns" => result.elapsed_ns,
        "status" => lowercase(result.status),
        "output" => result.output,
        "metadata" => result.metadata)
end

"""Write the complete verbosity-independent verification report as JSON."""
function write_json_report(io::IO, results::Vector{PhaseResult})
    report = Dict(
        "schema_version" => "1.0.0",
        "passed" => all(result -> result.status == "PASS", results),
        "phases" => phase_json.(results))
    JSON3.pretty(io, report)
    println(io)
end

"""Run one phase while writing immediate start and completion progress."""
function run_progress_phase(progress_io, index, total, name, operation)
    progress_io === nothing || begin
        println(progress_io, "  [$index/$total] $name")
        flush(progress_io)
    end
    result = operation()
    progress_io === nothing || begin
        println(progress_io, "        $(result.status)  $(result.detail) " *
            "($(format_duration(result.elapsed_ns)))")
        flush(progress_io)
    end
    return result
end

"""Run all sample verification phases."""
function run_phases(policy::OutputPolicy; progress_io=stderr)
    progress_io === nothing || begin
        println(progress_io, "VERIFICATION PROGRESS")
        flush(progress_io)
    end
    phases = [
        ("Build Odin and Julia hello programs", run_build_phase),
        ("Run Odin and Julia unit tests", run_unit_phase),
        ("Analyze the sample repository",
            () -> run_analysis_phase(policy; stream_progress=progress_io !== nothing)),
    ]
    return [run_progress_phase(
        progress_io,
        index,
        length(phases),
        name,
        operation) for (index, (name, operation)) in enumerate(phases)]
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
    results = run_phases(policy)
    policy.format == "json" ? write_json_report(stdout, results) :
        write_text_report(stdout, results, policy)
    return all(result -> result.status == "PASS", results) ? 0 : 1
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(SampleVerification.main(ARGS))
end