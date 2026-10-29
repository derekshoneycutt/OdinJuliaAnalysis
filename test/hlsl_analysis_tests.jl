@testset "HLSL lexical accounting" begin
    engine = OdinJuliaAnalysis.HLSLEngine
    cases = [
        ("", Symbol[]),
        ("\n", [:blank]),
        ("float x;", [:code]),
        ("float x;\n", [:code]),
        ("// comment\r\n\r\nfloat x; // inline\r\n", [:comment, :blank, :code]),
        ("/* start\n\nend */\n", [:comment, :blank, :comment]),
        ("/* comment */ float x;\nfloat y; /* comment */\n", [:code, :code]),
        ("/* outer /* not nested */ float x;", [:code]),
        ("#define VALUE 1\n#if 0\nfloat x;\n#endif", fill(:code, 4)),
        ("#include \"path//file.hlsli\"\n", [:code]),
        ("\"/* quoted */ // text\"; '\"';\n", [:code]),
        ("\"escaped \\\" // text\";\n", [:code]),
        ("// continued\\\ncomment\nfloat x;\n", [:comment, :comment, :code]),
        ("/\\\n/ split comment\n", [:comment, :comment]),
        ("/\\\r\n* split\r\n*\\\r\n/ float x;", [:comment, :comment, :comment, :code]),
        ("\"continued\\\n// quoted\";\n", [:code, :code]),
        ("// trailing splice\\\n", [:comment]),
        ("\\\n", [:code]),
        ("/* é */ float β;\n", [:code]),
    ]
    for (source, kinds) in cases
        evidence = engine.analyze(source)
        @test evidence.line_kinds == kinds
        @test isempty(evidence.issues)
    end
    for (source, location) in [
            ("float x;\n  /* unclosed", (2, 3)),
            ("  \"unclosed", (1, 3)),
            ("'unclosed\nfloat x;", (1, 1))]
        evidence = engine.analyze(source)
        issue = only(evidence.issues)
        @test (issue.line, issue.column) == location
        @test occursin("Unterminated HLSL", issue.message)
    end
    @test isempty(engine.analyze("not valid HLSL !!!").issues)
end

@testset "HLSL whole-file statistics" begin
    mktempdir() do root
        for extension in (".hlsl", ".hlsli")
            path = joinpath(root, "shader" * extension)
            write(path, "// contract\n\nfloat4 main() { return 1; }\n")
            report = analyze_source_statistics(path)
            @test report.language == "hlsl"
            @test !report.file.parsed
            @test (report.file.physical_lines, report.file.source_lines,
                report.file.code_lines, report.file.comment_lines,
                report.file.blank_lines) == (3, 2, 1, 1, 1)
            for field in (:function_count, :struct_count, :total_cyclomatic_complexity,
                    :complexity_per_code_line, :average_function_complexity,
                    :maximum_function_complexity, :average_executable_lines,
                    :maximum_executable_lines)
                @test getfield(report.file, field) === nothing
            end
            @test isempty(report.functions)
            @test report.metric_scope.status == "not-applicable"
            @test "hlsl" in report.metric_scope.excluded_languages
            @test_throws ArgumentError analyze_source_statistics(path; function_name="main")
            @test_throws ArgumentError analyze_source_statistics(path; line=1)
            @test OdinJuliaAnalysis.main(["stats", path, "--function=main"]) == 2
            @test OdinJuliaAnalysis.main(["stats", path, "--line=1"]) == 2
            output = IOBuffer()
            OdinJuliaAnalysis.write_statistics_report(output, report, "text")
            text = String(take!(output))
            @test occursin("lexical-only", text)
            @test !occursin("FUNCTIONS", text)
            OdinJuliaAnalysis.write_statistics_report(output, report, "json")
            encoded = JSON.parse(String(take!(output)))
            @test encoded.file.function_count === nothing
            @test encoded.file.total_cyclomatic_complexity === nothing
            @test encoded.language == "hlsl"
            write(path, "  /* unclosed")
            @test_throws ArgumentError analyze_source_statistics(path)
            @test OdinJuliaAnalysis.main(["stats", path]) == 2
        end
    end
end

@testset "HLSL common formatting checks" begin
    configuration = sql_rule_configuration()
    source = "// " * repeat("comment ", 20) * "\n\tfloat x;\n" *
        repeat("x", 121) * "\n/* " * repeat("x", 130) * " */ float y;\n"
    diagnostics = OdinJuliaAnalysis.check_common_rules("shader.hlsl", source, configuration)
    @test [(item.rule_id, item.line) for item in diagnostics] ==
        [("COMMON-NO-TABS", 2), ("COMMON-LINE-120", 3), ("COMMON-LINE-120", 4)]
    @test all(item -> item.response == Fail, diagnostics)
    disabled = with_rules(configuration, Dict(
        id => RuleSetting(id, false, Fail)
        for id in ("COMMON-NO-TABS", "COMMON-LINE-120")))
    @test isempty(OdinJuliaAnalysis.check_common_rules("shader.hlsli", source, disabled))
    warnings = with_rules(configuration,
        Dict("COMMON-NO-TABS" => RuleSetting("COMMON-NO-TABS", true, Warn)))
    @test only(OdinJuliaAnalysis.check_common_rules(
        "shader.hlsli", "\tfloat x;", warnings)).response == Warn
    @test isempty(OdinJuliaAnalysis.check_common_rules(
        "shader.hlsl", "// continued\\\n" * repeat("x", 150), configuration))
end

@testset "Standalone HLSL repositories and final outputs" begin
    configuration = sql_rule_configuration()
    mktempdir() do root
        write(joinpath(root, "shader.vert.hlsl"), "// contract\nfloat x;\n")
        write(joinpath(root, "shared.hlsli"), "\n/* shared */\nfloat y;\n")
        mkpath(joinpath(root, "excluded"))
        write(joinpath(root, "excluded", "ignored.hlsl"), "/* unclosed")
        paths = OdinJuliaAnalysis.discover_sources(root, ["excluded"])
        @test basename.(paths) == ["shader.vert.hlsl", "shared.hlsli"]
        @test OdinJuliaAnalysis.count_files_by_language(paths)["hlsl"] == 2
        rm(joinpath(root, "excluded", "ignored.hlsl"))
        report = OdinJuliaAnalysis.check_repository(root; configuration)
        @test report.exit_code == 0
        @test report.files_by_language["hlsl"] == 2
        @test all(file -> file.language == "hlsl" && !file.parsed, report.files)
        @test all(file -> file.struct_count === nothing, report.files)
        @test all(file -> isempty(file.functions) && isempty(file.declarations), report.files)
        totals = report.statistics.sources_by_language["hlsl"]
        @test (totals.files, totals.physical_lines, totals.source_lines,
            totals.code_lines, totals.comment_lines, totals.blank_lines) == (2, 5, 4, 2, 2, 1)
        @test report.statistics.cocomo === nothing
        @test report.statistics.locomo === nothing
        @test report.statistics.code_by_language["hlsl"].functions === nothing
        @test report.statistics.code_by_language["hlsl"].complexity === nothing
        @test only(filter(item -> item.name == "hlsl-lexer", report.engines)).status == "complete"
        @test only(filter(item -> item.rule_id == "COMMON-NO-TABS",
            report.rules)).files_checked == 2
        @test only(filter(item -> item.rule_id == "JULIA-SYNTAX",
            report.rules)).files_checked == 0
        encoded = JSON.parse(JSON.json(report))
        @test encoded.statistics.sources_by_language.hlsl.code_lines == 2
        @test encoded.statistics.code_by_language.hlsl.structs === nothing
        output = IOBuffer()
        OdinJuliaAnalysis.write_report(output, report, "text"; color=:never)
        text = String(take!(output))
        @test occursin("2 HLSL", text)
        @test occursin("HLSL SOURCE (lexical-only", text)
        for comprehensive in (false, true)
            OdinJuliaAnalysis.write_markdown_report(output, report; comprehensive)
            text = String(take!(output))
            @test occursin("| hlsl | 2 | 5 | 4 | 2 | 2 | 1 |", text)
            @test occursin("| HLSL | 2 | \u2014 | \u2014 |", text)
            @test occursin("HLSL coverage is lexical-only", text)
            @test occursin("Excluded: SQL, MARKDOWN, HLSL", text)
            @test !occursin("| hlsl | failed |", text)
            @test occursin("| hlsl | lexical-only |", text) == comprehensive
        end
        for field in fieldnames(OdinJuliaAnalysis.SourceTotals)
            @test getfield(report.statistics.sources, field) ==
                sum(item -> getfield(item, field), values(report.statistics.sources_by_language))
        end
        write(joinpath(root, "broken.hlsl"), "\n /* unclosed")
        broken = OdinJuliaAnalysis.check_repository(root; configuration)
        @test broken.exit_code == 2
        engine = only(filter(item -> item.name == "hlsl-lexer", broken.engines))
        @test engine.status == "incomplete"
        @test occursin("broken.hlsl:2:2:", engine.message)
    end
end

@testset "HLSL preserves procedural metric and estimate inputs" begin
    mktempdir() do root
        write(joinpath(root, "app.jl"), "\"\"\"Return one.\"\"\"\nf() = 1\n")
        configuration = sql_rule_configuration()
        before = OdinJuliaAnalysis.check_repository(root; configuration).statistics
        write(joinpath(root, "shader.hlsl"), "// shader\nfloat x;\n")
        after = OdinJuliaAnalysis.check_repository(root; configuration).statistics
        for field in (:code, :cocomo, :locomo)
            @test JSON.json(getfield(before, field)) == JSON.json(getfield(after, field))
        end
        @test after.sources.files == before.sources.files + 1
        @test after.sources.code_lines == before.sources.code_lines + 1
        @test after.metric_scope.complexity_code_lines == before.metric_scope.complexity_code_lines
        @test after.metric_scope.estimate_code_lines == before.metric_scope.estimate_code_lines
    end
end
