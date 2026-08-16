const IGNORED_PAREN_TOKEN_KINDS = Set([
    JuliaSyntax.K"Whitespace",
    JuliaSyntax.K"NewlineWs",
    JuliaSyntax.K"Comment",
])

mutable struct ParenthesisFrame
    last_interior_byte::Union{Nothing, Int}
end

"""Report closing parentheses placed on a different line from content."""
function check_closing_parentheses(
    path::String,
    source::String,
    configuration::EffectiveSettings)
    diagnostics = Diagnostic[]
    frames = ParenthesisFrame[]
    line_starts = source_line_starts(source)

    for token in JuliaSyntax.tokenize(source)
        token_range = getfield(token, :range)
        first_byte = Int(first(token_range))
        token_kind = JuliaSyntax.kind(token)
        if token_kind == JuliaSyntax.K"("
            isempty(frames) || (frames[end].last_interior_byte = first_byte)
            push!(frames, ParenthesisFrame(nothing))
        elseif token_kind == JuliaSyntax.K")"
            isempty(frames) && continue
            frame = pop!(frames)
            add_closing_parenthesis_diagnostic!(
                diagnostics,
                configuration,
                path,
                source,
                line_starts,
                frame,
                first_byte)
            isempty(frames) || (frames[end].last_interior_byte = first_byte)
        elseif token_kind ∉ IGNORED_PAREN_TOKEN_KINDS
            isempty(frames) || (frames[end].last_interior_byte = first_byte)
        end
    end
    return diagnostics
end

"""Append a diagnostic when a closing parenthesis violates placement rules."""
function add_closing_parenthesis_diagnostic!(
    diagnostics,
    configuration,
    path,
    source,
    line_starts,
    frame,
    closing_byte)
    frame.last_interior_byte === nothing && return
    interior_line = source_line(line_starts, frame.last_interior_byte)
    closing_line = source_line(line_starts, closing_byte)
    interior_line == closing_line && return
    column = source_column(source, line_starts[closing_line], closing_byte)
    diagnostic = Diagnostic(
        "JULIA-CLOSING-PAREN-PLACEMENT",
        Ignore,
        path,
        closing_line,
        column,
        "Closing `)` must remain on the same line as the final argument or parameter.",
        nothing,
        nothing,
        "julia-syntax")
    configured = configured_diagnostic(configuration, diagnostic)
    configured === nothing || push!(diagnostics, configured)
end

"""Return byte offsets for the start of every source line."""
function source_line_starts(source::String)
    starts = Int[1]
    for index in eachindex(source)
        source[index] == '\n' && push!(starts, nextind(source, index))
    end
    return starts
end

"""Map a source byte offset to its one-based line number."""
source_line(line_starts, byte) = searchsortedlast(line_starts, byte)

"""Return the one-based source column for a byte offset and line start."""
function source_column(source::String, line_start::Int, byte::Int)
    line_start == byte && return 1
    return length(SubString(source, line_start, prevind(source, byte))) + 1
end