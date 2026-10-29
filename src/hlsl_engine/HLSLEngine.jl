"""Standalone lexical source accounting; shader compilation remains the consumer's concern."""
module HLSLEngine

"""A source-located boundary that prevents complete lexical accounting."""
struct LexicalIssue
    line::Int
    column::Int
    message::String
end

"""Physical-line classifications and lexical failures, with no structural claims."""
struct SourceEvidence
    line_kinds::Vector{Symbol}
    issues::Vector{LexicalIssue}
end

"""Remove escaped newlines while retaining physical coordinates for source accounting."""
function logical_characters(source)
    characters = collect(replace(source, "\r\n" => "\n"))
    result = Tuple{Char, Int, Int}[]
    index, line, column = 1, 1, 1
    while index <= length(characters)
        character = characters[index]
        if character == '\\' && index < length(characters) &&
                characters[index + 1] == '\n'
            index += 2
            line, column = line + 1, 1
            continue
        end
        push!(result, (character, line, column))
        line, column = character == '\n' ? (line + 1, 1) : (line, column + 1)
        index += 1
    end
    return result
end

"""Read a logical character, using a sentinel only for lookahead beyond end of input."""
character_at(characters, index) =
    index <= length(characters) ? characters[index][1] : '\0'

"""Find a non-nesting comment's end without interpreting quoted text within it."""
function comment_end(characters, start, block)
    index = start + 2
    while index <= length(characters)
        if block && character_at(characters, index) == '*' &&
                character_at(characters, index + 1) == '/'
            return index + 2, nothing
        elseif !block && character_at(characters, index) == '\n'
            return index + 1, nothing
        end
        index += 1
    end
    return index, block ? "Unterminated HLSL block comment." : nothing
end

"""Find quoted text's end, preserving escaped delimiters and rejecting bare newlines."""
function quoted_end(characters, start)
    delimiter = character_at(characters, start)
    index = start + 1
    while index <= length(characters)
        character = character_at(characters, index)
        character == delimiter && return index + 1, nothing
        character == '\n' && return index, "Unterminated HLSL quoted text."
        index += character == '\\' ? 2 : 1
    end
    return length(characters) + 1, "Unterminated HLSL quoted text."
end

"""Classify a lexical region; code takes precedence over comments on a physical line."""
function mark_region!(kinds, characters, start, after, kind)
    first_line = characters[start][2]
    last_line = after > length(characters) ? length(kinds) :
        characters[after - 1][2]
    for line in first_line:last_line
        kinds[line] == :blank && continue
        if kind == :code || kinds[line] != :code
            kinds[line] = kind
        end
    end
end

"""Account for authored HLSL lines lexically, without preprocessing or syntax validation."""
function analyze(source)
    lines = split(source, '\n'; keepempty=true)
    physical = isempty(source) ? 0 : length(lines) - (isempty(last(lines)) ? 1 : 0)
    kinds = [isempty(strip(line)) ? :blank : :unclassified for line in lines[1:physical]]
    characters = logical_characters(source)
    issues = LexicalIssue[]
    index = 1
    while index <= length(characters)
        character = character_at(characters, index)
        next = character_at(characters, index + 1)
        if character == '/' && next in ('/', '*')
            after, issue = comment_end(characters, index, next == '*')
            kind = :comment
        elseif character in ('"', '\'')
            after, issue = quoted_end(characters, index)
            kind = :code
        else
            isspace(character) || (kinds[characters[index][2]] = :code)
            index += 1
            continue
        end
        mark_region!(kinds, characters, index, after, kind)
        issue === nothing || push!(issues, LexicalIssue(
            characters[index][2], characters[index][3], issue))
        index = after
    end
    replace!(kinds, :unclassified => :code)
    return SourceEvidence(kinds, issues)
end

end
