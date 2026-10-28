"""Reject untyped/missing protocol fields before granting any source coverage."""
function sqlite_field(record, name, type)
    record isa AbstractDict || throw(ArgumentError("SQLite result is not an object"))
    haskey(record, name) || throw(ArgumentError("SQLite result lacks $name"))
    value = record[name]
    value isa type || throw(ArgumentError("SQLite result has invalid $name"))
    type === Int && value isa Bool && throw(ArgumentError("SQLite $name is not an integer"))
    return value
end

"""Require a supplied protocol identity to match its exact request counterpart."""
function sqlite_match(record, name, expected)
    value = sqlite_field(record, name, typeof(expected))
    value == expected || throw(ArgumentError("SQLite result $name mismatch"))
    return value
end

"""Read a nullable native failure with copied diagnostic text and byte coordinates."""
function sqlite_result_failure(record, source_bytes::Union{Nothing, Int}=nothing)
    haskey(record, "failure") || throw(ArgumentError("SQLite result lacks failure"))
    item = record["failure"]
    item === nothing && return nothing
    phase = sqlite_field(item, "phase", String)
    phase in ("prepare", "bind", "step", "capability", "transaction", "finalize", "close") ||
        throw(ArgumentError("SQLite result has unknown failure phase"))
    primary = sqlite_field(item, "primary_code", Int)
    extended = sqlite_field(item, "extended_code", Int)
    primary >= 0 && extended >= 0 && (extended & 0xff) == primary ||
        throw(ArgumentError("SQLite failure codes are contradictory"))
    offset = sqlite_field(item, "offset", Union{Nothing, Int})
    offset === nothing || (!(offset isa Bool) && offset > 0 &&
        (source_bytes === nothing || offset <= source_bytes + 1)) ||
        throw(ArgumentError("SQLite failure offset is outside its source"))
    message = sqlite_field(item, "message", String)
    isempty(message) && throw(ArgumentError("SQLite failure lacks diagnostic text"))
    return SQLiteValidationFailure(phase, primary, extended, offset, message)
end

"""Validate every step against the source snapshot, mode and complete native tail."""
function sqlite_result_step(record, request)
    sqlite_match(record, "id", request.id)
    sqlite_match(record, "source_id", request.source_id)
    sqlite_match(record, "digest", request.digest)
    sqlite_match(record, "mode", request.mode)
    status = sqlite_field(record, "status", String)
    status in ("passed", "failed", "skipped") ||
        throw(ArgumentError("SQLite result has unknown step status"))
    attempted = sqlite_field(record, "attempted", Bool)
    prepared = sqlite_field(record, "prepared", Bool)
    executed = sqlite_field(record, "executed", Bool)
    bytes = sqlite_field(record, "processed_bytes", Int)
    count = sqlite_field(record, "statement_count", Int)
    total = ncodeunits(request.source)
    0 <= bytes <= total && 0 <= count <= total ||
        throw(ArgumentError("SQLite statement count or processed range is invalid"))
    failure = sqlite_result_failure(record, total)
    result = SQLiteStepEvidence(request.id, request.source_id, request.digest,
        request.mode, status, attempted, prepared, executed, bytes, count, failure)
    sqlite_step_consistency(result, total)
    return result
end

"""Do not confuse a partial attempt, prepared statement, or first row with full execution."""
function sqlite_step_consistency(item, total)
    if item.status == "passed"
        sqlite_passed_step(item, total) ||
            throw(ArgumentError("SQLite successful step is incomplete or contradictory"))
    elseif item.status == "skipped"
        sqlite_skipped_step(item) ||
            throw(ArgumentError("SQLite skipped step claims validation evidence"))
    else
        item.attempted && !item.executed && item.failure !== nothing ||
            throw(ArgumentError("SQLite failed step lacks a coherent failure"))
        item.prepared && throw(ArgumentError("SQLite failed step claims full preparation"))
    end
end

"""Require complete source preparation and exactly the requested execution mode."""
function sqlite_passed_step(item, total)
    return item.attempted && item.prepared && item.executed == (item.mode == "execute") &&
        item.processed_bytes == total && item.failure === nothing
end

"""A skipped dependency has no attempted work, measurement or native diagnostic."""
function sqlite_skipped_step(item)
    return !item.attempted && !item.prepared && !item.executed &&
        item.processed_bytes == 0 && item.statement_count == 0 && item.failure === nothing
end

"""Require ordered failure-local execution; a failed setup never validates dependents."""
function sqlite_result_steps(records, requests, case_failure)
    length(records) == length(requests) || throw(ArgumentError(
        "SQLite result step count mismatch"))
    steps = [sqlite_result_step(record, request)
        for (record, request) in zip(records, requests)]
    stopped = false
    for step in steps
        stopped && step.status != "skipped" && throw(ArgumentError(
            "SQLite result ran steps after failure"))
        step.status == "skipped" && !stopped && case_failure === nothing &&
            throw(ArgumentError("SQLite result skipped steps without failure"))
        stopped |= step.status != "passed"
    end
    return steps
end

"""Validate provider identity, capability availability, cleanup and completion as one result."""
function sqlite_case_result(record, request, stderr)
    sqlite_match(record, "protocol_version", SQLITE_PROTOCOL_VERSION)
    sqlite_match(record, "case_id", request.case_id)
    sqlite_field(record, "completed", Bool) || throw(ArgumentError(
        "SQLite case result is not complete"))
    status = sqlite_field(record, "status", String)
    status in ("passed", "failed") || throw(ArgumentError("Unknown SQLite case status"))
    provider = sqlite_result_provider(record)
    failure = sqlite_result_failure(record)
    steps = sqlite_result_steps(sqlite_field(record, "steps", AbstractVector),
        request.steps, failure)
    transaction = sqlite_field(record, "transaction_complete", Bool)
    cleanup = sqlite_field(record, "cleanup", AbstractDict)
    finalized = sqlite_field(cleanup, "finalized", Bool)
    closed = sqlite_field(cleanup, "closed", Bool)
    result = SQLiteCaseEvidence(request.case_id, status, provider, true, transaction,
        finalized, closed, steps, failure, nothing, stderr)
    sqlite_case_consistency(result)
    sqlite_required_capabilities(result, request.requirements)
    return result
end

"""Reject success-shaped results that contradict transaction or cleanup evidence."""
function sqlite_case_consistency(result)
    if !result.finalized || !result.closed
        result.failure !== nothing && result.failure.phase in ("finalize", "close") ||
            throw(ArgumentError("SQLite cleanup failure lacks copied diagnostics"))
    end
    passed = all(step -> step.status == "passed", result.steps) &&
        result.failure === nothing && result.transaction_complete &&
        result.finalized && result.closed
    (result.status == "passed") == passed || throw(ArgumentError(
        "SQLite case status contradicts steps, transaction or cleanup"))
    !passed && result.failure === nothing &&
        !any(step -> step.failure !== nothing, result.steps) &&
        throw(ArgumentError("SQLite case failed without diagnostic evidence"))
end

"""Require declared capability availability or an explicit pre-execution capability failure."""
function sqlite_required_capabilities(result, requirements)
    provider = result.provider
    provider === nothing && throw(ArgumentError("SQLite result lacks provider evidence"))
    missing = setdiff(requirements, provider.capabilities)
    isempty(missing) || (result.status == "failed" && result.failure !== nothing &&
        result.failure.phase == "capability" && all(step -> !step.attempted, result.steps)) ||
        throw(ArgumentError("SQLite runner did not provide required capabilities"))
end

"""Retain the actual provider/version, never assume a consumer-specific implementation."""
function sqlite_result_provider(record)
    provider = sqlite_field(record, "provider", AbstractDict)
    identity = sqlite_field(provider, "identity", String)
    version = sqlite_field(provider, "version", String)
    isempty(identity) || isempty(version) ? throw(ArgumentError(
        "SQLite runner lacks provider identity/version")) : nothing
    capabilities = sqlite_field(provider, "capabilities", AbstractVector)
    all(value -> value isa String && !isempty(value), capabilities) &&
        length(unique(capabilities)) == length(capabilities) ||
        throw(ArgumentError("SQLite provider capabilities are invalid"))
    return SQLiteProviderEvidence(identity, version, String[capabilities...])
end
