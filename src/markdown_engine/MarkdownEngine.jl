module MarkdownEngine

using ..OdinJuliaAnalysis: Diagnostic
using ..OdinJuliaAnalysis: EffectiveSettings
using ..OdinJuliaAnalysis: Ignore
using ..OdinJuliaAnalysis: configured_diagnostic

export check

"""Check configured structural rules for one Markdown document."""
function check(path::String, source::String, configuration::EffectiveSettings)
    diagnostics = Diagnostic[]
    headings = collect_headings!(diagnostics, path, source, configuration)
    check_h1_count!(diagnostics, configuration, path, headings)
    check_heading_levels!(diagnostics, configuration, path, headings)
    return diagnostics
end

"""Collect headings outside fences and report fences without language tags."""
function collect_headings!(diagnostics, path, source, configuration)
    headings = Tuple{Int, Int}[]
    fence_character = nothing
    fence_length = 0

    for (line_number, line) in enumerate(split(source, '\n'; keepempty=true))
        fence = match(r"^\s*(`{3,}|~{3,})(.*)$", line)
        if fence !== nothing
            marker = something(fence.captures[1])
            info = something(fence.captures[2])
            if fence_character === nothing
                fence_character = first(marker)
                fence_length = length(marker)
                isempty(strip(info)) && add_diagnostic!(
                    diagnostics,
                    configuration,
                    "MARKDOWN-CODE-FENCE-LANGUAGE",
                    path,
                    line_number,
                    findfirst(!isspace, line),
                    "Fenced code block is missing a language tag.")
                    elseif first(marker) == fence_character &&
                        length(marker) >= fence_length &&
                    isempty(strip(info))
                fence_character = nothing
                fence_length = 0
            end
            continue
        end

        fence_character === nothing || continue
        heading = match(r"^(#{1,6})\s+", line)
        heading === nothing || push!(
            headings,
            (line_number, length(something(heading.captures[1]))))
    end
    return headings
end

"""Append diagnostics when a Markdown document lacks exactly one H1."""
function check_h1_count!(diagnostics, configuration, path, headings)
    h1_count = count(heading -> heading[2] == 1, headings)
    h1_count == 1 && return
    add_diagnostic!(
        diagnostics,
        configuration,
        "MARKDOWN-SINGLE-H1",
        path,
        isempty(headings) ? 1 : first(headings)[1],
        1,
        "Markdown file must contain exactly one H1; found $h1_count.";
        measured=h1_count,
        allowed=1)
end

"""Append diagnostics for skipped Markdown heading levels."""
function check_heading_levels!(diagnostics, configuration, path, headings)
    isempty(headings) && return
    previous_level = first(headings)[2]
    for (line_number, level) in Iterators.drop(headings, 1)
        if level > previous_level + 1
            add_diagnostic!(
                diagnostics,
                configuration,
                "MARKDOWN-HEADING-LEVELS",
                path,
                line_number,
                1,
                "Heading level jumps from H$previous_level to H$level.";
                measured=level,
                allowed=previous_level + 1)
        end
        previous_level = level
    end
end

"""Create and append an enabled Markdown diagnostic."""
function add_diagnostic!(
    diagnostics,
    configuration,
    rule_id,
    path,
    line,
    column,
    message;
    measured=nothing,
    allowed=nothing)
    diagnostic = Diagnostic(
        rule_id,
        Ignore,
        path,
        line,
        something(column, 1),
        message,
        measured,
        allowed,
        "markdown")
    configured = configured_diagnostic(configuration, diagnostic)
    configured === nothing || push!(diagnostics, configured)
end

end