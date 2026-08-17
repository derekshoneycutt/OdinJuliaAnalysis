"""Write the complete human-readable analysis artifact as Markdown."""
function write_markdown_report(io::IO, report::AnalysisReport)
    println(io, "# Odin-Julia Analysis Report")
    write_markdown_metadata(io, report)
    write_markdown_summary(io, report)
    write_markdown_statistics(io, report.statistics)
    write_markdown_thresholds(
        io, report.thresholds, report.parameter_counts, report.function_metrics)
    write_markdown_files(io, report)
    write_markdown_dependencies(io, report)
    write_markdown_declarations(io, report)
    write_markdown_import_bindings(io, report)
    write_markdown_references(io, report)
    write_markdown_call_roots(io, report)
    write_markdown_call_graph(io, report)
    write_markdown_interop(io, report)
    write_markdown_functions(io, report)
    write_markdown_odin_builds(io, report)
    write_markdown_findings(io, report)
    write_markdown_allocations(io, report)
    write_markdown_ignored(io, report)
    write_markdown_rules(io, report)
    write_markdown_extensions(io, report)
    write_markdown_engines(io, report)
end

"""Write configured and inferred call roots by lifecycle category."""
function write_markdown_call_roots(io, report)
    println(io)
    println(io, "## Call Roots")
    isempty(report.call_roots) && return println(io, "\nNo call roots were found.")
    println(io, "\n| ID | Source | Language | Declaration | Category |")
    println(io, "| --- | --- | --- | --- | --- |")
    for root in report.call_roots
        println(io, "| `$(markdown_cell(root.id))` | `$(markdown_cell(root.path))` | ",
            "$(root.language) | `$(markdown_cell(root.declaration))` | ",
            "$(root.category) |")
    end
end

"""Write explicit import bindings eligible for unused-import analysis."""
function write_markdown_import_bindings(io, report)
    println(io)
    println(io, "## Import Bindings")
    isempty(report.import_bindings) && return println(io, "\nNo explicit bindings found.")
    println(io, "\n| Source | Language | Target | Binding | Kind | Location |")
    println(io, "| --- | --- | --- | --- | --- | ---: |")
    for binding in report.import_bindings
        println(io, "| `$(markdown_cell(binding.path))` | $(binding.language) | ",
            "`$(markdown_cell(binding.target))` | `$(markdown_cell(binding.name))` | ",
            "$(binding.kind) | $(binding.line):$(binding.column) |")
    end
end

"""Write parser-visible identifier references."""
function write_markdown_references(io, report)
    println(io)
    println(io, "## Reference Inventory")
    isempty(report.references) && return println(io, "\nNo identifier references found.")
    println(io, "\n| Source | Language | Name | Scope | Location |")
    println(io, "| --- | --- | --- | --- | ---: |")
    for reference in report.references
        scope = something(reference.scope, "-")
        println(io, "| `$(markdown_cell(reference.path))` | $(reference.language) | ",
            "`$(markdown_cell(reference.name))` | `$(markdown_cell(scope))` | ",
            "$(reference.line):$(reference.column) |")
    end
end

"""Write explicit parser-backed call graph edges."""
function write_markdown_call_graph(io, report)
    println(io)
    println(io, "## Call Graph")
    isempty(report.call_edges) && return println(io, "\nNo explicit call edges found.")
    println(io, "\n| Source | Language | Caller | Callee | Kind | Location |")
    println(io, "| --- | --- | --- | --- | --- | ---: |")
    for edge in report.call_edges
        caller = something(edge.caller, "-")
        println(io, "| `$(markdown_cell(edge.source_path))` | $(edge.language) | ",
            "`$(markdown_cell(caller))` | `$(markdown_cell(edge.callee))` | ",
            "$(edge.kind) | $(edge.line):$(edge.column) |")
    end
end

"""Write normalized ABI signatures and deterministic bridge pair status."""
function write_markdown_interop(io, report)
    println(io)
    println(io, "## Interop Signatures")
    if isempty(report.interop_signatures)
        println(io, "\nNo supported interop signatures found.")
    else
        println(io, "\n| Source | Language | Direction | Symbol | ABI | Parameters" *
            " | Returns |")
        println(io, "| --- | --- | --- | --- | --- | --- | --- |")
        for signature in report.interop_signatures
            parameters = join(signature.parameter_types, ", ")
            returns = isempty(signature.return_types) ? "void" :
                join(signature.return_types, ", ")
            println(io, "| `$(markdown_cell(signature.path))` | ",
                "$(signature.language) | $(signature.direction) | ",
                "`$(markdown_cell(signature.symbol))` | ",
                "$(signature.calling_convention) | `$(markdown_cell(parameters))` | ",
                "`$(markdown_cell(returns))` |")
        end
    end
    println(io)
    println(io, "## Interop Bridge Pairs")
    isempty(report.interop_pairs) && return println(io, "\nNo bridge pairs found.")
    println(io, "\n| Symbol | Status | Julia | Odin | Mismatch |")
    println(io, "| --- | --- | --- | --- | --- |")
    for pair in report.interop_pairs
        println(io, "| `$(markdown_cell(pair.symbol))` | $(pair.status) | ",
            "`$(markdown_cell(something(pair.julia_path, "-")))` | ",
            "`$(markdown_cell(something(pair.odin_path, "-")))` | ",
            "$(markdown_cell(something(pair.mismatch, "-"))) |")
    end
end

"""Write the parser-backed declaration inventory."""
function write_markdown_declarations(io, report)
    println(io)
    println(io, "## Declaration Inventory")
    if isempty(report.declarations)
        println(io)
        println(io, "No supported Julia or Odin declarations were found.")
        return
    end
    println(io)
    println(io, "| Source | Language | Kind | Qualified name | Scope | Location |")
    println(io, "| --- | --- | --- | --- | --- | ---: |")
    for declaration in report.declarations
        scope = something(declaration.scope, "-")
        println(io,
            "| `$(markdown_cell(declaration.path))` | $(declaration.language) | ",
            "$(declaration.kind) | `$(markdown_cell(declaration.qualified_name))` | ",
            "`$(markdown_cell(scope))` | ",
            "$(declaration.line):$(declaration.column) |")
    end
end

"""Write the parser-backed repository dependency graph."""
function write_markdown_dependencies(io, report)
    println(io)
    println(io, "## Dependency Graph")
    if isempty(report.dependencies)
        println(io)
        println(io, "No Julia or Odin dependencies were found.")
        return
    end
    println(io)
    println(io, "| Source | Language | Kind | Target | Resolution" *
        " | Target path | Location |")
    println(io, "| --- | --- | --- | --- | --- | --- | ---: |")
    for edge in report.dependencies
        target_path = something(edge.target_path, "-")
        println(io,
            "| `$(markdown_cell(edge.source_path))` | $(edge.language) | ",
            "$(edge.kind) | `$(markdown_cell(edge.target))` | ",
            "$(edge.resolution) | `$(markdown_cell(target_path))` | ",
            "$(edge.line):$(edge.column) |")
    end
end

"""Write analytical Odin build commands, outcomes, artifacts, and captured streams."""
function write_markdown_odin_builds(io, report)
    println(io)
    println(io, "## Analytical Odin Builds")
    if isempty(report.odin_builds)
        println(io)
        println(io, "No analytical Odin builds were configured.")
        return
    end
    for build in report.odin_builds
        println(io)
        println(io, "### `$(markdown_heading(build.id))`")
        println(io)
        println(io, "| Field | Value |")
        println(io, "| --- | --- |")
        println(io, "| Status | $(uppercase(build.status)) |")
        println(io, "| Exit code | `$(build.exit_code)` |")
        println(io, "| Input | `$(markdown_cell(build.input))` |")
        println(io, "| Output | `$(markdown_cell(build.output))` |")
        command = join(
            ("`$(markdown_cell(argument))`" for argument in build.command),
            " ")
        println(io, "| Command | $command |")
        write_markdown_build_stream(io, "Standard Output", build.stdout)
        write_markdown_build_stream(io, "Standard Error", build.stderr)
    end
end

"""Write one captured build stream without omitting empty output."""
function write_markdown_build_stream(io, heading, output)
    println(io)
    println(io, "#### $heading")
    println(io)
    if isempty(output)
        println(io, "No output.")
        return
    end
    println(io, "````text")
    println(io, chomp(output))
    println(io, "````")
end

"""Write complete repository statistics and economic model assumptions."""
function write_markdown_statistics(io, statistics)
    println(io)
    println(io, "## Repository Statistics")
    println(io)
    println(io, "| Language | Files | Functions | Structs | Lines | Blank | Comment | " *
        "Code | Complexity | Complexity/Code |")
    println(io,
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    write_markdown_code_statistics_row(io, "Odin", statistics.code_by_language["odin"])
    write_markdown_code_statistics_row(io, "Julia", statistics.code_by_language["julia"])
    write_markdown_code_statistics_row(io, "Total", statistics.code)
    println(io)
    println(io, "Line totals cover analyzed Julia and Odin files; Markdown is excluded.")
    println(io, "Functions includes parser-backed Julia functions and Odin procedures.")
    println(io, "Structs includes parser-backed named struct declarations.")
    println(io, "Complexity is the sum of parser-derived cyclomatic complexity for Julia")
    println(io, "functions and Odin procedures.")
    write_markdown_cocomo_statistics(io, statistics.cocomo)
    write_markdown_locomo_statistics(io, statistics.locomo)
end

"""Write COCOMO estimates and assumptions."""
function write_markdown_cocomo_statistics(io, cocomo)
    println(io)
    println(io, "### COCOMO Development Estimate")
    println(io)
    println(io, "| Measure | Estimate |")
    println(io, "| --- | ---: |")
    println(io, "| Model | $(cocomo.model) |")
    println(io, "| Effort | ",
        "$(round(cocomo.effort_person_months; digits=3)) person-months |")
    println(io, "| Schedule | $(round(cocomo.schedule_months; digits=3)) months |")
    println(io, "| Average team | $(round(cocomo.people; digits=3)) people |")
    println(io, "| Estimated cost | \$$(round(cocomo.estimated_cost; digits=2)) |")
    println(io, "| Average annual wage | \$$(cocomo.average_annual_wage) |")
    println(io, "| Overhead multiplier | $(cocomo.overhead_multiplier) |")
    println(io)
    println(io, "This Basic COCOMO organic estimate models human creation from scratch.")
    println(io, "It uses nominal effort adjustment and SCC-compatible coefficients.")
end

"""Write LOCOMO regeneration estimates and assumptions."""
function write_markdown_locomo_statistics(io, locomo)
    println(io)
    println(io, "### LOCOMO Regeneration Estimate")
    println(io)
    println(io, "| Measure | Estimate |")
    println(io, "| --- | ---: |")
    println(io, "| Preset | $(locomo.preset) |")
    println(io, "| Input tokens | $(round(Int, locomo.input_tokens)) |")
    println(io, "| Output tokens | $(round(Int, locomo.output_tokens)) |")
    println(io, "| Estimated cycles | $(round(locomo.estimated_cycles; digits=3)) |")
    println(io, "| Estimated generation cost | ",
        "\$$(round(locomo.estimated_cost; digits=2)) |")
    println(io, "| Serial generation time | ",
        "$(round(locomo.generation_seconds / 3600; digits=3)) hours |")
    println(io, "| Human review time | $(round(locomo.review_hours; digits=3)) hours |")
    println(io)
    println(io, "LOCOMO is an experimental regeneration heuristic, not a project plan.")
    println(io,
        "The medium preset assumes 10 output tokens and 20 base input tokens per line.")
    println(io,
        "Complexity-scaled retries use \$3/\$15 per million input/output tokens and")
    println(io,
        "50 output tokens per second. Review uses 0.01 minutes per line.")
end

"""Write one language row in the Markdown code-statistics table."""
function write_markdown_code_statistics_row(io, language, code)
    println(io,
        "| $language | $(code.files) | $(code.functions) | $(code.structs) | ",
        "$(code.lines) | $(code.blank_lines) | $(code.comment_lines) | ",
        "$(code.code_lines) | $(code.complexity) | ",
        "$(round(code.complexity_per_code_line; digits=4)) |")
end

"""Write analyzer identity and scan metadata."""
function write_markdown_metadata(io, report)
    println(io)
    println(io, "## Run Metadata")
    println(io)
    println(io, "| Field | Value |")
    println(io, "| --- | --- |")
    println(io, "| Analysis schema | `$(report.schema_version)` |")
    println(io, "| Analyzer version | `$(report.tool_version)` |")
    println(io, "| Root | `$(markdown_cell(report.root))` |")
    println(io, "| Profile | `$(report.profile)` |")
    println(io, "| Exit code | `$(report.exit_code)` |")
end

"""Write repository-wide totals and positive coverage evidence."""
function write_markdown_summary(io, report)
    counts = severity_counts(report.diagnostics)
    function_statuses = Dict(status => count(
        item -> function_status(
            item,
            report.thresholds,
            report.parameter_counts,
            report.function_metrics) == status,
        report.functions) for status in (
            "within thresholds", "review", "exceeds maximum"))
    clean_files = count(file -> !any(
        item -> item.path == file.path && item.response in (Warn, Fail),
        report.diagnostics), report.files)
    println(io)
    println(io, "## Executive Summary")
    println(io)
    println(io, "| Measure | Count |")
    println(io, "| --- | ---: |")
    println(io, "| Files analyzed | $(report.files_analyzed) |")
    source_lines = sum((file.source_lines for file in report.files); init=0)
    println(io, "| Source lines | $source_lines |")
    println(io, "| Functions and procedures | $(length(report.functions)) |")
    println(io, "| Functions within thresholds | ",
        "$(function_statuses["within thresholds"]) |")
    println(io, "| Functions requiring review | $(function_statuses["review"]) |")
    println(io, "| Functions exceeding maxima | ",
        "$(function_statuses["exceeds maximum"]) |")
    println(io, "| Clean files | $clean_files |")
    println(io, "| Report findings | $(counts[Report]) |")
    println(io, "| Warnings | $(counts[Warn]) |")
    println(io, "| Failures | $(counts[Fail]) |")
    println(io, "| Ignored findings | $(length(report.ignored_diagnostics)) |")
    println(io, "| Reviewed allocations | ", count(
        item -> item.reviewed_policy_id !== nothing, report.diagnostics), " |")
end

"""Count visible diagnostics by configured response."""
function severity_counts(diagnostics)
    return Dict(response => count(item -> item.response == response, diagnostics)
        for response in (Report, Warn, Fail))
end

"""Write metric thresholds used to classify function measurements."""
function write_markdown_thresholds(
    io,
    thresholds,
    parameter_counts,
    function_metrics)
    println(io)
    println(io, "## Function Thresholds")
    println(io)
    println(io, "| Metric | Report | Warn | Fail |")
    println(io, "| --- | ---: | ---: | ---: |")
    write_response_threshold_row(
        io, "Julia executable lines", function_metrics.julia_lines)
    write_response_threshold_row(
        io, "Odin executable lines", function_metrics.odin_lines)
    println(io, "| Julia positional parameters | - | - | ",
        "$(parameter_counts.julia_maximum) |")
    println(io, "| Odin parameters | - | $(parameter_counts.odin_warning) | ",
        "$(parameter_counts.odin_maximum) |")
    write_response_threshold_row(
        io, "Julia cyclomatic complexity", function_metrics.julia_cyclomatic)
    write_response_threshold_row(
        io, "Odin cyclomatic complexity", function_metrics.odin_cyclomatic)
    println(io, "| Julia cognitive complexity | - | - | ",
        "$(thresholds.cognitive_maximum) |")
end

"""Write one report/warn/fail threshold row."""
function write_response_threshold_row(io, name, thresholds)
    println(io, "| $name | $(thresholds.report) | $(thresholds.warn) | ",
        "$(thresholds.fail) |")
end

"""Write per-file line, function, and finding measurements."""
function write_markdown_files(io, report)
    println(io)
    println(io, "## File Inventory")
    println(io)
    println(io, "| File | Lang | Parse | Lines | Code | Comment | Blank | Functions | ",
        "Report | Warn | Fail |")
    println(io, "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ",
        "---: | ---: | ---: |")
    for file in report.files
        findings = filter(item -> item.path == file.path, report.diagnostics)
        counts = severity_counts(findings)
        parse_status = file.parsed ? "complete" : "failed"
        println(io, "| `$(markdown_cell(file.path))` | $(file.language) | ",
            "$parse_status | $(file.physical_lines) | $(file.code_lines) | ",
            "$(file.comment_lines) | $(file.blank_lines) | ",
            "$(file.function_count) | $(counts[Report]) | $(counts[Warn]) | ",
            "$(counts[Fail]) |")
    end
end

"""Write every measured function and its threshold classification."""
function write_markdown_functions(io, report)
    println(io)
    println(io, "## Function And Procedure Inventory")
    println(io)
    println(io,
        "| File | Function | Lines | NLOC | Params | Cyclomatic | Cognitive | ",
        "Docs | Status |")
    println(io, "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |")
    for item in sort(report.functions; by=function_sort_key)
        span = "$(item.start_line)-$(item.end_line)"
        documented = item.documented ? "yes" : "no"
        status = function_status(
            item,
            report.thresholds,
            report.parameter_counts,
            report.function_metrics)
        cognitive = something(item.cognitive_complexity, "-")
        println(io, "| `$(markdown_cell(item.path))` | `$(markdown_cell(item.name))` | ",
            "$span | $(item.executable_lines) | $(item.parameter_count) | ",
            "$(item.cyclomatic_complexity) | $cognitive | $documented | $status |")
    end
end

"""Return a stable function inventory ordering key."""
function function_sort_key(item)
    return (path=item.path, start_line=item.start_line, name=item.name)
end

"""Classify function measurements against configured thresholds."""
function function_status(item, thresholds, parameter_counts, function_metrics)
    parameter_maximum = item.language == "julia" ?
        parameter_counts.julia_maximum : parameter_counts.odin_maximum
    metric_settings = item.language == "julia" ?
        (
            lines=function_metrics.julia_lines,
            cyclomatic=function_metrics.julia_cyclomatic) :
        (
            lines=function_metrics.odin_lines,
            cyclomatic=function_metrics.odin_cyclomatic)
    if item.executable_lines > metric_settings.lines.fail ||
            item.parameter_count > parameter_maximum ||
            item.cyclomatic_complexity > metric_settings.cyclomatic.fail ||
            something(item.cognitive_complexity, 0) > thresholds.cognitive_maximum
        return "exceeds maximum"
    elseif item.executable_lines > metric_settings.lines.report ||
            item.language == "odin" &&
                item.parameter_count > parameter_counts.odin_warning ||
            item.cyclomatic_complexity > metric_settings.cyclomatic.report
        return "review"
    end
    return "within thresholds"
end

"""Write every visible diagnostic grouped by source file."""
function write_markdown_findings(io, report)
    println(io)
    println(io, "## Complete Findings By File")
    grouped = group_diagnostics(report.diagnostics)
    isempty(grouped) && (println(io); println(io, "No visible findings."); return)
    for path in sort!(collect(keys(grouped)))
        println(io)
        println(io, "### `$(markdown_heading(path))`")
        println(io)
        println(io, "| Response | Location | Rule | Measurement | Message |")
        println(io, "| --- | --- | --- | --- | --- |")
        for item in grouped[path]
            location = "$(item.line):$(item.column)"
            measurement = diagnostic_measurement(item)
            println(io, "| $(uppercase(response_name(item.response))) | $location | ",
                "`$(item.rule_id)` | $measurement | $(markdown_cell(item.message)) |")
        end
    end
end

"""Group diagnostics by repository-relative path."""
function group_diagnostics(diagnostics)
    grouped = Dict{String, Vector{Diagnostic}}()
    for diagnostic in diagnostics
        push!(get!(grouped, diagnostic.path, Diagnostic[]), diagnostic)
    end
    return grouped
end

"""Format optional measured and allowed diagnostic values."""
function diagnostic_measurement(item)
    item.measured === nothing && return "-"
    item.allowed === nothing && return string(item.measured)
    return "$(item.measured) / $(item.allowed) allowed"
end

"""Write the complete allocation ledger, including reviewed policy context."""
function write_markdown_allocations(io, report)
    allocations = filter(is_allocation_diagnostic,
        vcat(report.diagnostics, report.ignored_diagnostics))
    println(io)
    println(io, "## Allocation Ledger")
    println(io)
    isempty(allocations) && (println(io, "No allocation findings."); return)
    println(io, "| Response | File:line | Procedure | Operation | Target | Allocator | ",
        "Certainty | Policy |")
    println(io, "| --- | --- | --- | --- | --- | --- | --- | --- |")
    for item in sort(allocations; by=diagnostic_sort_key)
        policy = item.reviewed_policy_id === nothing ? "-" :
            "`$(markdown_cell(item.reviewed_policy_id))`: " *
            markdown_cell(something(item.reviewed_policy_reason, ""))
        println(io, "| $(uppercase(response_name(item.response))) | ",
            "`$(markdown_cell(item.path)):$(item.line)` | ",
            "$(markdown_optional(item.procedure)) | ",
            "$(markdown_optional(item.operation)) | ",
            "$(markdown_optional(item.allocation_target)) | ",
            "$(markdown_optional(item.allocator_source)) | ",
            "$(markdown_optional(item.certainty)) | $policy |")
    end
end

"""Write complete ignored findings rather than aggregate counts alone."""
function write_markdown_ignored(io, report)
    println(io)
    println(io, "## Ignored Findings")
    println(io)
    isempty(report.ignored_diagnostics) && (println(io, "No ignored findings."); return)
    println(io, "| File:line | Rule | Message |")
    println(io, "| --- | --- | --- |")
    for item in report.ignored_diagnostics
        println(io, "| `$(markdown_cell(item.path)):$(item.line)` | ",
            "`$(item.rule_id)` | $(markdown_cell(item.message)) |")
    end
end

"""Write all configured rules, including positive zero-finding results."""
function write_markdown_rules(io, report)
    println(io)
    println(io, "## Rule Coverage")
    println(io)
    println(io, "| Rule | Response | Status | Files checked | Findings |")
    println(io, "| --- | --- | --- | ---: | ---: |")
    for rule in report.rules
        println(io, "| `$(rule.rule_id)` | $(uppercase(response_name(rule.response))) | ",
            "$(rule.status) | $(rule.files_checked) | $(rule.findings) |")
    end
end

"""Write extension phase outcomes and their JSON-serializable artifacts."""
function write_markdown_extensions(io, report)
    println(io)
    println(io, "## Extension Results")
    println(io)
    if isempty(report.extensions)
        println(io, "No extensions were configured.")
        return
    end
    println(io, "| Extension | Phase | Status | Message | Artifacts |")
    println(io, "| --- | --- | --- | --- | --- |")
    for result in report.extensions
        artifacts = isempty(result.artifacts) ? "-" :
            "`$(markdown_cell(JSON3.write(result.artifacts)))`"
        println(io, "| `$(markdown_cell(result.extension_id))` | ",
            "`$(result.phase)` | $(uppercase(result.status)) | ",
            "$(markdown_cell(something(result.message, "-"))) | $artifacts |")
    end
end

"""Write all analysis engine completion states and messages."""
function write_markdown_engines(io, report)
    println(io)
    println(io, "## Engine Status")
    println(io)
    println(io, "| Engine | Status | Message |")
    println(io, "| --- | --- | --- |")
    for engine in report.engines
        println(io, "| $(engine.name) | $(engine.status) | ",
            "$(markdown_cell(something(engine.message, "-"))) |")
    end
end

"""Format an optional report value as inline code."""
function markdown_optional(value)
    value === nothing && return "-"
    return "`$(markdown_cell(value))`"
end

"""Escape text for a Markdown table cell."""
function markdown_cell(value)
    return replace(string(value), '|' => "\\|", '\n' => " ", '\r' => "")
end

"""Escape text used inside an inline-code Markdown heading."""
function markdown_heading(value)
    return replace(string(value), '`' => "'")
end