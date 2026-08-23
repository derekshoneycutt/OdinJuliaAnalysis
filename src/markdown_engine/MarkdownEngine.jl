module MarkdownEngine

using Markdown
using MarkdownAST

using ..OdinJuliaAnalysis: Diagnostic
using ..OdinJuliaAnalysis: EffectiveSettings
using ..OdinJuliaAnalysis: Ignore
using ..OdinJuliaAnalysis: configured_diagnostic

export check

"""Check configured structural rules for one Markdown document."""
function check(
    path::String,
    source::String,
    configuration::EffectiveSettings;
    filesystem_path::String=path)
    diagnostics = Diagnostic[]
    ast = convert(MarkdownAST.Node, Markdown.parse(source))
    headings = collect_headings(ast, source)
    check_h1_count!(diagnostics, configuration, path, headings)
    check_heading_levels!(diagnostics, configuration, path, headings)
    check_links_and_images!(
        diagnostics, configuration, path, filesystem_path, source, ast)
    check_code_fence_languages!(diagnostics, configuration, path, source)
    return diagnostics
end

"""Collect MarkdownAST heading levels and their source lines in document order."""
function collect_headings(ast, source)
    heading_lines = collect_heading_lines(source)
    headings = Tuple{Int, Int}[]
    heading_index = Ref(0)
    visit_nodes(ast) do node
        node.element isa MarkdownAST.Heading || return
        heading_index[] += 1
        line = get(heading_lines, heading_index[], 1)
        push!(headings, (line, node.element.level))
    end
    return headings
end

"""Locate ATX and setext headings for diagnostic source positions."""
function collect_heading_lines(source)
    lines = split(source, '\n'; keepempty=true)
    locations = Int[]
    in_fence = false
    fence_character = nothing
    fence_length = 0

    for (line_number, line) in enumerate(lines)
        fence = match(r"^\s*(`{3,}|~{3,})(.*)$", line)
        if fence !== nothing
            marker = something(fence.captures[1])
            if !in_fence
                in_fence = true
                fence_character = first(marker)
                fence_length = length(marker)
            elseif first(marker) == fence_character && length(marker) >= fence_length
                in_fence = false
            end
            continue
        end
        in_fence && continue

        occursin(r"^\s*(?:>\s*)*#{1,6}(?:\s+|$)", line) &&
            push!(locations, line_number)
        line_number == 1 && continue
        occursin(r"^\s*(?:>\s*)*(?:=+|-+)\s*$", line) &&
            !isempty(strip(lines[line_number - 1])) && push!(locations, line_number - 1)
    end
    return locations
end

"""Report fenced code blocks without language tags."""
function check_code_fence_languages!(diagnostics, configuration, path, source)
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
        end
    end
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

"""Append diagnostics for broken relative links and images without alt text."""
function check_links_and_images!(
    diagnostics,
    configuration,
    path,
    filesystem_path,
    source,
    ast)
    search_offsets = Dict{String, Int}()
    visit_nodes(ast) do node
        element = node.element
        if element isa MarkdownAST.Link
            check_relative_link!(
                diagnostics,
                configuration,
                path,
                filesystem_path,
                source,
                element.destination,
                search_offsets)
        elseif element isa MarkdownAST.Image && isempty(strip(node_text(node)))
            line, column = source_location!(
                source,
                isempty(element.destination) ? "![" : element.destination,
                search_offsets)
            add_diagnostic!(
                diagnostics,
                configuration,
                "MARKDOWN-IMAGE-ALT-TEXT",
                path,
                line,
                column,
                "Markdown image is missing alt text.")
        end
    end
end

"""Append a diagnostic when a local Markdown link target does not exist."""
function check_relative_link!(
    diagnostics,
    configuration,
    path,
    filesystem_path,
    source,
    destination,
    search_offsets)
    is_relative_link(destination) || return
    target = first(split(destination, r"[?#]"; limit=2))
    isempty(target) && return
    resolved = normpath(joinpath(dirname(filesystem_path), target))
    ispath(resolved) && return
    line, column = source_location!(source, destination, search_offsets)
    add_diagnostic!(
        diagnostics,
        configuration,
        "MARKDOWN-RELATIVE-LINK",
        path,
        line,
        column,
        "Relative Markdown link target does not exist: '$destination'.")
end

"""Return whether a destination should resolve against the Markdown file."""
function is_relative_link(destination)
    isempty(destination) && return false
    (startswith(destination, "#") || startswith(destination, "/")) && return false
    startswith(destination, "//") && return false
    return !occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", destination)
end

"""Return concatenated text descendants of one MarkdownAST node."""
function node_text(node)
    text = IOBuffer()
    visit_nodes(node) do descendant
        descendant.element isa MarkdownAST.Text || return
        print(text, descendant.element.text)
    end
    return String(take!(text))
end

"""Visit a MarkdownAST node and all descendants in document order."""
function visit_nodes(visitor, node)
    visitor(node)
    for child in node.children
        visit_nodes(visitor, child)
    end
end

"""Find the next source occurrence of a node value and advance its search offset."""
function source_location!(source, needle, search_offsets)
    start = get(search_offsets, needle, firstindex(source))
    location = findnext(needle, source, start)
    location === nothing && return (1, 1)
    search_offsets[needle] = nextind(source, last(location))
    prefix = SubString(source, firstindex(source), first(location))
    line = count(==('\n'), prefix) + 1
    previous_newline = findprev(==('\n'), source, prevind(source, first(location)))
    column = previous_newline === nothing ? first(location) :
        first(location) - previous_newline
    return (line, column)
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