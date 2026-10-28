module SQLEngine

using ..OdinJuliaAnalysis: SQLSourceSpan, SQLToken, SQLLexicalIssue
using ..OdinJuliaAnalysis: SQLCapabilities, SQLSourceEvidence
using ..OdinJuliaAnalysis: SQLStructure, SQLStatementRecord, SQLQueryRecord
using ..OdinJuliaAnalysis: SQLDeclarationRecord, SQLProjectionRecord, SQLAliasRecord
using ..OdinJuliaAnalysis: SQLJoinRecord, SQLCTERecord, SQLBindRecord, SQLCapabilityGap
using ..OdinJuliaAnalysis: Diagnostic, Ignore, configured_diagnostic

const MAX_NESTING = 256
const SPACE_BYTES = (0x09, 0x0a, 0x0c, 0x0d, 0x20)
const OPERATORS = (
    "->>", "->", "||", "<<", ">>", "<=", ">=", "==", "!=", "<>",
    "+", "-", "*", "/", "%", "~", "&", "|", "<", ">", "=")
const NUMERIC_DIGIT = "[0-9](?:_?[0-9])*"
const DECIMAL_LITERAL = Regex(
    "^(?:$NUMERIC_DIGIT(?:\\.(?:$NUMERIC_DIGIT)?)?|\\.$NUMERIC_DIGIT)" *
    "(?:[eE][+-]?$NUMERIC_DIGIT)?\$")
const HEX_LITERAL = r"^0[xX][0-9a-fA-F](?:_?[0-9a-fA-F])*$"

struct ScannedToken
    kind::Symbol
    after_last_byte::Int
    valid::Bool
end

"""Return whether a byte belongs to a SQLite unquoted identifier."""
identifier_byte(byte) = byte >= 0x80 || byte in (0x5f, 0x24) ||
    0x30 <= byte <= 0x39 || 0x41 <= byte <= 0x5a || 0x61 <= byte <= 0x7a

"""Return whether a byte starts an unquoted identifier rather than a number."""
identifier_start(byte) = identifier_byte(byte) && !(0x30 <= byte <= 0x39)

"""Return whether an ASCII byte is a hexadecimal digit."""
hex_byte(byte) = 0x30 <= byte <= 0x39 || 0x41 <= byte <= 0x46 ||
    0x61 <= byte <= 0x66

"""Test a short ASCII spelling without decoding arbitrary UTF-8 byte offsets."""
function bytes_match(bytes, index, spelling)
    last = index + ncodeunits(spelling) - 1
    last <= length(bytes) || return false
    return all(offset -> bytes[index + offset - 1] == codeunit(spelling, offset),
        1:ncodeunits(spelling))
end

"""Scan a SQLite quote; doubled delimiters escape except in bracket identifiers."""
function quoted_end(bytes, index)
    opening = bytes[index]
    closing = opening == 0x5b ? 0x5d : opening
    cursor = index + 1
    while cursor <= length(bytes)
        if bytes[cursor] == closing
            if opening != 0x5b && cursor < length(bytes) &&
                bytes[cursor + 1] == closing
                cursor += 2
                continue
            end
            return cursor + 1, true
        end
        cursor += 1
    end
    return cursor, false
end

"""Scan a numeric literal, retaining malformed spellings as explicit issues."""
function numeric_end(bytes, index)
    cursor = index
    hexadecimal = bytes_match(bytes, cursor, "0x") ||
        bytes_match(bytes, cursor, "0X")
    hexadecimal && (cursor += 2)
    cursor = numeric_digits_end(bytes, cursor, hexadecimal)
    if !hexadecimal && cursor <= length(bytes) && bytes[cursor] == 0x2e
        cursor = numeric_digits_end(bytes, cursor + 1, false)
    end
    if !hexadecimal && cursor <= length(bytes) && bytes[cursor] in (0x65, 0x45)
        cursor += 1
        if cursor <= length(bytes) && bytes[cursor] in (0x2b, 0x2d)
            cursor += 1
        end
        cursor = numeric_digits_end(bytes, cursor, false)
    end
    while cursor <= length(bytes) && identifier_byte(bytes[cursor])
        cursor += 1
    end
    return cursor
end

"""Consume numeric digits and separators while leaving punctuation to the lexer."""
function numeric_digits_end(bytes, index, hexadecimal)
    cursor = index
    while cursor <= length(bytes)
        byte = bytes[cursor]
        digit = hexadecimal ? hex_byte(byte) : 0x30 <= byte <= 0x39
        digit || byte == 0x5f || break
        cursor += 1
    end
    return cursor
end

"""Scan numbered/anonymous binds and SQLite's extended Tcl-style dollar names."""
function bind_end(bytes, index)
    prefix = bytes[index]
    cursor = index + 1
    if prefix == 0x3f
        while cursor <= length(bytes) && 0x30 <= bytes[cursor] <= 0x39
            cursor += 1
        end
        return cursor, true
    end
    name_bytes = 0
    while cursor <= length(bytes)
        if identifier_byte(bytes[cursor])
            cursor += 1
            name_bytes += 1
        elseif bytes_match(bytes, cursor, "::")
            cursor += 2
        else
            break
        end
    end
    if name_bytes > 0 && cursor <= length(bytes) && bytes[cursor] == 0x28
        cursor += 1
        while cursor <= length(bytes) && bytes[cursor] != 0x29 &&
            bytes[cursor] ∉ SPACE_BYTES
            cursor += 1
        end
        closed = cursor <= length(bytes) && bytes[cursor] == 0x29
        return closed ? cursor + 1 : cursor, closed
    end
    return cursor, name_bytes > 0
end

"""Find comment extent; SQLite permits a block comment to reach end of input."""
function comment_end(bytes, index, block)
    cursor = index + 2
    while cursor <= length(bytes)
        block && bytes_match(bytes, cursor, "*/") && return cursor + 2
        !block && bytes[cursor] == 0x0a && return cursor
        cursor += 1
    end
    return cursor
end

"""Classify one token using SQLite lexical boundaries, not keyword heuristics."""
function scan_token(bytes, index)
    byte = bytes[index]
    if bytes_match(bytes, index, "--") || bytes_match(bytes, index, "/*")
        return ScannedToken(
            :comment, comment_end(bytes, index, bytes[index + 1] == 0x2a), true)
    elseif byte in (0x27, 0x22, 0x60, 0x5b)
        after, closed = quoted_end(bytes, index)
        return ScannedToken(byte == 0x27 ? :string : :quoted_identifier, after, closed)
    elseif byte in (0x78, 0x58) && bytes_match(bytes, index + 1, "'")
        after, closed = quoted_end(bytes, index + 1)
        valid = closed && iseven(after - index - 3) &&
            all(hex_byte, @view bytes[(index + 2):(after - 2)])
        return ScannedToken(:blob, after, valid)
    end
    return scan_unquoted_token(bytes, index)
end

"""Scan names, values and operators outside quotes and comments."""
function scan_unquoted_token(bytes, index)
    byte = bytes[index]
    if 0x30 <= byte <= 0x39 || byte == 0x2e &&
        index < length(bytes) && 0x30 <= bytes[index + 1] <= 0x39
        return ScannedToken(:number, numeric_end(bytes, index), true)
    elseif byte in (0x3f, 0x3a, 0x40, 0x24, 0x23)
        after, valid = bind_end(bytes, index)
        return ScannedToken(:bind, after, valid)
    elseif identifier_start(byte)
        cursor = index + 1
        while cursor <= length(bytes) && identifier_byte(bytes[cursor])
            cursor += 1
        end
        return ScannedToken(:word, cursor, true)
    elseif byte in (0x28, 0x29, 0x2c, 0x2e, 0x3b)
        return ScannedToken(:punctuation, index + 1, true)
    end
    operator = findfirst(item -> bytes_match(bytes, index, item), OPERATORS)
    operator === nothing && return ScannedToken(:invalid, index + 1, false)
    return ScannedToken(:operator, index + ncodeunits(OPERATORS[operator]), true)
end

"""Validate numeric spelling without granting SQLite semantic acceptance."""
function valid_number(source, span)
    bytes = @view codeunits(source)[span.first_byte:(span.after_last_byte - 1)]
    all(byte -> byte < 0x80, bytes) || return false
    text = String(SubString(source, span.first_byte, span.after_last_byte - 1))
    return occursin(HEX_LITERAL, text) || occursin(DECIMAL_LITERAL, text)
end

"""Build bounded matching-parenthesis links without recursive lexer calls."""
function link_delimiters(source, tokens, issues)
    links = zeros(Int, length(tokens))
    stack = Int[]
    overflow = 0
    for (index, token) in enumerate(tokens)
        token.kind == :punctuation || continue
        byte = codeunit(source, token.span.first_byte)
        if byte == 0x28
            if length(stack) == MAX_NESTING || overflow > 0
                overflow += 1
                overflow == 1 && push!(issues, SQLLexicalIssue(
                    token.span, "Parenthesis nesting exceeds $MAX_NESTING."))
            else
                push!(stack, index)
            end
        elseif byte == 0x29
            if overflow > 0
                overflow -= 1
            elseif isempty(stack)
                push!(issues, SQLLexicalIssue(token.span, "Unmatched closing parenthesis."))
            else
                opening = pop!(stack)
                links[opening] = index
                links[index] = opening
            end
        end
    end
    for index in stack
        push!(issues, SQLLexicalIssue(tokens[index].span, "Unclosed parenthesis."))
    end
    return links
end

"""Classify physical lines from disjoint tokens, including literal interiors."""
function classify_lines(source, tokens)
    bytes = codeunits(source)
    starts = isempty(bytes) ? Int[] : [1]
    for index in eachindex(bytes)
        bytes[index] == 0x0a && index < length(bytes) && push!(starts, index + 1)
    end
    kinds = fill(:blank, length(starts))
    line = 1
    for token in tokens
        while line < length(starts) && starts[line + 1] <= token.span.first_byte
            line += 1
        end
        last_line = line
        while last_line < length(starts) &&
            starts[last_line + 1] < token.span.after_last_byte
            last_line += 1
        end
        for covered in line:last_line
            if token.kind != :comment
                kinds[covered] = :code
            elseif kinds[covered] != :code
                kinds[covered] = :comment
            end
        end
        line = last_line
    end
    return starts, kinds
end

"""Lex one owned SQL snapshot without claiming deeper structural capabilities."""
function lex(source::String)
    tokens = SQLToken[]
    issues = SQLLexicalIssue[]
    bytes = codeunits(source)
    cursor = 1
    while cursor <= length(bytes)
        if bytes[cursor] in SPACE_BYTES
            cursor += 1
            continue
        elseif bytes_match(bytes, cursor, "\xef\xbb\xbf")
            cursor += 3
            continue
        end
        scanned = scan_token(bytes, cursor)
        span = SQLSourceSpan(cursor, scanned.after_last_byte)
        push!(tokens, SQLToken(scanned.kind, span))
        valid = scanned.valid &&
            (scanned.kind != :number || valid_number(source, span))
        valid || push!(issues, SQLLexicalIssue(
            span, "Malformed SQLite $(scanned.kind) token."))
        cursor = scanned.after_last_byte
    end
    isvalid(source) || push!(issues, SQLLexicalIssue(
        SQLSourceSpan(1, ncodeunits(source) + 1), "Source is not valid UTF-8."))
    occursin('\0', source) && push!(issues, SQLLexicalIssue(
        SQLSourceSpan(1, ncodeunits(source) + 1), "SQL source contains NUL."))
    lexical_complete = isempty(issues)
    links = link_delimiters(source, tokens, issues)
    starts, kinds = classify_lines(source, tokens)
    capabilities = SQLCapabilities(
        lexical_complete ? :complete : :incomplete,
        isempty(issues) ? :complete : :incomplete, :incomplete, :incomplete)
    return SQLSourceEvidence(source, tokens, starts, kinds, links, issues, capabilities)
end

include("parser.jl")
include("expressions.jl")
include("queries.jl")
include("statements.jl")
include("rules.jl")

end
