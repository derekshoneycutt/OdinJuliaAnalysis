const SQL_RULE_IDS = (
    "SQL-KEYWORD-CASING", "SQL-SEMICOLON", "SQL-NUMBERED-BINDS",
    "SQL-EXPLICIT-AS", "SQL-PROJECTION-WILDCARD", "SQL-COMMA-JOIN")
const MAX_STRUCTURAL_DEPTH = 64

struct StructuralGap <: Exception
    span::SQLSourceSpan
    message::String
end

mutable struct SQLParser
    lexical::SQLSourceEvidence
    indices::Vector{Int}
    links::Vector{Int}
    position::Int
    limit::Int
    depth::Int
    statement::Int
    query::Union{Nothing, Int}
    structure::SQLStructure
end

"""Build a comment-free cursor with constant-time parenthesis navigation."""
function SQLParser(lexical)
    indices = findall(token -> token.kind != :comment, lexical.tokens)
    reverse = zeros(Int, length(lexical.tokens))
    for (index, original) in enumerate(indices)
        reverse[original] = index
    end
    links = [lexical.delimiter_links[original] == 0 ? 0 :
        reverse[lexical.delimiter_links[original]] for original in indices]
    return SQLParser(lexical, indices, links, 1, length(indices) + 1,
        0, 0, nothing, SQLStructure())
end

"""Return a significant token's source span, including a safe EOF span."""
function token_span(parser, position=parser.position)
    position > length(parser.indices) && return SQLSourceSpan(
        ncodeunits(parser.lexical.source) + 1, ncodeunits(parser.lexical.source) + 1)
    return parser.lexical.tokens[parser.indices[position]].span
end

"""Decode an owned token only when grammar dispatch needs its spelling."""
function token_text(parser, position=parser.position)
    position >= parser.limit && return ""
    span = token_span(parser, position)
    return SubString(parser.lexical.source, span.first_byte,
        prevind(parser.lexical.source, span.after_last_byte))
end

"""Return a significant token's lexical category."""
function token_kind(parser, position=parser.position)
    position >= parser.limit && return :eof
    return parser.lexical.tokens[parser.indices[position]].kind
end

"""Compare grammar keywords only for unquoted word tokens."""
function at(parser, spelling, position=parser.position)
    position >= parser.limit && return false
    text = token_text(parser, position)
    return token_kind(parser, position) == :word ?
        uppercase(text) == spelling : text == spelling
end

"""Consume punctuation or a grammar-selected keyword and retain casing evidence."""
function accept!(parser, spelling)
    at(parser, spelling) || return false
    token_kind(parser) == :word && push!(parser.structure.keywords, token_span(parser))
    parser.position += 1
    return true
end

"""Stop one unsupported region without pretending to reject valid SQLite syntax."""
function gap(parser, message)
    throw(StructuralGap(token_span(parser), message))
end

"""Require a structural delimiter or keyword, not database syntax acceptance."""
function expect!(parser, spelling)
    accept!(parser, spelling) || gap(parser, "Expected structural $spelling.")
end

"""Consume an identifier in a grammar-defined naming position, including keywords."""
function identifier!(parser)
    token_kind(parser) in (:word, :quoted_identifier, :string) ||
        gap(parser, "Unsupported identifier form.")
    span = token_span(parser)
    parser.position += 1
    return span
end

"""Consume an optionally schema-qualified object name."""
function object_name!(parser)
    first = identifier!(parser)
    accept!(parser, ".") || return nothing, first
    return first, identifier!(parser)
end

"""Return the consumed region from a significant-token starting index."""
function consumed_span(parser, start)
    first = token_span(parser, start).first_byte
    after = parser.position > start ?
        token_span(parser, parser.position - 1).after_last_byte : first
    return SQLSourceSpan(first, after)
end

"""Bound recursive expression, query and grouped-source descent."""
function enter!(parser)
    parser.depth < MAX_STRUCTURAL_DEPTH || gap(parser,
        "Structural nesting exceeds $MAX_STRUCTURAL_DEPTH.")
    parser.depth += 1
end

"""Consume a named column list without interpreting its names as keywords."""
function identifier_list!(parser)
    expect!(parser, "(")
    identifier!(parser)
    while accept!(parser, ",")
        identifier!(parser)
    end
    expect!(parser, ")")
end

"""Skip opaque module/type syntax using validated delimiter links."""
function opaque_group!(parser)
    at(parser, "(") || gap(parser, "Expected delimited module or declaration syntax.")
    closing = parser.links[parser.position]
    closing > 0 && closing < parser.limit || gap(parser, "Unlinked declaration group.")
    start = parser.position
    parser.position = closing + 1
    return consumed_span(parser, start)
end

"""Preserve bind evidence even when deeper structure is unsupported."""
function collect_binds!(parser)
    arguments = sort!([item.module_arguments for item in parser.structure.declarations
        if item.module_arguments !== nothing]; by=span -> span.first_byte)
    region = 1
    for token in parser.lexical.tokens
        token.kind == :bind || continue
        span = token.span
        while region <= length(arguments) &&
            arguments[region].after_last_byte <= span.first_byte
            region += 1
        end
        if region <= length(arguments) &&
            arguments[region].first_byte <= span.first_byte <
                arguments[region].after_last_byte
            continue
        end
        text = SubString(parser.lexical.source, span.first_byte,
            prevind(parser.lexical.source, span.after_last_byte))
        form = startswith(text, "?") ? (text == "?" ? :anonymous : :numbered) : :named
        slot = form == :numbered ? tryparse(Int, text[2:end]) : nothing
        push!(parser.structure.binds, SQLBindRecord(span, form, slot))
    end
end

"""Parse structural evidence independently of SQLite acceptance or execution."""
function analyze(source::String)
    lexical = lex(source)
    parser = SQLParser(lexical)
    complete = isempty(lexical.issues)
    complete && parse_script!(parser)
    collect_binds!(parser)
    complete &= isempty(parser.structure.gaps)
    for rule in SQL_RULE_IDS
        lexical_rule = rule == "SQL-NUMBERED-BINDS"
        parser.structure.rules[rule] = (lexical_rule ?
            lexical.capabilities.lexical_accounting == :complete : complete) ?
            :evaluated : :incomplete
    end
    capabilities = SQLCapabilities(
        lexical.capabilities.lexical_accounting, lexical.capabilities.delimiter_links,
        complete ? :complete : :incomplete, complete ? :complete : :incomplete)
    return SQLSourceEvidence(lexical.source, lexical.tokens, lexical.line_starts,
        lexical.line_kinds, lexical.delimiter_links, lexical.issues,
        capabilities, parser.structure)
end

"""Inventory a complete script, recovering only at lexical statement boundaries."""
function parse_script!(parser)
    while parser.position < parser.limit
        accept!(parser, ";") && continue
        start = parser.position
        try
            parse_statement!(parser, nothing)
        catch error
            error isa StructuralGap || rethrow()
            push!(parser.structure.gaps, SQLCapabilityGap(error.span, error.message))
            parser.position = start
            while parser.position < parser.limit && !accept!(parser, ";")
                parser.position += 1
            end
            parser.depth = 0
            parser.query = nothing
        end
    end
end
