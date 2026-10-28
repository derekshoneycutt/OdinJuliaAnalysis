"""A one-based UTF-8 byte interval [first_byte, after_last_byte)."""
struct SQLSourceSpan
    first_byte::Int
    after_last_byte::Int
end

"""A lexical category without claiming contextual keyword/identifier resolution."""
struct SQLToken
    kind::Symbol
    span::SQLSourceSpan
end

struct SQLLexicalIssue
    span::SQLSourceSpan
    message::String
end

"""Capability state is independent of database acceptance and runtime evidence."""
struct SQLCapabilities
    lexical_accounting::Symbol
    delimiter_links::Symbol
    statement_inventory::Symbol
    query_structure::Symbol
end

struct SQLStatementRecord
    kind::Symbol
    span::SQLSourceSpan
    parent::Union{Nothing, Int}
    terminated::Bool
end

struct SQLQueryRecord
    kind::Symbol
    span::SQLSourceSpan
    statement::Int
    parent::Union{Nothing, Int}
end

struct SQLDeclarationRecord
    kind::Symbol
    name::SQLSourceSpan
    schema::Union{Nothing, SQLSourceSpan}
    temporary::Bool
    strict::Bool
    without_rowid::Bool
    module_name::Union{Nothing, SQLSourceSpan}
    module_arguments::Union{Nothing, SQLSourceSpan}
    partial_predicate::Union{Nothing, SQLSourceSpan}
end

struct SQLProjectionRecord
    query::Int
    span::SQLSourceSpan
    alias::Union{Nothing, SQLSourceSpan}
    explicit_as::Bool
    wildcard::Bool
    exists_only::Bool
end

struct SQLAliasRecord
    kind::Symbol
    span::SQLSourceSpan
    explicit_as::Bool
end

struct SQLJoinRecord
    query::Union{Nothing, Int}
    statement::Int
    span::SQLSourceSpan
    comma::Bool
end

struct SQLCTERecord
    name::SQLSourceSpan
    span::SQLSourceSpan
    statement::Int
    parent_query::Union{Nothing, Int}
end

struct SQLBindRecord
    span::SQLSourceSpan
    form::Symbol
    slot::Union{Nothing, Int}
end

struct SQLCapabilityGap
    span::SQLSourceSpan
    message::String
end

"""Flat structural evidence uses source spans and indices, never procedural metrics."""
struct SQLStructure
    statements::Vector{SQLStatementRecord}
    queries::Vector{SQLQueryRecord}
    declarations::Vector{SQLDeclarationRecord}
    projections::Vector{SQLProjectionRecord}
    aliases::Vector{SQLAliasRecord}
    joins::Vector{SQLJoinRecord}
    ctes::Vector{SQLCTERecord}
    binds::Vector{SQLBindRecord}
    keywords::Vector{SQLSourceSpan}
    gaps::Vector{SQLCapabilityGap}
    rules::Dict{String, Symbol}
end

"""Create empty inventories without claiming any structural capability."""
function SQLStructure()
    return SQLStructure(SQLStatementRecord[], SQLQueryRecord[],
        SQLDeclarationRecord[], SQLProjectionRecord[], SQLAliasRecord[],
        SQLJoinRecord[], SQLCTERecord[], SQLBindRecord[], SQLSourceSpan[],
        SQLCapabilityGap[], Dict{String, Symbol}())
end

"""Owned source snapshot and reusable lexical evidence; links use token indices.

Line starts and spans are one-based byte offsets, not Unicode display columns.
Zero links mean no matched parenthesis. Physical lines exclude a phantom line
after a final LF. Structural capabilities stay incomplete until actually parsed.
"""
struct SQLSourceEvidence
    source::String
    tokens::Vector{SQLToken}
    line_starts::Vector{Int}
    line_kinds::Vector{Symbol}
    delimiter_links::Vector{Int}
    issues::Vector{SQLLexicalIssue}
    capabilities::SQLCapabilities
    structure::SQLStructure
end

"""Retain the lexical constructor without inventing structural completion."""
function SQLSourceEvidence(
    source, tokens, line_starts, line_kinds, delimiter_links, issues, capabilities)
    return SQLSourceEvidence(source, tokens, line_starts, line_kinds,
        delimiter_links, issues, capabilities, SQLStructure())
end
