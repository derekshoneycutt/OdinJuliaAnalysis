struct LcovData
    lines::Dict{String, Dict{Int, Int}}
end

struct TestCoverageAnalysis
    evidence::Vector{TestCoverageEvidence}
    statistics::Union{Nothing, TestCoverageStatistics}
end

"""Correlate static test reachability with configured LCOV line evidence."""
function analyze_test_coverage(
    root,
    functions,
    call_edges,
    call_roots,
    configuration)
    settings = configuration.coverage
    settings.enabled || return TestCoverageAnalysis(TestCoverageEvidence[], nothing)
    lcov = load_lcov_data(root, settings.tracefiles)
    evidence = TestCoverageEvidence[]
    for language in ("julia", "odin")
        language_functions = filter(item -> item.language == language, functions)
        test_roots = filter(
            item -> item.language == language && item.category == "test",
            call_roots)
        reachable = isempty(test_roots) ? nothing : test_reachable_names(
            language, language_functions, call_edges, test_roots)
        for item in language_functions
            push!(evidence, coverage_evidence(
                item, reachable, lcov, call_roots))
        end
    end
    sort!(evidence; by=coverage_evidence_key)
    statistics = coverage_statistics(
        evidence, call_edges, settings.high_risk_limit)
    return TestCoverageAnalysis(evidence, statistics)
end

"""Compute the fixed-point callable-name closure from test roots."""
function test_reachable_names(language, functions, call_edges, roots)
    names = Set(item.name for item in functions)
    reachable = Set(root.declaration for root in roots)
    changed = true
    while changed
        changed = false
        for edge in call_edges
            edge.language == language || continue
            terminal_call_name(edge.caller) in reachable || continue
            callee = terminal_call_name(edge.callee)
            callee in names || continue
            callee in reachable && continue
            push!(reachable, callee)
            changed = true
        end
    end
    return reachable
end

"""Build one reproducible declaration-level coverage evidence record."""
function coverage_evidence(item, reachable, lcov, roots)
    line_counts = get(lcov.lines, item.path, Dict{Int, Int}())
    instrumented = [line for line in keys(line_counts)
        if item.start_line <= line <= item.end_line]
    covered_lines = count(line -> line_counts[line] > 0, instrumented)
    runtime_covered = isempty(instrumented) ? nothing : covered_lines > 0
    static_reachable = reachable === nothing ? nothing : item.name in reachable
    evidence_class = coverage_evidence_class(static_reachable, runtime_covered)
    categories = coverage_boundary_categories(item, roots)
    risk_score = coverage_risk_score(item, categories)
    return TestCoverageEvidence(
        item.path,
        item.language,
        item.name,
        item.start_line,
        item.end_line,
        item.executable_lines,
        item.cyclomatic_complexity,
        static_reachable,
        length(instrumented),
        covered_lines,
        runtime_covered,
        evidence_class,
        categories,
        risk_score,
        coverage_evidence_explanation(evidence_class))
end

"""Classify agreement and disagreement between static and runtime evidence."""
function coverage_evidence_class(static_reachable, runtime_covered)
    static_reachable === true && runtime_covered === true && return "corroborated"
    static_reachable === true && runtime_covered === false && return "static-only"
    static_reachable === false && runtime_covered === true && return "runtime-only"
    static_reachable === false && runtime_covered === false && return "uncovered"
    static_reachable !== nothing && return "runtime-unavailable"
    runtime_covered !== nothing && return "static-unavailable"
    return "unavailable"
end

"""Return callback and bridge categories attached to one declaration."""
function coverage_boundary_categories(item, roots)
    categories = [root.category for root in roots
        if root.language == item.language && root.path == item.path &&
            terminal_call_name(root.declaration) == item.name &&
            root.category in ("callback", "bridge")]
    sort!(unique!(categories))
    return categories
end

"""Calculate the fixed transparent declaration risk score."""
function coverage_risk_score(item, categories)
    boundary_weight = any(category -> category in ("callback", "bridge"), categories) ?
        5 : 0
    return item.cyclomatic_complexity + cld(item.executable_lines, 10) +
        boundary_weight
end

"""Explain one evidence class without overstating test quality."""
function coverage_evidence_explanation(evidence_class)
    explanations = Dict(
        "corroborated" => "Static test reachability and runtime line coverage agree.",
        "static-only" => "Static test reachability was not corroborated at runtime.",
        "runtime-only" => "Runtime coverage exists outside the resolved test-call closure.",
        "uncovered" => "Neither static test reachability nor runtime execution was observed.",
        "runtime-unavailable" => "No LCOV line intersects this declaration.",
        "static-unavailable" => "No static test root exists for this language.",
        "unavailable" => "Neither static test roots nor runtime lines are available.")
    return explanations[evidence_class] *
        " Reachability and line execution do not prove assertion quality."
end

"""Aggregate declaration evidence overall and by language."""
function coverage_statistics(evidence, call_edges, high_risk_limit)
    languages = ("julia", "odin")
    by_language = Dict(language => coverage_counts(filter(
        item -> item.language == language, evidence)) for language in languages)
    dynamic_edges = count(edge -> edge.kind == "dynamic", call_edges)
    return TestCoverageStatistics(
        coverage_counts(evidence), by_language, dynamic_edges, high_risk_limit)
end

"""Count each evidence class and rankable gap in one scope."""
function coverage_counts(evidence)
    gaps = count(item -> coverage_is_gap(item), evidence)
    return TestCoverageCounts(
        length(evidence),
        count(item -> item.static_test_reachable === true, evidence),
        count(item -> item.runtime_covered !== nothing, evidence),
        count(item -> item.runtime_covered === true, evidence),
        count_coverage_class(evidence, "corroborated"),
        count_coverage_class(evidence, "static-only"),
        count_coverage_class(evidence, "runtime-only"),
        count_coverage_class(evidence, "uncovered"),
        count_coverage_class(evidence, "runtime-unavailable"),
        count_coverage_class(evidence, "static-unavailable"),
        count_coverage_class(evidence, "unavailable"),
        gaps)
end

    """Count declarations assigned to one coverage evidence class."""
    count_coverage_class(evidence, name) = count(
        item -> item.evidence_class == name, evidence)

"""Return whether available evidence identifies a declaration-level gap."""
coverage_is_gap(item) = item.static_test_reachable === false ||
    item.runtime_covered === false

"""Return deterministic canonical coverage evidence ordering."""
coverage_evidence_key(item) = join((
    item.language, item.path, item.declaration, string(item.start_line)), '\0')

"""Return deterministic risk-first presentation ordering."""
coverage_risk_key(item) = join((
    lpad(string(typemax(Int) - item.risk_score), 20, '0'),
    item.language,
    item.path,
    item.declaration,
    string(item.start_line)), '\0')

"""Parse and merge configured LCOV tracefiles for one analysis root."""
function load_lcov_data(root, tracefiles)
    merged = Dict{String, Dict{Int, Int}}()
    for tracefile in tracefiles
        path = joinpath(root, tracefile)
        isfile(path) || throw(ArgumentError(
            "coverage tracefile does not exist: $tracefile"))
        merge_lcov!(merged, parse_lcov(read(path, String), root, tracefile))
    end
    return LcovData(merged)
end

"""Parse LCOV source and line records into repository-relative line counts."""
function parse_lcov(source, root, tracefile="<memory>")
    records = Dict{String, Dict{Int, Int}}()
    current_path = nothing
    in_record = false
    for (line_number, raw_line) in enumerate(eachline(IOBuffer(source)))
        line = strip(raw_line)
        isempty(line) && continue
        if startswith(line, "SF:")
            !in_record || throw(ArgumentError(
                "$tracefile:$line_number starts a source before end_of_record"))
            current_path = lcov_repository_path(line[4:end], root)
            in_record = true
        elseif startswith(line, "DA:")
            !in_record && throw(ArgumentError(
                "$tracefile:$line_number has DA before SF"))
            parsed = parse_lcov_da(line[4:end], tracefile, line_number)
            if current_path isa String
                counts = get!(records, current_path, Dict{Int, Int}())
                counts[parsed.line] = get(counts, parsed.line, 0) + parsed.count
            end
        elseif line == "end_of_record"
            !in_record && throw(ArgumentError(
                "$tracefile:$line_number has end_of_record before SF"))
            current_path = nothing
            in_record = false
        end
    end
    !in_record || throw(ArgumentError(
        "$tracefile ends before end_of_record"))
    return records
end

"""Normalize one LCOV source path, excluding files outside the repository."""
function lcov_repository_path(path, root)
    absolute = isabspath(path) ? normpath(path) : normpath(joinpath(root, path))
    relative = relpath(absolute, root)
    parts = splitpath(relative)
    return isabspath(relative) || (!isempty(parts) && first(parts) == "..") ?
        nothing : replace(relative, '\\' => '/')
end

"""Parse one LCOV DA payload with an optional checksum field."""
function parse_lcov_da(payload, tracefile, line_number)
    fields = split(payload, ',')
    length(fields) in (2, 3) || throw(ArgumentError(
        "$tracefile:$line_number has malformed DA record"))
    line = tryparse(Int, fields[1])
    count = tryparse(Int, fields[2])
    line !== nothing && line > 0 || throw(ArgumentError(
        "$tracefile:$line_number has invalid DA line"))
    count !== nothing && count >= 0 || throw(ArgumentError(
        "$tracefile:$line_number has invalid DA count"))
    return (line=line::Int, count=count::Int)
end

"""Merge line counts from one parsed LCOV trace into accumulated evidence."""
function merge_lcov!(merged, incoming)
    for (path, line_counts) in incoming
        counts = get!(merged, path, Dict{Int, Int}())
        for (line, count) in line_counts
            counts[line] = get(counts, line, 0) + count
        end
    end
    return merged
end