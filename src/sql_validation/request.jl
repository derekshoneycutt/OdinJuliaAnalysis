const SQLITE_PROTOCOL_VERSION = 1
const SQLITE_REQUEST_LIMIT = 8 * 1024 * 1024
const SQLITE_SOURCE_LIMIT = 1024 * 1024
const SQLITE_STEP_LIMIT = 256
const SQLITE_STDOUT_LIMIT = 2 * 1024 * 1024
const SQLITE_STDERR_LIMIT = 64 * 1024

"""Hash the exact UTF-8 snapshot, never a later filesystem read."""
sqlite_source_digest(source) = bytes2hex(SHA.sha256(codeunits(source)))

"""Serialize explicit SQL types without lossy JSON integer or binary transport."""
sqlite_bind_value(value::SQLiteNull) = ("null", nothing)
"""Preserve the complete signed 64-bit integer range as a decimal string."""
sqlite_bind_value(value::SQLiteInteger) = ("integer", string(value.value))
"""Transport finite IEEE real values as JSON numbers."""
sqlite_bind_value(value::SQLiteReal) = ("real", value.value)
"""Preserve empty text and embedded NUL as text, not NULL."""
sqlite_bind_value(value::SQLiteText) = ("text", value.value)
"""Transport binary values as lowercase hexadecimal, including empty blobs."""
sqlite_bind_value(value::SQLiteBlob) = ("blob", bytes2hex(value.value))

"""Build a typed binding's protocol record using its explicit slot identity."""
function sqlite_request_bind(binding)
    type, value = sqlite_bind_value(binding.value)
    return (; binding.slot, type, value)
end

"""Resolve file steps exclusively against already-discovered, owned SQL snapshots."""
function sqlite_step_source(step::SQLiteFileStep, case_id, sources)
    path = replace(normpath(step.path), '\\' => '/')
    haskey(sources, path) || throw(ArgumentError(
        "SQLite source is nonexistent, excluded or not discovered SQL: $path"))
    return path, sources[path]
end

"""Fixture source can establish context but cannot acquire dedicated-file coverage."""
function sqlite_step_source(step::SQLiteFixtureStep, case_id, sources)
    return "fixture:$case_id:$(step.id)", SQLEngine.lex(step.source)
end

"""Send all lexical bind tokens independently of structural parser completion."""
function sqlite_bind_tokens(evidence)
    return [(;
        first_byte=token.span.first_byte,
        after_last_byte=token.span.after_last_byte,
        text=String(SubString(evidence.source, token.span.first_byte,
            prevind(evidence.source, token.span.after_last_byte))))
        for token in evidence.tokens if token.kind == :bind]
end

"""Construct a bounded complete-source case request; native prepare tails own statements."""
function sqlite_case_request(case, sources)
    length(case.steps) <= SQLITE_STEP_LIMIT || throw(ArgumentError(
        "SQLite case exceeds $SQLITE_STEP_LIMIT steps"))
    steps = map(case.steps) do step
        source_id, evidence = sqlite_step_source(step, case.id, sources)
        isvalid(evidence.source) || throw(ArgumentError(
            "SQLite protocol requires valid UTF-8 source: $source_id"))
        ncodeunits(evidence.source) <= SQLITE_SOURCE_LIMIT || throw(ArgumentError(
            "SQLite source exceeds $SQLITE_SOURCE_LIMIT bytes: $source_id"))
        (; step.id, role=string(step.role), mode=string(step.mode), source_id,
            source=evidence.source, digest=sqlite_source_digest(evidence.source),
            binds=sqlite_request_bind.(step.bindings),
            bind_tokens=sqlite_bind_tokens(evidence))
    end
    request = (; protocol_version=SQLITE_PROTOCOL_VERSION, case_id=case.id,
        requirements=case.requirements, steps)
    ncodeunits(JSON.json(request)) <= SQLITE_REQUEST_LIMIT || throw(ArgumentError(
        "SQLite case request exceeds $SQLITE_REQUEST_LIMIT bytes"))
    return request
end

"""Resolve the executable and working directory against the documented repository root."""
function sqlite_runner_command(root, runner)
    arguments = copy(runner.command)
    arguments[1] = isabspath(arguments[1]) ? arguments[1] :
        normpath(joinpath(root, arguments[1]))
    directory = isabspath(runner.working_directory) ? runner.working_directory :
        normpath(joinpath(root, runner.working_directory))
    return Cmd(Cmd(arguments); dir=directory)
end
