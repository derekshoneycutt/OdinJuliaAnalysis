"""Represent process/protocol/configuration failures without granting partial coverage."""
function sqlite_incomplete_case(id, message, stderr="")
    return SQLiteCaseEvidence(id, "incomplete", nothing, false, false, false, false,
        SQLiteStepEvidence[], nothing, message, stderr)
end

"""Run independent cases even when a sibling fails or its runner is unavailable."""
function run_sqlite_case(root, case, runner, sources)
    request = try
        sqlite_case_request(case, sources)
    catch error
        error isa ArgumentError || rethrow()
        return sqlite_incomplete_case(case.id, sprint(showerror, error))
    end
    command = sqlite_runner_command(root, runner)
    timeout = something(case.timeout_seconds, runner.timeout_seconds)
    process = sqlite_process(command, request, timeout)
    process.status == "complete" || return sqlite_incomplete_case(
        case.id, process.message, process.stderr)
    return sqlite_decode_result(process, request)
end

"""A zero process exit alone is never SQLite evidence."""
function sqlite_decode_result(process, request)
    try
        isvalid(process.stdout) || throw(ArgumentError("SQLite stdout is not valid UTF-8"))
        record = JSON.parse(process.stdout)
        result = sqlite_case_result(record, request, process.stderr)
        return sqlite_classify_result(result)
    catch error
        error isa ArgumentError || rethrow()
        return sqlite_incomplete_case(request.case_id,
            "SQLite result protocol failure: $(sprint(showerror, error))", process.stderr)
    end
end

"""Unavailable provider capabilities are incomplete analysis, not a SQL rejection."""
function sqlite_classify_result(result)
    failure = result.failure
    (failure === nothing || failure.phase != "capability") && return result
    return SQLiteCaseEvidence(result.id, "incomplete", result.provider, result.completed,
        result.transaction_complete, result.finalized, result.closed, result.steps,
        failure, "SQLite provider or required capability is unavailable.", result.stderr)
end

"""Record declaration independently of validated runtime coverage."""
function sqlite_declared_sources(settings)
    declared = Dict{String, Vector{String}}()
    for case in settings.cases, step in case.steps
        step isa SQLiteFileStep || continue
        path = replace(normpath(step.path), '\\' => '/')
        modes = get!(declared, path, String[])
        string(step.mode) in modes || push!(modes, string(step.mode))
    end
    return declared
end

"""Reconcile successful native whole-source results against each discovered snapshot."""
function sqlite_source_coverage(sources, settings, cases)
    declared = sqlite_declared_sources(settings)
    coverage = SQLiteSourceCoverage[]
    for path in sort!(collect(keys(sources)))
        digest = sqlite_source_digest(sources[path].source)
        steps = [step for case in cases for step in case.steps
            if step.source_id == path && step.digest == digest]
        validated_steps = [step for case in cases if sqlite_case_cleaned_up(case)
            for step in case.steps if step.source_id == path && step.digest == digest]
        modes = get(declared, path, String[])
        attempted = any(step -> step.attempted, steps)
        prepared = any(step -> step.prepared, steps)
        executed = any(step -> step.executed, steps)
        validated = !isempty(modes) && all(mode -> any(step ->
            step.mode == mode && step.status == "passed", validated_steps), modes)
        push!(coverage, SQLiteSourceCoverage(
            path, digest, !isempty(modes), attempted,
            prepared, executed, validated, modes))
    end
    return coverage
end

"""Require complete transaction state and cleanup before granting validated coverage."""
function sqlite_case_cleaned_up(case)
    return case.completed && case.transaction_complete && case.finalized && case.closed
end

"""Keep native validation independent of structural capability and optional coverage policy."""
function analyze_sqlite_validation(root, sources, settings)
    runner = settings.runner
    runner === nothing && return empty_sqlite_validation()
    cases = [run_sqlite_case(root, case, runner, sources) for case in settings.cases]
    coverage = sqlite_source_coverage(sources, settings, cases)
    command = sqlite_runner_command(root, runner)
    unavailable = Sys.which(command.exec[1]) === nothing || !isdir(command.dir)
    message = unavailable ? "Configured SQLite runner or working directory is unavailable." :
        nothing
    status = unavailable || any(case -> case.status == "incomplete", cases) ? "incomplete" :
        any(case -> case.status == "failed", cases) ? "failed" :
        settings.require_coverage && any(item -> !item.validated, coverage) ?
            "failed" : "complete"
    return SQLiteValidationEvidence(
        status, settings.require_coverage, cases, coverage, message)
end

"""Summarize failures without manufacturing runtime evidence from manifest membership."""
function sqlite_validation_message(evidence)
    messages = String[]
    evidence.message === nothing || push!(messages, evidence.message)
    for case in evidence.cases
        case.message === nothing || push!(messages, "$(case.id): $(case.message)")
        case.failure === nothing || push!(messages,
            "$(case.id): $(case.failure.phase): $(case.failure.message)")
        for step in case.steps
            step.failure === nothing && continue
            push!(messages, "$(case.id)/$(step.id) ($(step.source_id)): " *
                "$(step.failure.phase): $(step.failure.message)")
        end
    end
    if evidence.require_coverage
        for item in evidence.coverage
            item.validated || push!(messages, "$(item.path): no successful declared-mode coverage")
        end
    end
    return isempty(messages) ? nothing : join(messages, "\n")
end
