"""Explicit SQLite values; integer and blob transport must remain lossless."""
abstract type SQLiteValue end

struct SQLiteNull <: SQLiteValue end

struct SQLiteInteger <: SQLiteValue
    value::Int64
end

struct SQLiteReal <: SQLiteValue
    value::Float64
end

struct SQLiteText <: SQLiteValue
    value::String
end

struct SQLiteBlob <: SQLiteValue
    value::Vector{UInt8}
end

struct SQLiteBind
    slot::Int
    value::SQLiteValue
end

"""An ordered source or fixture operation, never an expected-result assertion."""
abstract type SQLiteValidationStep end

struct SQLiteFileStep <: SQLiteValidationStep
    id::String
    path::String
    role::Symbol
    mode::Symbol
    bindings::Vector{SQLiteBind}
end

"""Declare a repository-relative SQL file and its explicit validation mode."""
function SQLiteFileStep(
    id::String, path::String; role::Symbol=:operation, mode::Symbol=:execute,
    bindings::Vector{SQLiteBind}=SQLiteBind[])
    return SQLiteFileStep(id, path, role, mode, bindings)
end

struct SQLiteFixtureStep <: SQLiteValidationStep
    id::String
    source::String
    role::Symbol
    mode::Symbol
    bindings::Vector{SQLiteBind}
end

"""Declare small context-building SQL without granting dedicated-file coverage."""
function SQLiteFixtureStep(
    id::String, source::String; role::Symbol=:setup, mode::Symbol=:execute,
    bindings::Vector{SQLiteBind}=SQLiteBind[])
    return SQLiteFixtureStep(id, source, role, mode, bindings)
end

struct SQLiteValidationCase
    id::String
    requirements::Vector{String}
    steps::Vector{SQLiteValidationStep}
    timeout_seconds::Union{Nothing, Float64}
end

"""Declare one disposable connection's ordered setup and operation steps."""
function SQLiteValidationCase(
    id::String; requirements::Vector{String}=String[],
    steps::AbstractVector{<:SQLiteValidationStep}=SQLiteValidationStep[],
    timeout_seconds::Union{Nothing, Real}=nothing)
    timeout = timeout_seconds === nothing ? nothing : Float64(timeout_seconds)
    return SQLiteValidationCase(id, requirements, SQLiteValidationStep[steps...], timeout)
end

struct SQLiteRunnerSettings
    command::Vector{String}
    working_directory::String
    protocol_version::Int
    timeout_seconds::Float64
end

"""Configure an argument vector; relative paths resolve against the project root."""
function SQLiteRunnerSettings(
    command::Vector{String}; working_directory::String=".",
    protocol_version::Int=1, timeout_seconds::Real=30)
    return SQLiteRunnerSettings(
        command, working_directory, protocol_version, Float64(timeout_seconds))
end

struct SQLiteValidationSettings
    runner::Union{Nothing, SQLiteRunnerSettings}
    cases::Vector{SQLiteValidationCase}
    require_coverage::Bool
end

"""Disable runtime validation unless a consumer explicitly configures a runner."""
function SQLiteValidationSettings(;
    runner::Union{Nothing, SQLiteRunnerSettings}=nothing,
    cases::Vector{SQLiteValidationCase}=SQLiteValidationCase[],
    require_coverage::Bool=false)
    return SQLiteValidationSettings(runner, cases, require_coverage)
end

"""Return provider-independent structural-only defaults."""
default_sqlite_validation_settings() = SQLiteValidationSettings()

"""Reject contradictory runtime configuration without resolving a project provider."""
function validate_sqlite_validation_settings(settings::SQLiteValidationSettings)
    if settings.runner === nothing
        settings.require_coverage && throw(ArgumentError(
            "SQLite coverage requires a configured runner"))
        isempty(settings.cases) || throw(ArgumentError(
            "SQLite validation cases require a configured runner"))
        return
    end
    runner = settings.runner
    isempty(runner.command) && throw(ArgumentError("SQLite runner requires a command"))
    all(argument -> !isempty(argument) && !occursin('\0', argument), runner.command) ||
        throw(ArgumentError("SQLite runner arguments must be nonempty and contain no NUL"))
    isempty(strip(runner.working_directory)) && throw(ArgumentError(
        "SQLite runner requires a working directory"))
    occursin('\0', runner.working_directory) && throw(ArgumentError(
        "SQLite runner working directory must contain no NUL"))
    runner.protocol_version == 1 || throw(ArgumentError(
        "unsupported SQLite runner protocol version: $(runner.protocol_version)"))
    validate_sqlite_timeout(runner.timeout_seconds)
    ids = Set{String}()
    for case in settings.cases
        validate_sqlite_identity!(ids, case.id, "case")
        validate_sqlite_case(case)
    end
end

"""Require a finite, positive case budget."""
function validate_sqlite_timeout(timeout)
    isfinite(timeout) && timeout > 0 || throw(ArgumentError(
        "SQLite timeout must be finite and positive"))
end

"""Require nonempty, unique identities within their protocol scope."""
function validate_sqlite_identity!(seen, id, label)
    isempty(strip(id)) && throw(ArgumentError("SQLite $label requires an id"))
    id in seen && throw(ArgumentError("duplicate SQLite $label id: $id"))
    push!(seen, id)
end

"""Validate ordered cases and explicit modes without executing fixture SQL."""
function validate_sqlite_case(case::SQLiteValidationCase)
    case.timeout_seconds === nothing || validate_sqlite_timeout(case.timeout_seconds)
    all(requirement -> !isempty(strip(requirement)), case.requirements) ||
        throw(ArgumentError("SQLite requirements must be nonempty"))
    length(unique(case.requirements)) == length(case.requirements) ||
        throw(ArgumentError("duplicate SQLite capability requirement"))
    ids = Set{String}()
    for step in case.steps
        id = validate_sqlite_step(step)
        validate_sqlite_identity!(ids, id, "step")
    end
end

"""Validate supported source kinds without assuming fields on arbitrary subtypes."""
function validate_sqlite_step(step::Union{SQLiteFileStep, SQLiteFixtureStep})
    step.role in (:setup, :operation) || throw(ArgumentError(
        "unsupported SQLite step role: $(step.role)"))
    step.mode in (:prepare, :execute) || throw(ArgumentError(
        "unsupported SQLite step mode: $(step.mode)"))
    step isa SQLiteFileStep && validate_repository_path(step.path, "SQLite source")
    step isa SQLiteFixtureStep && step.role != :setup && throw(ArgumentError(
        "SQLite fixture SQL is only for context setup"))
    validate_sqlite_bindings(step.bindings)
    return step.id
end

"""Reject extensions to the closed validation-step protocol explicitly."""
function validate_sqlite_step(step::SQLiteValidationStep)
    throw(ArgumentError("unsupported SQLite validation step: $(typeof(step))"))
end

"""Preserve sparse/repeated SQL slots while rejecting duplicate supplied values."""
function validate_sqlite_bindings(bindings)
    slots = Set{Int}()
    for binding in bindings
        binding.slot > 0 || throw(ArgumentError("SQLite bind slots must be positive"))
        binding.slot in slots && throw(ArgumentError(
            "duplicate SQLite binding: $(binding.slot)"))
        push!(slots, binding.slot)
        binding.value isa Union{SQLiteNull, SQLiteInteger, SQLiteReal,
            SQLiteText, SQLiteBlob} || throw(ArgumentError(
                "unsupported SQLite binding value: $(typeof(binding.value))"))
        binding.value isa SQLiteReal && !isfinite(binding.value.value) &&
            throw(ArgumentError("SQLite real bindings must be finite"))
        binding.value isa SQLiteText && !isvalid(binding.value.value) &&
            throw(ArgumentError("SQLite text bindings must be valid UTF-8"))
    end
end
