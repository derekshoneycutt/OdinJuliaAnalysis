const ANSI_RESET = "\e[0m"
const ANSI_BOLD_RED = "\e[1;31m"
const ANSI_BOLD_YELLOW = "\e[1;33m"
const ANSI_CYAN = "\e[36m"
const ANSI_GREEN = "\e[32m"
const ANSI_YELLOW = "\e[33m"
const RESPONSE_STYLES = Dict(
    Fail => ANSI_BOLD_RED,
    Warn => ANSI_BOLD_YELLOW,
    Report => "")

"""Write targeted source statistics in the requested format."""
function write_statistics_report(io::IO, report, format::AbstractString)
    if format == "json"
        JSON3.pretty(io, report)
        println(io)
        return
    end
    format == "text" || throw(ArgumentError("unsupported format: $format"))
    write_text_statistics(io, report)
end

"""Write human-readable file and selected function measurements."""
function write_text_statistics(io, report)
    println(io, "FILE STATISTICS")
    println(io)
    write_file_statistics(io, report)
    println(io)
    write_function_statistics(io, report)
end

"""Write scalar measurements for one source file."""
function write_file_statistics(io, report)
    file = report.file
    write_statistic(io, "Path", report.path)
    write_statistic(io, "Language", uppercasefirst(report.language))
    write_statistic(io, "Parsed", file.parsed ? "yes" : "no")
    write_statistic(io, "Physical lines", file.physical_lines)
    write_statistic(io, "Source lines", file.source_lines)
    write_statistic(io, "Code lines", file.code_lines)
    write_statistic(io, "Comment lines", file.comment_lines)
    write_statistic(io, "Blank lines", file.blank_lines)
    write_statistic(io, "Functions", file.function_count)
    write_statistic(io, "Structs", file.struct_count)
    write_statistic(io, "Total cyclomatic", file.total_cyclomatic_complexity)
    write_statistic(io, "Complexity/code", statistic_decimal(
        file.complexity_per_code_line))
    write_statistic(io, "Average complexity", statistic_decimal(
        file.average_function_complexity))
    write_statistic(io, "Maximum complexity", file.maximum_function_complexity)
    write_statistic(io, "Average exec lines", statistic_decimal(
        file.average_executable_lines))
    write_statistic(io, "Maximum exec lines", file.maximum_executable_lines)
end

"""Write the measured or selected functions in source order."""
function write_function_statistics(io, report)
    heading = report.selection === nothing ? "FUNCTIONS" : "SELECTED FUNCTIONS"
    println(io, heading)
    println(io)
    println(io, rpad("Line", 7), rpad("Name", 34),
        lpad("Span", 6), lpad("Exec", 7), lpad("Params", 9),
        lpad("Cyclomatic", 13), lpad("Cognitive", 12), lpad("Documented", 12))
    for item in report.functions
        cognitive = item.cognitive_complexity === nothing ? "-" :
            string(item.cognitive_complexity)
        println(io, rpad(item.start_line, 7), rpad(item.name, 34),
            lpad(item.physical_lines, 6), lpad(item.executable_lines, 7),
            lpad(item.parameter_count, 9), lpad(item.cyclomatic_complexity, 13),
            lpad(cognitive, 12), lpad(item.documented ? "yes" : "no", 12))
    end
end

"""Write one aligned scalar statistics field."""
write_statistic(io, label, value) = println(io, rpad(label, 24), value)

"""Format a statistics ratio without excessive precision."""
statistic_decimal(value) = string(round(value; digits=3))

"""Write an analysis report in the requested machine or human format."""
function write_report(
    io::IO,
    report::AnalysisReport,
    format::AbstractString;
    color::Symbol=:auto,
    warning_limit::Int=50,
    report_limit::Int=50)
    if format == "json"
        JSON3.pretty(io, report)
        println(io)
        return
    end

    write_text_report(io, report, color, warning_limit, report_limit)
end

"""Write the human-readable analysis report."""
function write_text_report(io, report, color, warning_limit, report_limit)
    use_color = color_enabled(io, color)
    println(io, styled("OdinJuliaAnalysis $(report.tool_version)", "\e[1m", use_color))
    println(io, "Target:  $(report.root)")
    println(io, "Profile: $(report.profile)")
    println(io, "Files:   $(report.files_analyzed) total " *
        "($(report.files_by_language["julia"]) Julia, " *
        "$(report.files_by_language["odin"]) Odin, " *
        "$(report.files_by_language["markdown"]) Markdown)")

    write_engine_summary(io, report.engines)
    write_rule_summary(io, report.rules)
    write_ignored_summary(io, report.ignored_counts)

    for response in (Report, Warn, Fail)
        findings = filter(
            diagnostic -> diagnostic.response == response,
            report.diagnostics)
        isempty(findings) && continue
        limit = response == Warn ? warning_limit : report_limit
        response == Fail && (limit = typemax(Int))
        write_response_group(
            io,
            report.root,
            response,
            findings,
            limit,
            use_color)
    end

    write_engine_failures(io, report.engines, use_color)
    write_analysis_summary(io, report.diagnostics, use_color)
    println(io)
    status = styled(
        status_text(report.exit_code),
        status_style(report.exit_code),
        use_color)
    println(io, status)
end

"""Write a compact severity matrix at the end of text analysis output."""
function write_analysis_summary(io, diagnostics, use_color)
    responses = (Report, Warn, Fail)
    rows = map(responses) do response
        findings = filter(item -> item.response == response, diagnostics)
        (
            response=response,
            findings=length(findings),
            files=length(Set(item.path for item in findings)),
            rules=length(Set(item.rule_id for item in findings)))
    end
    labels = [uppercasefirst(response_name(row.response)) for row in rows]
    label_width = max(length("Analysis Summary:"), maximum(length, labels))
    findings_width = max(length("Findings"), maximum(row -> ndigits(row.findings), rows))
    files_width = max(length("Files"), maximum(row -> ndigits(row.files), rows))
    rules_width = max(length("Rules"), maximum(row -> ndigits(row.rules), rows))

    println(io)
    println(io, rpad("Analysis Summary:", label_width), " | ",
        lpad("Findings", findings_width), "  ",
        lpad("Files", files_width), "  ", lpad("Rules", rules_width))
    for (row, label) in zip(rows, labels)
        padded_label = rpad(label, label_width)
        row_style = row.findings == 0 ? "" : summary_style(row.response)
        print(io, styled(padded_label, row_style, use_color), " | ")
        println(io, lpad(row.findings, findings_width), "  ",
            lpad(row.files, files_width), "  ", lpad(row.rules, rules_width))
    end
    reviewed = filter(
        item -> item.reviewed_policy_id !== nothing,
        diagnostics)
    if !isempty(reviewed)
        policy_count = length(Set(item.reviewed_policy_id for item in reviewed))
        println(io, "Reviewed allocations: $(length(reviewed)) findings, " *
            "$policy_count policies")
    end
end

"""Return the ANSI summary style for a finding response."""
summary_style(response) = response == Report ? ANSI_CYAN : RESPONSE_STYLES[response]

"""Write the completion status of every analysis engine."""
function write_engine_summary(io, engines)
    println(io)
    println(io, "ENGINES")
    for engine in engines
        println(io, "  $(uppercase(engine.status))  $(engine.name)")
    end
end

"""Write rule execution status and finding counts."""
function write_rule_summary(io, rules)
    println(io)
    println(io, "RULES")
    for rule in rules
        status = uppercase(replace(rule.status, '-' => ' '))
        response = uppercase(response_name(rule.response))
        details = rule.status == "evaluated" ?
            "$(rule.files_checked) files, $(rule.findings) findings" :
            "$(rule.findings) findings"
        println(io, "  $status  $(rule.rule_id) [$response] - $details")
    end
end

"""Return whether ANSI styling is enabled for an output stream."""
function color_enabled(io::IO, color::Symbol)
    color == :always && return true
    color == :never && return false
    color == :auto || throw(ArgumentError("color must be :auto, :always, or :never"))
    return !haskey(ENV, "NO_COLOR") && get(io, :color, false)
end

"""Wrap text in an ANSI style when styling is enabled."""
function styled(text::AbstractString, style::AbstractString, enabled::Bool)
    return enabled && !isempty(style) ? style * text * ANSI_RESET : text
end

"""Write one response-severity group of diagnostics."""
function write_response_group(io, root, response, findings, limit, use_color)
    label = uppercase(response_name(response))
    heading = "$label ($(length(findings)))"
    println(io)
    println(io, styled(heading, RESPONSE_STYLES[response], use_color))
    shown, omitted = findings_for_display(findings, limit)
    previous_path = nothing
    for diagnostic in shown
        if diagnostic.path != previous_path
            println(io, "  ", diagnostic.path)
            previous_path = diagnostic.path
        end
        path = normpath(joinpath(root, diagnostic.path))
        location = "$path:$(diagnostic.line):$(diagnostic.column):"
        message = first(split(diagnostic.message, '\n'))
        rule_label = diagnostic_label(diagnostic, use_color)
        message = styled(
            message,
            diagnostic_style(diagnostic),
            use_color)
        reviewed_label = reviewed_policy_label(diagnostic, use_color)
        println(io, "    $location  $rule_label$reviewed_label $message")
    end
    omitted > 0 && println(
        io,
        "  ... $omitted more non-allocation $label findings omitted.")
end

"""Return the display label for a diagnostic's reviewed policy."""
function reviewed_policy_label(diagnostic, use_color)
    diagnostic.reviewed_policy_id === nothing && return ""
    label = " [REVIEWED: $(diagnostic.reviewed_policy_id)]"
    return styled(label, ANSI_CYAN, use_color)
end

"""Select diagnostics for display while retaining allocation findings."""
function findings_for_display(findings, limit)
    limit == typemax(Int) && return findings, 0
    allocation_findings = filter(is_allocation_diagnostic, findings)
    ordinary_findings = filter(!is_allocation_diagnostic, findings)
    ordinary_shown = ordinary_findings[1:min(length(ordinary_findings), limit)]
    shown = vcat(ordinary_shown, allocation_findings)
    sort!(shown; by=diagnostic_sort_key)
    return shown, length(ordinary_findings) - length(ordinary_shown)
end

"""Return whether a diagnostic describes Odin allocation behavior."""
is_allocation_diagnostic(diagnostic) =
    startswith(diagnostic.rule_id, "ODIN-ALLOCATION-")

"""Format a diagnostic rule label for human-readable output."""
function diagnostic_label(diagnostic, use_color)
    use_color || return "[$(diagnostic.rule_id)]"
    bracket_style = diagnostic.response == Report ? ANSI_GREEN : ANSI_BOLD_YELLOW
    bracket = styled("[", bracket_style, true)
    rule_id = styled(
        diagnostic.rule_id,
        diagnostic_style(diagnostic),
        true)
    close_bracket = styled("]", bracket_style, true)
    return bracket * rule_id * close_bracket
end

"""Return the ANSI style for a diagnostic's response and category."""
function diagnostic_style(diagnostic)
    diagnostic.response == Report && return ANSI_YELLOW
    if is_allocation_diagnostic(diagnostic) ||
        diagnostic.rule_id == "COMMON-LINE-100"
        return ANSI_BOLD_RED
    end
    diagnostic.rule_id == "COMMON-LINE-90" && return ANSI_BOLD_YELLOW
    return RESPONSE_STYLES[diagnostic.response]
end

"""Write counts for diagnostics ignored by configuration."""
function write_ignored_summary(io, ignored_counts)
    isempty(ignored_counts) && return
    println(io)
    total = sum(values(ignored_counts))
    println(io, "IGNORED ($total)")
    for rule_id in sort!(collect(keys(ignored_counts)))
        println(io, "  $rule_id: $(ignored_counts[rule_id])")
    end
end

"""Write diagnostic details for analysis engines that failed."""
function write_engine_failures(io, engines, use_color)
    failures = filter(engine -> engine.status == "failed", engines)
    isempty(failures) && return
    println(io)
    println(io, styled("TOOL FAILURES ($(length(failures)))", "\e[1;31m", use_color))
    for engine in failures
        println(io, "  $(engine.name): $(something(engine.message, "unknown failure"))")
    end
end

"""Return human-readable policy status for an analyzer exit code."""
function status_text(exit_code::Int)
    exit_code == 0 && return "PASS (exit 0)"
    exit_code == 1 && return "POLICY FAILURE (exit 1)"
    return "ANALYSIS INCOMPLETE (exit 2)"
end

"""Return the ANSI style for an analyzer exit code."""
function status_style(exit_code::Int)
    return exit_code == 0 ? "\e[1;32m" : "\e[1;31m"
end