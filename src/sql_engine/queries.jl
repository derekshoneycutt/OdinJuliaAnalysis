const ALIAS_BOUNDARIES = Set((
    "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "WINDOW",
    "UNION", "INTERSECT", "EXCEPT", "JOIN", "LEFT", "RIGHT", "FULL", "INNER",
    "CROSS", "NATURAL", "OUTER", "ON", "USING", "INDEXED", "NOT", "SET", "VALUES",
    "RETURNING", "DEFAULT", "DO", "WHEN", "THEN", "ELSE", "END"))

"""Identify query introductions without confusing quoted object names."""
query_start(parser) = at(parser, "SELECT") || at(parser, "WITH") || at(parser, "VALUES")

"""Record a query hierarchy, CTEs and compound operands with bounded descent."""
function parse_query!(parser; exists_only=false)
    enter!(parser)
    start = parser.position
    parent = parser.query
    index = length(parser.structure.queries) + 1
    push!(parser.structure.queries, SQLQueryRecord(
        :query, token_span(parser), parser.statement, parent))
    parser.query = index
    accept!(parser, "WITH") && with_clause!(parser)
    query_operand!(parser, exists_only)
    while at(parser, "UNION") || at(parser, "INTERSECT") || at(parser, "EXCEPT")
        compound_operand!(parser, exists_only)
    end
    query_tail!(parser)
    parser.structure.queries[index] = SQLQueryRecord(
        :query, consumed_span(parser, start), parser.statement, parent)
    parser.query = parent
    parser.depth -= 1
    return index
end

"""Consume CTE declarations; names and optional column lists are not aliases."""
function with_clause!(parser)
    accept!(parser, "RECURSIVE")
    while true
        start = parser.position
        name = identifier!(parser)
        at(parser, "(") && identifier_list!(parser)
        expect!(parser, "AS")
        if accept!(parser, "NOT")
            expect!(parser, "MATERIALIZED")
        else
            accept!(parser, "MATERIALIZED")
        end
        expect!(parser, "(")
        parse_query!(parser)
        expect!(parser, ")")
        push!(parser.structure.ctes, SQLCTERecord(
            name, consumed_span(parser, start), parser.statement, parser.query))
        accept!(parser, ",") || break
    end
end

"""Represent every compound SELECT operand as a query block, not a statement."""
function compound_operand!(parser, exists_only)
    expect!(parser, uppercase(token_text(parser)))
    accept!(parser, "ALL") || accept!(parser, "DISTINCT")
    parent = parser.query
    start = parser.position
    index = length(parser.structure.queries) + 1
    push!(parser.structure.queries, SQLQueryRecord(
        :compound_operand, token_span(parser), parser.statement, parent))
    parser.query = index
    query_operand!(parser, exists_only)
    parser.structure.queries[index] = SQLQueryRecord(
        :compound_operand, consumed_span(parser, start), parser.statement, parent)
    parser.query = parent
end

"""Parse SELECT/VALUES cores while keeping expression and FROM commas separate."""
function query_operand!(parser, exists_only)
    if accept!(parser, "VALUES")
        values_rows!(parser)
        return
    end
    expect!(parser, "SELECT")
    accept!(parser, "DISTINCT") || accept!(parser, "ALL")
    projection_list!(parser; exists_only)
    accept!(parser, "FROM") && from_clause!(parser)
    accept!(parser, "WHERE") && expression!(parser)
    if accept!(parser, "GROUP")
        expect!(parser, "BY")
        expression_list!(parser)
    end
    accept!(parser, "HAVING") && expression!(parser)
    at(parser, "WINDOW") && gap(parser, "Named windows are not structurally supported.")
end

"""Parse result interfaces and aliases without flagging function stars or multiplication."""
function projection_list!(parser; exists_only=false)
    while true
        start = parser.position
        wildcard = projection_wildcard!(parser)
        wildcard || expression!(parser)
        expression_span = consumed_span(parser, start)
        alias, explicit = alias!(parser, :projection)
        query = parser.query
        query === nothing && gap(parser, "Projection has no containing query block.")
        push!(parser.structure.projections, SQLProjectionRecord(
            query, expression_span, alias, explicit,
            wildcard, exists_only))
        accept!(parser, ",") || break
    end
end

"""Consume only an entire projection wildcard, never an expression operator."""
function projection_wildcard!(parser)
    accept!(parser, "*") && return true
    if token_kind(parser) in (:word, :quoted_identifier) &&
        at(parser, ".", parser.position + 1) && at(parser, "*", parser.position + 2)
        parser.position += 3
        return true
    end
    return false
end

"""Recognize aliases only after an expression or source has been consumed."""
function alias!(parser, kind)
    explicit = accept!(parser, "AS")
    if explicit
        span = identifier!(parser)
    elseif token_kind(parser) in (:quoted_identifier, :string) ||
        token_kind(parser) == :word && uppercase(token_text(parser)) ∉ ALIAS_BOUNDARIES
        span = identifier!(parser)
    else
        return nothing, false
    end
    push!(parser.structure.aliases, SQLAliasRecord(kind, span, explicit))
    return span, explicit
end

"""Parse sources and JOIN conditions, recording only FROM-level commas."""
function from_clause!(parser)
    from_source!(parser)
    while parser.position < parser.limit
        start = parser.position
        comma = accept!(parser, ",")
        if !comma && !join_operator!(parser)
            break
        end
        push!(parser.structure.joins, SQLJoinRecord(
            parser.query, parser.statement, consumed_span(parser, start), comma))
        from_source!(parser)
        if accept!(parser, "ON")
            expression!(parser)
        elseif accept!(parser, "USING")
            identifier_list!(parser)
        end
    end
end

"""Recognize SQLite explicit join spellings without counting modifier words as aliases."""
function join_operator!(parser)
    accept!(parser, "JOIN") && return true
    modifiers = ("NATURAL", "LEFT", "RIGHT", "FULL", "INNER", "CROSS", "OUTER")
    uppercase(token_text(parser)) in modifiers || return false
    while uppercase(token_text(parser)) in modifiers
        expect!(parser, uppercase(token_text(parser)))
    end
    expect!(parser, "JOIN")
    return true
end

"""Parse table names/functions, subqueries and parenthesized join groups."""
function from_source!(parser)
    enter!(parser)
    if accept!(parser, "(")
        query_start(parser) ? parse_query!(parser) : from_clause!(parser)
        expect!(parser, ")")
    else
        object_name!(parser)
        at(parser, "(") && function_arguments!(parser)
    end
    alias!(parser, :source)
    if accept!(parser, "INDEXED")
        expect!(parser, "BY")
        identifier!(parser)
    elseif accept!(parser, "NOT")
        expect!(parser, "INDEXED")
    end
    parser.depth -= 1
end

"""Parse ORDER/LIMIT including SQLite's comma form without inventing a comma join."""
function query_tail!(parser)
    if accept!(parser, "ORDER")
        expect!(parser, "BY")
        ordering_list!(parser)
    end
    if accept!(parser, "LIMIT")
        expression!(parser)
        (accept!(parser, "OFFSET") || accept!(parser, ",")) && expression!(parser)
    end
end

"""Consume VALUES rows; commas here are data rather than source joins."""
function values_rows!(parser)
    while true
        expect!(parser, "(")
        expression_list!(parser)
        expect!(parser, ")")
        accept!(parser, ",") || break
    end
end
