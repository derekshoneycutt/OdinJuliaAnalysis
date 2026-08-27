@testset "Julia source statistics" begin
    mktempdir() do root
        path = joinpath(root, "metrics.jl")
        write(path, """
            # File-level comment.
            struct Sample
                value::Int
            end

            \"\"\"Document the outer function.\"\"\"
            function outer(value)
                inner(item) = item > 0 ? item : 0
                return value > 0 ? inner(value) : 0
            end

            duplicate(value) = value
            duplicate(value, fallback) = value > 0 ? value : fallback
            """)

        report = analyze_source_statistics(path)
        @test report.schema_version == "1.0.0"
        @test report.language == "julia"
        @test report.file.parsed
        @test report.file.function_count == 4
        @test report.file.struct_count == 1
        @test report.file.total_cyclomatic_complexity == sum(
            item.cyclomatic_complexity for item in report.functions)
        @test report.file.maximum_function_complexity == maximum(
            item.cyclomatic_complexity for item in report.functions)
        @test report.selection === nothing
        @test [item.name for item in report.functions] == [
            "outer", "inner", "duplicate", "duplicate"]

        shared = only(OdinJuliaAnalysis.analyze_files(root, [path], Dict(), []))
        @test report.file.physical_lines == shared.physical_lines
        @test report.file.source_lines == shared.source_lines
        @test report.file.code_lines == shared.code_lines
        @test report.file.comment_lines == shared.comment_lines
        @test report.file.blank_lines == shared.blank_lines

        nested_line = only(filter(
            item -> item.name == "inner", report.functions)).start_line
        nested = analyze_source_statistics(path; line=nested_line)
        @test only(nested.functions).name == "inner"
        @test nested.selection.kind == "line"
        @test nested.selection.matches == 1

        overloads = analyze_source_statistics(path; function_name="duplicate")
        @test length(overloads.functions) == 2
        @test overloads.selection.matches == 2
        @test issorted(item.start_line for item in overloads.functions)

        encoded = JSON3.read(JSON3.write(overloads))
        @test encoded.schema_version == "1.0.0"
        @test length(encoded.functions) == 2
        @test !haskey(encoded.functions[1], :call_edges)
    end
end

@testset "empty and invalid source statistics" begin
    mktempdir() do root
        empty_path = joinpath(root, "empty.jl")
        write(empty_path, "const VALUE = 1\n")
        empty_report = analyze_source_statistics(empty_path)
        @test empty_report.file.function_count == 0
        @test empty_report.file.average_function_complexity == 0.0
        @test empty_report.file.maximum_function_complexity == 0
        @test empty_report.file.average_executable_lines == 0.0
        @test empty_report.file.maximum_executable_lines == 0
        @test isempty(empty_report.functions)

        markdown_path = joinpath(root, "notes.md")
        write(markdown_path, "# Notes\n")
        @test_throws ArgumentError analyze_source_statistics(markdown_path)
        @test_throws ArgumentError analyze_source_statistics(
            empty_path; function_name="missing")
        @test_throws ArgumentError analyze_source_statistics(empty_path; line=0)
        @test_throws ArgumentError analyze_source_statistics(
            empty_path; function_name="missing", line=1)

        broken_path = joinpath(root, "broken.jl")
        write(broken_path, "function broken(\n")
        @test_throws ArgumentError analyze_source_statistics(broken_path)
    end
end

@testset "Odin source statistics" begin
    mktempdir() do root
        path = joinpath(root, "metrics.odin")
        write(path, """
            package fixture

            Sample :: struct {
                value: int,
            }

            // Select one value.
            choose :: proc(value, fallback: int) -> int {
                if value > 0 {
                    return value
                }
                return fallback
            }
            """)

        report = analyze_source_statistics(path; function_name="choose")
        item = only(report.functions)
        @test report.language == "odin"
        @test report.file.parsed
        @test report.file.function_count == 1
        @test report.file.struct_count == 1
        @test item.parameter_count == 2
        @test item.cyclomatic_complexity == 2
        @test item.cognitive_complexity === nothing
        @test item.documented

        analysis = OdinJuliaAnalysis.OdinEngine.analyze_metrics(root, [path])
        canonical = only(analysis.functions)
        @test item.executable_lines == canonical.executable_lines
        @test item.cyclomatic_complexity == canonical.cyclomatic_complexity

        broken_path = joinpath(root, "broken.odin")
        write(broken_path, "package fixture\n\nbroken :: proc( {\n")
        @test_throws ArgumentError analyze_source_statistics(broken_path)
    end
end

@testset "statistics command options" begin
    options = OdinJuliaAnalysis.parse_stats_options([
        "fixture.jl", "--format=json", "--line=12"])
    @test options.path == "fixture.jl"
    @test options.format == "json"
    @test options.line == 12
    @test options.function_name === nothing

    @test OdinJuliaAnalysis.parse_stats_options(String[]) === nothing
    @test OdinJuliaAnalysis.parse_stats_options([
        "one.jl", "two.jl"]) === nothing
    @test OdinJuliaAnalysis.parse_stats_options([
        "fixture.jl", "--format=yaml"]) === nothing
    @test OdinJuliaAnalysis.parse_stats_options([
        "fixture.jl", "--line=text"]) === nothing
    @test OdinJuliaAnalysis.parse_stats_options([
        "fixture.jl", "--function=",]) === nothing
    @test OdinJuliaAnalysis.parse_stats_options([
        "fixture.jl", "--function=sample", "--line=1"]) === nothing
end