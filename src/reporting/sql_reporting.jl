const SQL_INVENTORY_FIELDS = (
    :statements, :top_level_statements, :tables, :views, :indexes, :triggers,
    :virtual_tables, :query_blocks, :ctes, :binds, :projections)

"""Show complete source totals independently of procedural metric applicability."""
function write_source_totals(io, totals)
    println(io, "\nSOURCE TOTALS (all discovered languages)")
    for field in fieldnames(SourceTotals)
        write_statistic(io, replace(string(field), '_' => ' '), getfield(totals, field))
    end
end

"""Report independent lexical/structural SQL measurements, including unavailable values."""
function write_sql_statistics(io, sql)
    println(io, "\nSQLITE INVENTORY")
    write_statistic(io, "Files", sql.files)
    write_statistic(io, "Lexical status", sql.lexical_status)
    write_statistic(io, "Structural status", sql.structural_status)
    for field in SQL_INVENTORY_FIELDS
        write_statistic(io, replace(string(field), '_' => ' '), getfield(sql, field))
    end
    sql.reason === nothing || println(io, "Reason: ", sql.reason)
end

"""Show executable statement source ranges, including trigger-owned operations."""
function write_sql_statements(io, statements)
    println(io, "\nSQLITE STATEMENTS")
    println(io, "Kind                Lines       Parent   Terminated")
    for item in statements
        println(io, rpad(item.kind, 20), rpad("$(item.start_line)-$(item.end_line)", 12),
            rpad(statistic_value(item.parent), 9), item.terminated ? "yes" : "no")
    end
end

"""Disclose the exact CC denominator and unchanged Odin/Julia-only estimation scope."""
function write_metric_scope(io, scope)
    println(io, "\nProcedural metrics: ", scope.status, " (Odin/Julia only).")
    println(io, "CC coverage: ", scope.complexity_files, " parsed files, ",
        scope.complexity_code_lines, " code lines. SQL and Markdown excluded.")
    println(io, "Estimate inputs: ", scope.estimate_code_lines,
        " Odin/Julia code lines; SQL and Markdown excluded.")
    scope.reason === nothing || println(io, "Reason: ", scope.reason)
end

"""Write shared source totals to both compact and comprehensive Markdown reports."""
function write_markdown_source_totals(io, statistics)
    println(io, "\n### Shared Source Totals\n")
    println(io, "| Language | Files | Physical | Source | Code | Comment | Blank |")
    println(io, "| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for language in ("odin", "julia", "sql", "markdown", "total")
        totals = language == "total" ? statistics.sources :
            statistics.sources_by_language[language]
        println(io, "| $language | $(totals.files) | $(totals.physical_lines) | ",
            "$(totals.source_lines) | $(totals.code_lines) | ",
            "$(totals.comment_lines) | $(totals.blank_lines) |")
    end
end

"""Show SQL inventories with explicit capability status, not misleading partial counts."""
function write_markdown_sql_statistics(io, sql)
    println(io, "\n### SQLite Inventory\n")
    println(io, "Lexical: $(sql.lexical_status); structural: $(sql.structural_status).")
    sql.reason === nothing || println(io, "\n", markdown_cell(sql.reason))
    println(io, "\n| Measure | Count |\n| --- | ---: |")
    println(io, "| files | $(sql.files) |")
    for field in SQL_INVENTORY_FIELDS
        println(io, "| $(replace(string(field), '_' => ' ')) | ",
            statistic_value(getfield(sql, field)), " |")
    end
end

"""Retain per-file structural completeness and statements in comprehensive reports."""
function write_markdown_sql_files(io, files)
    println(io, "\n## SQLite Source Inventories\n")
    for file in files
        file.language == "sql" || continue
        println(io, "### `$(markdown_cell(file.path))`")
        write_markdown_sql_statistics(io, sql_statistics([file]))
        file.sql === nothing && continue
        file.sql.capabilities.statement_inventory == :complete || continue
        println(io, "\n| Statement | Kind | Lines | Parent | Terminated |")
        println(io, "| ---: | --- | --- | ---: | --- |")
        for (index, item) in enumerate(sql_statement_statistics(file.sql))
            println(io, "| $index | $(item.kind) | $(item.start_line)-$(item.end_line) | ",
                "$(statistic_value(item.parent)) | $(item.terminated) |")
        end

    end
end

"""Expose runtime evidence without implying structural or behavioral correctness."""
function write_sqlite_validation(io, validation)
    println(io, "\nSQLITE RUNTIME VALIDATION: ", validation.status)
    validation.message === nothing || println(io, validation.message)
    for case in validation.cases
        println(io, "Case ", case.id, ": ", case.status)
        if case.provider !== nothing
            println(io, "  Provider: ", case.provider.identity, " ", case.provider.version,
                "; capabilities: ", join(case.provider.capabilities, ", "))
        end
        case.message === nothing || println(io, "  ", case.message)
        write_sqlite_failure(io, case.failure)
        println(io, "  Transaction complete: ", case.transaction_complete,
            "; finalized: ", case.finalized, "; closed: ", case.closed)
        for step in case.steps
            println(io, "  ", step.id, " [", step.source_id, "] (", step.mode,
                "): ", step.status,
                "; ", step.statement_count, " statements; ", step.processed_bytes, " bytes")
            write_sqlite_failure(io, step.failure)
        end
        isempty(case.stderr) || println(io, "  Runner stderr: ", case.stderr)
    end
    println(io, "Dedicated SQL coverage: ", count(item -> item.validated, validation.coverage),
        "/", length(validation.coverage), "; required: ", validation.require_coverage)
    for item in validation.coverage
        println(io, "  ", item.path, ": declared=", item.declared,
            ", attempted=", item.attempted, ", prepared=", item.prepared,
            ", executed=", item.executed, ", validated=", item.validated)
    end
end

"""Retain native phase, codes and source-relative offset in human failure output."""
function write_sqlite_failure(io, failure)
    failure === nothing && return
    println(io, "  Failure [", failure.phase, "] SQLite ", failure.primary_code,
        "/", failure.extended_code, " at byte ", statistic_value(failure.offset),
        ": ", failure.message)
end

"""Write runtime status and declared/attempted/prepared/executed coverage separately."""
function write_markdown_sqlite_validation(io, validation)
    println(io, "\n## SQLite Runtime Validation\n")
    println(io, "Status: ", validation.status, ".")
    validation.message === nothing || println(io, "\n", markdown_cell(validation.message))
    for case in validation.cases
        write_markdown_sqlite_case(io, case)
    end
    println(io, "\nCoverage required: ", validation.require_coverage, ".")
    println(io, "\n| Source | Declared | Attempted | Prepared | Executed | Validated |")
    println(io, "| --- | --- | --- | --- | --- | --- |")
    for item in validation.coverage
        println(io, "| ", markdown_cell(item.path), " | ", item.declared, " | ",
            item.attempted, " | ", item.prepared, " | ", item.executed, " | ",
            item.validated, " |")
    end
end

"""Render copied native failure details with source-relative byte locations."""
function write_markdown_sqlite_failure(io, failure)
    failure === nothing && return
    println(io, "\nFailure **", failure.phase, "**: SQLite ", failure.primary_code,
        "/", failure.extended_code, ", byte ", statistic_value(failure.offset),
        ": ", markdown_cell(failure.message))
end

"""Expose case cleanup, execution modes and native failures independently of coverage."""
function write_markdown_sqlite_case(io, case)
    println(io, "\nCase `", markdown_cell(case.id), "`: ", case.status, ".")
    if case.provider !== nothing
        println(io, "\nProvider: ", markdown_cell(case.provider.identity), " ",
            markdown_cell(case.provider.version), ".")
    end
    case.message === nothing || println(io, "\n", markdown_cell(case.message))
    write_markdown_sqlite_failure(io, case.failure)
    println(io, "\nTransaction complete: ", case.transaction_complete,
        "; finalized: ", case.finalized, "; closed: ", case.closed, ".")
    println(io, "\n| Step | Mode | Status | Statements | Processed bytes |")
    println(io, "| --- | --- | --- | ---: | ---: |")
    for step in case.steps
        println(io, "| ", markdown_cell(step.id), " | ", step.mode, " | ",
            step.status, " | ", step.statement_count, " | ", step.processed_bytes, " |")
    end
    for step in case.steps
        step.failure === nothing && continue
        println(io, "\nStep `", markdown_cell(step.id), "` source `",
            markdown_cell(step.source_id), "`:")
        write_markdown_sqlite_failure(io, step.failure)
    end
    isempty(case.stderr) || println(io, "\nRunner stderr: ", markdown_cell(case.stderr))
end
