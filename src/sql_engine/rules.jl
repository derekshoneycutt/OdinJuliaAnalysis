"""Convert one byte coordinate to a physical line and Unicode character column."""
function source_location(evidence, span)
    line = max(1, searchsortedlast(evidence.line_starts, span.first_byte))
    start = isempty(evidence.line_starts) ? 1 : evidence.line_starts[line]
    column = 1
    cursor = start
    while cursor < span.first_byte
        cursor = nextind(evidence.source, cursor)
        column += 1
    end
    return line, column
end

"""Create a configured SQL diagnostic without conflating structure and SQLite acceptance."""
function push_finding!(diagnostics, path, evidence, configuration, finding)
    rule, span, message = finding
    line, column = source_location(evidence, span)
    diagnostic = Diagnostic(rule, Ignore, path, line, column, message,
        nothing, nothing, "sql-structure")
    configured = configured_diagnostic(configuration, diagnostic)
    configured === nothing || push!(diagnostics, configured)
end

"""Evaluate only rules with sufficient evidence; lexical binds survive structural gaps."""
function check(path, evidence::SQLSourceEvidence, configuration)
    diagnostics = Diagnostic[]
    for (rule, span, message) in structural_findings(evidence)
        get(evidence.structure.rules, rule, :incomplete) == :evaluated || continue
        push_finding!(diagnostics, path, evidence, configuration, (rule, span, message))
    end
    return diagnostics
end

"""Produce convention findings solely from shared typed structural/lexical records."""
function structural_findings(evidence)
    findings = Tuple{String, SQLSourceSpan, String}[]
    structure = evidence.structure
    for span in structure.keywords
        text = SubString(evidence.source, span.first_byte,
            prevind(evidence.source, span.after_last_byte))
        text == uppercase(text) || push!(findings, (
            "SQL-KEYWORD-CASING", span, "Write SQLite grammar keywords in uppercase."))
    end
    for statement in structure.statements
        statement.terminated || push!(findings, (
            "SQL-SEMICOLON", statement.span, "Terminate authored SQLite statements with a semicolon."))
    end
    append_bind_findings!(findings, structure.binds)
    for alias in structure.aliases
        alias.explicit_as || push!(findings, (
            "SQL-EXPLICIT-AS", alias.span, "Write AS explicitly for SQLite aliases."))
    end
    append_wildcard_findings!(findings, structure.projections)
    for join in structure.joins
        join.comma && push!(findings, (
            "SQL-COMMA-JOIN", join.span, "Use explicit JOIN syntax instead of comma-separated sources."))
    end
    return findings
end

"""Check explicit positive numbered slots without renumbering sparse/repeated occurrences."""
function append_bind_findings!(findings, binds)
    for binding in binds
        if binding.form != :numbered || binding.slot === nothing || binding.slot <= 0
            push!(findings, ("SQL-NUMBERED-BINDS", binding.span,
                "Use explicit positive numbered SQLite bind slots such as ?1."))
        end
    end
end

"""Allow wildcard-only EXISTS projections, never exposed result interfaces."""
function append_wildcard_findings!(findings, projections)
    counts = Dict{Int, Int}()
    for projection in projections
        counts[projection.query] = get(counts, projection.query, 0) + 1
    end
    for projection in projections
        projection.wildcard || continue
        exempt = projection.exists_only && counts[projection.query] == 1 &&
            projection.alias === nothing
        exempt || push!(findings, ("SQL-PROJECTION-WILDCARD", projection.span,
            "Expose explicit result columns instead of a projection wildcard."))
    end
end
