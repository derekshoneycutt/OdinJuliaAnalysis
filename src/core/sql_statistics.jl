"""Reconcile shared physical source accounting without inventing callable declarations."""
function source_totals(files)
    return SourceTotals(length(files),
        sum(file -> file.physical_lines, files; init=0),
        sum(file -> file.source_lines, files; init=0),
        sum(file -> file.code_lines, files; init=0),
        sum(file -> file.comment_lines, files; init=0),
        sum(file -> file.blank_lines, files; init=0))
end

"""Describe coverage of procedural CC separately from unchanged estimate inputs."""
function procedural_scope(files)
    procedural = filter(file -> file.language in ("julia", "odin"), files)
    covered = filter(file -> file.parsed, procedural)
    status = isempty(procedural) ? "not-applicable" :
        length(covered) == length(procedural) ? "applicable" : "incomplete"
    reason = status == "not-applicable" ? "No Odin/Julia source in this scope." :
        status == "incomplete" ? "Some Odin/Julia source lacks parsed complexity evidence." :
        nothing
    return MetricScope(status, ["julia", "odin"], ["sql", "markdown", "hlsl"],
        length(covered), sum(file -> file.code_lines, covered; init=0),
        sum(file -> file.code_lines, procedural; init=0), reason)
end

"""Aggregate only complete SQL inventories; lexical bind counts have independent coverage."""
function sql_statistics(files)
    sql_files = filter(file -> file.language == "sql", files)
    evidence = [file.sql for file in sql_files if file.sql !== nothing]
    lexical = !isempty(sql_files) && length(evidence) == length(sql_files) &&
        all(item -> item.capabilities.lexical_accounting == :complete, evidence)
    structural = lexical && all(item ->
        item.capabilities.statement_inventory == :complete &&
        item.capabilities.query_structure == :complete, evidence)
    absent = isempty(sql_files)
    reasons = sql_measurement_reasons(sql_files)
    return SQLStatistics(length(sql_files),
        absent ? "not-applicable" : lexical ? "complete" : "incomplete",
        absent ? "not-applicable" : structural ? "complete" : "incomplete",
        absent ? "No dedicated SQL source in this scope." :
            isempty(reasons) ? nothing : join(reasons, "\n"),
        sql_inventory_count(evidence, :statements, structural),
        structural ? sum(item -> count(statement -> statement.parent === nothing,
            item.structure.statements), evidence; init=0) : nothing,
        (sql_declaration_count(evidence, kind, structural)
            for kind in (:table, :view, :index, :trigger, :virtual_table))...,
        sql_inventory_count(evidence, :queries, structural),
        sql_inventory_count(evidence, :ctes, structural),
        sql_inventory_count(evidence, :binds, lexical),
        sql_inventory_count(evidence, :projections, structural))
end

"""Explain missing/incomplete source measurement rather than exposing partial zeros."""
function sql_measurement_reasons(files)
    reasons = String[]
    for file in files
        if file.sql === nothing
            push!(reasons, "$(file.path): SQL evidence is unavailable.")
            continue
        end
        for issue in file.sql.issues
            line, column = SQLEngine.source_location(file.sql, issue.span)
            push!(reasons, "$(file.path):$line:$column: $(issue.message)")
        end
        for gap in file.sql.structure.gaps
            line, column = SQLEngine.source_location(file.sql, gap.span)
            push!(reasons, "$(file.path):$line:$column: $(gap.message)")
        end
        capabilities = file.sql.capabilities
        if capabilities.query_structure != :complete &&
            isempty(file.sql.issues) && isempty(file.sql.structure.gaps)
            push!(reasons, "$(file.path): SQL structural evidence is incomplete.")
        end
    end
    return reasons
end

"""Count a supported flat inventory or return unavailable, never a partial clean zero."""
function sql_inventory_count(evidence, field, complete)
    complete || return nothing
    return sum(item -> length(getproperty(item.structure, field)), evidence; init=0)
end

"""Count authored declarations, not SQLite live objects or generated shadow tables."""
function sql_declaration_count(evidence, kind, complete)
    complete || return nothing
    return sum(item -> count(declaration -> declaration.kind == kind,
        item.structure.declarations), evidence; init=0)
end

"""Measure SQL source and optionally select its innermost executable statement."""
function sql_source_statistics(path, source, function_name, line)
    function_name === nothing || throw(ArgumentError(
        "--function is not applicable to SQL; use --line to select a statement"))
    evidence = SQLEngine.analyze(source)
    file = analyze_file(path, path, source, "sql", false, 0; sql=evidence)
    summary = sql_statistics([file])
    complete = summary.structural_status == "complete"
    statements = complete ? sql_statement_statistics(evidence) : SQLStatementStatistics[]
    selected, selection = select_sql_statements(statements, line, complete)
    metrics = FileStatistics(file.parsed, file.physical_lines, file.source_lines,
        file.code_lines, file.comment_lines, file.blank_lines,
        nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing)
    return SourceStatisticsReport("2.0.0", string(VERSION), path, "sql", metrics,
        FunctionStatistics[], selection, summary, selected, procedural_scope([file]))
end

"""Project executable statement spans to physical lines without counting CTEs as statements."""
function sql_statement_statistics(evidence)
    return map(evidence.structure.statements) do item
        start_line = max(1, searchsortedlast(
            evidence.line_starts, item.span.first_byte))
        end_line = max(1, searchsortedlast(
            evidence.line_starts, max(item.span.first_byte, item.span.after_last_byte - 1)))
        SQLStatementStatistics(string(item.kind), item.span.first_byte,
            item.span.after_last_byte, start_line, end_line, item.parent, item.terminated)
    end
end

"""Select the smallest containing executable region; report incomplete selectors explicitly."""
function select_sql_statements(statements, line, complete)
    line === nothing && return statements, nothing
    line > 0 || throw(ArgumentError("line selector must be positive"))
    complete || throw(ArgumentError(
        "SQL statement selection is unavailable because structural analysis is incomplete"))
    matches = filter(item -> item.start_line <= line <= item.end_line, statements)
    isempty(matches) && throw(ArgumentError("no SQL statement contains line $line"))
    selected = argmin(item -> item.after_last_byte - item.first_byte, matches)
    return [selected], StatisticsSelection("statement-line", string(line), 1)
end
