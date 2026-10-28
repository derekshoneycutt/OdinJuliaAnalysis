"""
Caller-driven verification execution and presentation.

Include this file, define operations that return `PhaseResult`, pass their names and
operations to `run_phases`, then pass the results to `write_report`. Callers retain
control of commands, CLI policy, phase metadata, and optional text-section callbacks.
"""
module Verification

using JSON

export Details, PhaseResult, Summary, Trace, Verbosity
export capture_command, capture_command_streams, color_enabled
export run_phases, styled, write_analysis_diagnostics, write_code_statistics
export write_report, write_table

const ANSI_RESET = "\e[0m"
const ANSI_BOLD = "\e[1m"
const ANSI_GREEN = "\e[1;32m"
const ANSI_RED = "\e[1;31m"
const ANSI_YELLOW = "\e[1;33m"

@enum Verbosity Summary=0 Details=1 Trace=2

struct PhaseResult
    name::String
    detail::String
    elapsed_ns::UInt64
    status::String
    output::String
    metadata::Dict{String, Any}
end

mutable struct PhaseProgress
    io::IO
    label::String
    started::UInt64
    frame::Int
    active::Bool
    lock::ReentrantLock
end

"""Animate only real terminals with cursor controls, never redirected or dumb streams."""
terminal_progress_enabled(io) =
    io isa Base.TTY && get(ENV, "TERM", "") != "dumb"
terminal_progress_enabled(io::IOContext) = terminal_progress_enabled(io.io)

"""Format monotonic elapsed time without claiming a completion percentage."""
function progress_elapsed(elapsed_ns::UInt64)
    seconds = elapsed_ns ÷ 1_000_000_000
    return lpad(string(seconds ÷ 60), 2, '0') * ":" *
        lpad(string(seconds % 60), 2, '0')
end

"""Replace the active line while serializing animation with streamed diagnostics."""
function draw_progress(progress::PhaseProgress)
    lock(progress.lock) do
        progress.active || return
        frames = ("|", "/", "-", "\\")
        frame = frames[mod1(progress.frame, length(frames))]
        print(progress.io, "\r\e[2K", progress.label, "  ", frame, "  ",
            progress_elapsed(UInt64(time_ns() - progress.started)))
        flush(progress.io)
        progress.frame += 1
    end
end

"""Clear the spinner before a real output line, then resume below that output."""
function write_progress_message(progress::PhaseProgress, message::AbstractString)
    lock(progress.lock) do
        print(progress.io, "\r\e[2K", message)
        endswith(message, '\n') || println(progress.io)
        draw_progress(progress)
    end
end

"""Drain a child's stderr through the active display without mixing it with stdout."""
function capture_progress_command(command::Cmd, output::IO, progress::PhaseProgress)
    errors = Pipe()
    try
        process = run(pipeline(
            ignorestatus(command), stdin=devnull, stdout=output, stderr=errors);
            wait=false)
        close(errors.in)
        @sync begin
            @async for line in eachline(errors; keep=true)
                write_progress_message(progress, line)
            end
            wait(process)
        end
        return process
    finally
        close(errors)
    end
end

"""Run a command while retaining combined output and elapsed time."""
function capture_command(command::Cmd)
    output = IOBuffer()
    started = time_ns()
    process = run(pipeline(
        ignorestatus(command), stdin=devnull, stdout=output, stderr=output))
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
    progress = get(task_local_storage(), :verification_phase_progress, nothing)
    process = if stream_errors && progress !== nothing
        capture_progress_command(command, output, progress)
    else
        run(pipeline(
            ignorestatus(command), stdin=devnull, stdout=output, stderr=errors))
    end
    return (
        exit_code=process.exitcode,
        elapsed_ns=UInt64(time_ns() - started),
        output=String(take!(output)),
        errors=stream_errors ? "" : String(take!(errors)))
end

"""Run caller-provided phases while writing standardized progress."""
function run_phases(phases; heading::String="Run verification", progress_io=stderr)
    progress_io === nothing || begin
        println(progress_io, "==> ", heading)
        println(progress_io, "VERIFICATION PROGRESS")
        flush(progress_io)
    end
    return [run_progress_phase(
        progress_io,
        index,
        length(phases),
        name,
        operation) for (index, (name, operation)) in enumerate(phases)]
end

"""Run one phase with interactive feedback or unchanged static progress in logs."""
function run_progress_phase(
    progress_io, index, total, name, operation;
    animate::Bool=terminal_progress_enabled(progress_io))
    animate && return run_animated_phase(progress_io, index, total, name, operation)
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

"""Own and join the refresh task even when a phase fails, throws, or is interrupted."""
function run_animated_phase(progress_io, index, total, name, operation)
    progress = PhaseProgress(
        progress_io, "  [$index/$total] $name", time_ns(), 1, true, ReentrantLock())
    draw_progress(progress)
    refresher = @async while progress.active
        sleep(0.1)
        draw_progress(progress)
    end
    result = try
        task_local_storage(operation, :verification_phase_progress, progress)
    finally
        progress.active = false
        try
            wait(refresher)
        finally
            print(progress_io, "\r\e[2K")
            flush(progress_io)
        end
    end
    println(progress_io, progress.label, "  ", result.status, "  ", result.detail,
        " (", format_duration(result.elapsed_ns), ")")
    flush(progress_io)
    return result
end

"""Write text or JSON verification output from caller-provided phase results."""
function write_report(
    io::IO,
    results::Vector{PhaseResult};
    format::String="text",
    color::Symbol=:auto,
    verbosity::Verbosity=Summary,
    title::String="VERIFICATION",
    sections=Function[])
    if format == "json"
        write_json_report(io, results)
        return
    end
    write_text_report(io, results; color, verbosity, title, sections)
end

"""Write the standard human-readable verification report."""
function write_text_report(
    io::IO,
    results::Vector{PhaseResult};
    color::Symbol,
    verbosity::Verbosity,
    title::String,
    sections)
    use_color = color_enabled(io, color)
    println(io, styled(title, ANSI_BOLD, use_color))
    println(io)
    write_phase_table(io, results, use_color)
    for section in sections
        section(io, results, use_color)
    end
    failed = filter(result -> result.status == "FAIL", results)
    verbosity == Trace ? write_trace(io, results, use_color) :
        write_failures(io, failed, use_color)
    println(io)
    overall = isempty(failed) ? "PASS" : "FAIL"
    println(io, styled("Verification: $overall", status_style(overall), use_color))
end

"""Write the complete verification result as a stable JSON envelope."""
function write_json_report(io::IO, results::Vector{PhaseResult})
    report = Dict(
        "schema_version" => "1.0.0",
        "passed" => all(result -> result.status == "PASS", results),
        "phases" => phase_json.(results))
    JSON.print(io, report, 4)
    println(io)
end

"""Convert a phase result to its machine representation."""
function phase_json(result::PhaseResult)
    return Dict(
        "name" => result.name,
        "detail" => result.detail,
        "elapsed_ns" => result.elapsed_ns,
        "status" => lowercase(result.status),
        "output" => result.output,
        "metadata" => result.metadata)
end

"""Render the standard phase summary table."""
function write_phase_table(io::IO, results::Vector{PhaseResult}, use_color::Bool)
    headers = ["Phase", "Result", "Time", "Status"]
    rows = [[
        result.name,
        result.detail,
        format_duration(result.elapsed_ns),
        result.status,
    ] for result in results]
    widths = table_widths(headers, rows)
    separator = table_separator(widths)
    println(io, separator)
    println(io, table_line(headers, widths))
    println(io, separator)
    for (result, row) in zip(results, rows)
        prefix = table_line(row[1:end - 1], widths[1:end - 1])
        status = styled(
            rpad(row[end], widths[end]),
            status_style(result.status),
            use_color)
        println(io, prefix, " ", status, " |")
    end
    println(io, separator)
end

"""Write a caller-provided table using the standard border format."""
function write_table(io::IO, headers, rows)
    widths = table_widths(headers, rows)
    separator = table_separator(widths)
    println(io, separator)
    println(io, table_line(headers, widths))
    println(io, separator)
    foreach(row -> println(io, table_line(row, widths)), rows)
    println(io, separator)
end

"""Write canonical analyzer code statistics and estimates."""
function write_code_statistics(io::IO, report, use_color::Bool)
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
    if hasproperty(statistics.code_by_language, :sql)
        insert!(rows, 3, code_statistics_row("SQLite", statistics.code_by_language.sql))
        rows[end][1] = "Procedural total"
    end
    println(io)
    println(io, styled("CODE STATISTICS", ANSI_BOLD, use_color))
    println(io)
    write_table(io, headers, rows)
    write_estimates(io, statistics)
end

"""Show failed or incomplete native validation without adding success-path output."""
function write_sqlite_runtime_summary(io, report)
    hasproperty(report, :sqlite_validation) || return
    validation = report.sqlite_validation
    validation.status in ("failed", "incomplete") || return
    println(io, "SQLite runtime validation: ", validation.status)
    validation.message === nothing || println(io, "  ", validation.message)
    for case in validation.cases
        println(io, "  ", case.id, ": ", case.status)
        case.provider === nothing || println(io, "    Provider: ",
            case.provider.identity, " ", case.provider.version)
        case.message === nothing || println(io, "    ", case.message)
        write_sqlite_failure_summary(io, case.failure)
        for step in case.steps
            step.failure === nothing && continue
            println(io, "    ", step.id, " [", step.source_id, "] (", step.mode, ")")
            write_sqlite_failure_summary(io, step.failure)
        end
        isempty(case.stderr) || println(io, "    Runner stderr: ", case.stderr)
    end
    println(io, "SQLite validated source coverage: ",
        count(item -> item.validated, validation.coverage), "/", length(validation.coverage))
    for item in validation.coverage
        item.validated && continue
        println(io, "  Uncovered: ", item.path, "; declared=", item.declared,
            ", attempted=", item.attempted, ", prepared=", item.prepared,
            ", executed=", item.executed)
    end
end

"""Surface native SQL failures even when ordinary policy diagnostics are empty."""
function write_sqlite_failure_summary(io, failure)
    failure === nothing && return
    println(io, "    Failure [", failure.phase, "] SQLite ", failure.primary_code,
        "/", failure.extended_code, " at byte ", something(failure.offset, "\u2014"),
        ": ", failure.message)
end

"""Write canonical analyzer warning and failure diagnostics."""
function write_analysis_diagnostics(io::IO, report, use_color::Bool)
    report === nothing && return
    write_sqlite_runtime_summary(io, report)
    visible = filter(item -> lowercase(String(item.response)) in ("warn", "fail"),
        report.diagnostics)
    isempty(visible) && return
    println(io)
    println(io, styled("ANALYSIS DIAGNOSTICS", ANSI_BOLD, use_color))
    for item in visible
        severity = uppercase(String(item.response))
        style = severity == "FAIL" ? ANSI_RED : ANSI_YELLOW
        location = "$(item.path):$(item.line):$(item.column)"
        println(io, styled(severity, style, use_color), " ", location,
            " [$(item.rule_id)] ", item.message)
    end
end

"""Return whether ANSI styling should be used for a stream."""
function color_enabled(io::IO, color::Symbol)
    color == :always && return true
    color == :never && return false
    return !haskey(ENV, "NO_COLOR") && get(io, :color, false)
end

"""Apply an ANSI style when color output is enabled."""
function styled(text::AbstractString, style::AbstractString, enabled::Bool)
    return enabled ? style * text * ANSI_RESET : text
end

"""Format a nanosecond duration for human output."""
function format_duration(elapsed_ns::UInt64)
    elapsed_ms = elapsed_ns / 1_000_000
    elapsed_ms < 1 && return "<1 ms"
    elapsed_ms < 1_000 && return "$(round(Int, elapsed_ms)) ms"
    return "$(round(elapsed_ms / 1_000; digits=2)) s"
end

"""Select the ANSI style for a phase status."""
function status_style(status::String)
    status == "PASS" && return ANSI_GREEN
    status == "FAIL" && return ANSI_RED
    return ANSI_YELLOW
end

"""Calculate display widths for an aligned table."""
function table_widths(headers, rows)
    return [maximum(textwidth(string(row[column])) for row in vcat([headers], rows))
        for column in eachindex(headers)]
end

"""Construct a horizontal separator for an aligned table."""
function table_separator(widths)
    return "+" * join((repeat("-", width + 2) for width in widths), "+") * "+"
end

"""Render one aligned table row."""
function table_line(values, widths)
    cells = (rpad(string(value), width) for (value, width) in zip(values, widths))
    return "| " * join(cells, " | ") * " |"
end

"""Return one canonical code-statistics table row."""
function code_statistics_row(language, code)
    return Any[
        language,
        Int(code.files),
        metric_display(code.functions),
        metric_display(code.structs),
        Int(code.lines),
        Int(code.blank_lines),
        Int(code.comment_lines),
        Int(code.code_lines),
        metric_display(code.complexity),
        code.complexity_per_code_line === nothing ? "\u2014" :
            round(code.complexity_per_code_line; digits=3),
    ]
end

"""Render unavailable metrics separately from zero in verification tables."""
metric_display(value) = value === nothing ? "\u2014" : Int(value)

"""Write compact COCOMO and LOCOMO estimate summaries."""
function write_estimates(io::IO, statistics)
    cocomo = statistics.cocomo
    locomo = statistics.locomo
    if cocomo === nothing || locomo === nothing
        println(io, "COCOMO/LOCOMO: \u2014 (not applicable; no Odin/Julia source).")
        return
    end
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

"""Replay complete captured phase output for trace verbosity."""
function write_trace(io::IO, results::Vector{PhaseResult}, use_color::Bool)
    for result in results
        println(io)
        println(io, styled("TRACE: $(uppercase(result.name))", ANSI_BOLD, use_color))
        isempty(result.output) && (println(io, "(no output)"); continue)
        print(io, result.output)
        endswith(result.output, '\n') || println(io)
    end
end

"""Replay output for failed phases in non-trace reports."""
function write_failures(io::IO, failed::Vector{PhaseResult}, use_color::Bool)
    for result in failed
        get(result.metadata, "report", nothing) === nothing || continue
        println(io)
        println(io, styled("FAILURE: $(result.name)", ANSI_RED, use_color))
        print(io, result.output)
        endswith(result.output, '\n') || println(io)
    end
end

end
