"""Convert function measurements into highest-applicable response diagnostics."""
function function_metric_diagnostics(functions, configuration)
    diagnostics = Diagnostic[]
    for item in functions
        settings = item.language == "julia" ?
            (
                lines=configuration.function_metrics.julia_lines,
                cyclomatic=configuration.function_metrics.julia_cyclomatic,
                prefix="JULIA",
                noun="function") :
            (
                lines=configuration.function_metrics.odin_lines,
                cyclomatic=configuration.function_metrics.odin_cyclomatic,
                prefix="ODIN",
                noun="procedure")
        append_function_metric_diagnostic!(
            diagnostics,
            configuration,
            item,
            settings.lines,
            "$(settings.prefix)-FUNCTION-LINES",
            item.executable_lines,
            "executable lines",
            settings.noun)
        append_function_metric_diagnostic!(
            diagnostics,
            configuration,
            item,
            settings.cyclomatic,
            "$(settings.prefix)-CYCLOMATIC",
            item.cyclomatic_complexity,
            "cyclomatic complexity",
            settings.noun)
    end
    return diagnostics
end

"""Append one configured finding for the highest exceeded metric threshold."""
function append_function_metric_diagnostic!(
    diagnostics,
    configuration,
    item,
    thresholds,
    rule_prefix,
    measured,
    metric_name,
    noun)
    tier, allowed = function_metric_tier(measured, thresholds)
    tier === nothing && return
    rule_id = "$rule_prefix-$tier"
    diagnostic = Diagnostic(
        rule_id,
        Ignore,
        item.path,
        item.start_line,
        1,
        "$(uppercasefirst(item.language)) $(noun) `$(item.name)` has " *
            "$(measured) $(metric_name); $(lowercase(tier)) maximum is $(allowed).",
        measured,
        allowed,
        "function-metrics",
        item.name,
        replace(metric_name, ' ' => '_'),
        nothing,
        "stable")
    configured = configured_diagnostic(configuration, diagnostic)
    configured === nothing || push!(diagnostics, configured)
end

"""Return the highest response tier exceeded by one measurement."""
function function_metric_tier(measured, thresholds)
    measured > thresholds.fail && return "FAIL", thresholds.fail
    measured > thresholds.warn && return "WARN", thresholds.warn
    measured > thresholds.report && return "REPORT", thresholds.report
    return nothing, nothing
end

"""Check language-neutral source rules and return configured diagnostics."""
function check_common_rules(
    path::String,
    source::String,
    configuration::EffectiveSettings=load_settings())
    diagnostics = Diagnostic[]
    lines = split(source, '\n'; keepempty=true)
    line_length_exemptions = find_line_length_exemptions(path, lines)

    for (line_number, line) in enumerate(lines)
        line_number in line_length_exemptions || check_line_length!(
            diagnostics,
            path,
            line_number,
            line,
            configuration)
        check_tabs!(diagnostics, path, line_number, line, configuration)
    end

    return diagnostics
end

"""Return source lines exempt from line-length enforcement."""
function find_line_length_exemptions(path, lines)
    endswith(path, ".md") && return markdown_line_length_exemptions(lines)
    endswith(path, ".jl") && return comment_line_exemptions(
        lines,
        "#",
        "#=",
        "=#")
    endswith(path, ".odin") && return comment_line_exemptions(
        lines,
        "//",
        "/*",
        "*/")
    return Set{Int}()
end

"""Return Markdown lines exempt because of structural content."""
function markdown_line_length_exemptions(lines)
    exemptions = Set{Int}()
    outside_fence = markdown_fence_and_link_exemptions!(exemptions, lines)
    append_markdown_table_exemptions!(exemptions, lines, outside_fence)
    return exemptions
end

"""Mark fenced lines and links, returning which lines remain outside fences."""
function markdown_fence_and_link_exemptions!(exemptions, lines)
    outside_fence = trues(length(lines))
    fence_character = nothing
    fence_length = 0

    for (line_number, line) in enumerate(lines)
        fence = match(r"^\s*(`{3,}|~{3,})", line)
        if fence !== nothing
            marker = something(fence.captures[1])
            if fence_character === nothing
                fence_character = first(marker)
                fence_length = length(marker)
            elseif first(marker) == fence_character && length(marker) >= fence_length
                fence_character = nothing
                fence_length = 0
            end
            outside_fence[line_number] = false
            continue
        end
        outside_fence[line_number] = fence_character === nothing
        if outside_fence[line_number] && is_markdown_link_line(line)
            push!(exemptions, line_number)
        end
    end
    return outside_fence
end

"""Append complete Markdown table spans to line-length exemptions."""
function append_markdown_table_exemptions!(exemptions, lines, outside_fence)
    for line_number in 2:length(lines)
        outside_fence[line_number] || continue
        is_markdown_table_delimiter(lines[line_number]) || continue
        is_markdown_table_row(lines[line_number - 1]) || continue
        push!(exemptions, line_number - 1, line_number)
        row_number = line_number + 1
        while row_number <= length(lines) && outside_fence[row_number] &&
                is_markdown_table_row(lines[row_number])
            push!(exemptions, row_number)
            row_number += 1
        end
    end
end

"""Return whether a line contains Markdown link syntax."""
function is_markdown_link_line(line)
    return occursin(r"\[[^\]]+\]\([^\)]+\)", line) ||
        occursin(r"^\s*\[[^\]]+\]:\s*\S+", line) ||
        occursin(r"<(?:https?://|mailto:)[^>]+>", line) ||
        occursin(r"https?://\S+", line)
end

"""Return whether a line is a Markdown table row."""
is_markdown_table_row(line) = !isempty(strip(line)) && occursin('|', line)

"""Return whether a line is a Markdown table delimiter row."""
is_markdown_table_delimiter(line) = occursin(
    r"^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$",
    line)

"""Return lines containing comments without executable source."""
function comment_line_exemptions(lines, line_marker, block_open, block_close)
    exemptions = Set{Int}()
    block_depth = 0
    for (line_number, line) in enumerate(lines)
        block_depth, comment_only = scan_comment_line(
            line,
            block_depth,
            line_marker,
            block_open,
            block_close)
        comment_only && push!(exemptions, line_number)
    end
    return exemptions
end

"""Return comment-only line numbers for a supported source language."""
function source_comment_lines(path, lines)
    endswith(path, ".jl") && return comment_line_exemptions(lines, "#", "#=", "=#")
    endswith(path, ".odin") && return comment_line_exemptions(
        lines, "//", "/*", "*/")
    return Set{Int}()
end

"""Count code-bearing lines within an inclusive source span."""
function executable_source_lines(path, lines, start_line, end_line)
    comments = source_comment_lines(path, lines)
    return count(start_line:end_line) do line_number
        !isempty(strip(lines[line_number])) && line_number ∉ comments
    end
end

"""Scan one line and return updated block depth and comment-only status."""
function scan_comment_line(line, block_depth, line_marker, block_open, block_close)
    isempty(line) && return block_depth, false
    index = firstindex(line)
    saw_comment = block_depth > 0
    while index <= lastindex(line)
        if block_depth > 0
            if marker_at(line, block_open, index)
                block_depth += 1
                index = nextind(line, index, length(block_open))
            elseif marker_at(line, block_close, index)
                block_depth -= 1
                index = nextind(line, index, length(block_close))
            else
                index = nextind(line, index)
            end
        elseif isspace(line[index])
            index = nextind(line, index)
        elseif marker_at(line, block_open, index)
            saw_comment = true
            block_depth += 1
            index = nextind(line, index, length(block_open))
        elseif marker_at(line, line_marker, index)
            return block_depth, true
        else
            return block_depth, false
        end
    end
    return block_depth, saw_comment
end

"""Return whether a marker starts at the supplied string index."""
function marker_at(line, marker, index)
    return startswith(SubString(line, index), marker)
end

"""Append configured line-length diagnostics for one source line."""
function check_line_length!(diagnostics, path, line_number, line, configuration)
    diagnostic = line_length_diagnostic(path, line_number, line, configuration.thresholds)
    diagnostic === nothing || add_configured_diagnostic!(
        diagnostics, configuration, diagnostic)
end

"""Return the highest configured line-length tier exceeded by one line."""
function line_length_diagnostic(path, line_number, line, thresholds)
    width = length(line)
    tier = line_length_tier(width, thresholds)
    tier === nothing && return nothing
    return Diagnostic(
        tier.rule_id,
        Ignore,
        path,
        line_number,
        tier.allowed + 1,
        tier.message,
        width,
        tier.allowed,
        "frontend")
end

"""Return rule metadata for the highest line-length tier exceeded."""
function line_length_tier(width, thresholds)
    if width > thresholds.line_hard
        return (
            rule_id="COMMON-LINE-120",
            allowed=thresholds.line_hard,
            message="Line exceeds the hard $(thresholds.line_hard)-character limit.")
    elseif width > thresholds.line_discouraged
        return (
            rule_id="COMMON-LINE-100",
            allowed=thresholds.line_discouraged,
            message="Line exceeds the discouraged " *
                "$(thresholds.line_discouraged)-character limit.")
    elseif width > thresholds.line_warning
        return (
            rule_id="COMMON-LINE-90",
            allowed=thresholds.line_warning,
            message="Line exceeds the " *
                "$(thresholds.line_warning)-character warning threshold.")
    end
            return nothing
end

"""Append configured diagnostics for tabs in one source line."""
function check_tabs!(diagnostics, path, line_number, line, configuration)
    column = findfirst(==('\t'), line)
    column === nothing && return

    add_configured_diagnostic!(diagnostics, configuration, Diagnostic(
        "COMMON-NO-TABS",
        Ignore,
        path,
        line_number,
        column,
        "Tabs are disallowed; use four-space indentation.",
        nothing,
        nothing,
        "frontend"))
end

"""Append a diagnostic when its configured rule is enabled."""
function add_configured_diagnostic!(diagnostics, configuration, diagnostic)
    configured = configured_diagnostic(configuration, diagnostic)
    configured === nothing || push!(diagnostics, configured)
end