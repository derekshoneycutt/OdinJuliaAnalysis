"""Copied native error details survive statement finalization and connection teardown."""
struct SQLiteValidationFailure
    phase::String
    primary_code::Int
    extended_code::Int
    offset::Union{Nothing, Int}
    message::String
end

struct SQLiteProviderEvidence
    identity::String
    version::String
    capabilities::Vector{String}
end

struct SQLiteStepEvidence
    id::String
    source_id::String
    digest::String
    mode::String
    status::String
    attempted::Bool
    prepared::Bool
    executed::Bool
    processed_bytes::Int
    statement_count::Int
    failure::Union{Nothing, SQLiteValidationFailure}
end

"""A case result is granted evidence only after process and protocol reconciliation."""
struct SQLiteCaseEvidence
    id::String
    status::String
    provider::Union{Nothing, SQLiteProviderEvidence}
    completed::Bool
    transaction_complete::Bool
    finalized::Bool
    closed::Bool
    steps::Vector{SQLiteStepEvidence}
    failure::Union{Nothing, SQLiteValidationFailure}
    message::Union{Nothing, String}
    stderr::String
end

"""Dedicated-source coverage does not credit fixture SQL or skipped/partial steps."""
struct SQLiteSourceCoverage
    path::String
    digest::String
    declared::Bool
    attempted::Bool
    prepared::Bool
    executed::Bool
    validated::Bool
    modes::Vector{String}
end

struct SQLiteValidationEvidence
    status::String
    require_coverage::Bool
    cases::Vector{SQLiteCaseEvidence}
    coverage::Vector{SQLiteSourceCoverage}
    message::Union{Nothing, String}
end

"""Retain explicit structural-only defaults in historical report constructors."""
empty_sqlite_validation() = SQLiteValidationEvidence(
    "not-applicable", false, SQLiteCaseEvidence[], SQLiteSourceCoverage[], nothing)
