@testset verbose=TEST_VERBOSE "Julia closing parenthesis placement" begin
    configuration = OdinJuliaAnalysis.load_settings()
    @testset "accepts close beside final argument" begin
        source = "f(\n    first,\n    second)\n"
        @test isempty(OdinJuliaAnalysis.JuliaEngine.check(
            "valid.jl",
            source,
            configuration))
    end

    @testset "rejects isolated close" begin
        source = "f(\n    first,\n    second\n)\n"
        diagnostics = OdinJuliaAnalysis.JuliaEngine.check(
            "invalid.jl",
            source,
            configuration)
        @test only(diagnostics).rule_id == "JULIA-CLOSING-PAREN-PLACEMENT"
        @test only(diagnostics).line == 4
        @test only(diagnostics).response == Fail
    end

    @testset "ignores strings comments and empty calls" begin
        source = "let\n    text = \"value )\"\nend\n# )\nf()\n"
        @test isempty(OdinJuliaAnalysis.JuliaEngine.check(
            "trivia.jl",
            source,
            configuration))
    end
end

@testset "Markdown structure" begin
    configuration = OdinJuliaAnalysis.load_settings()
    source = """
        # Title

        ### Skipped Level

        ```text
        # Not A Heading
        ```

        ```
        missing language
        ```
        """
    diagnostics = OdinJuliaAnalysis.MarkdownEngine.check(
        "fixture.md",
        source,
        configuration)
    @test Set(item.rule_id for item in diagnostics) == Set([
        "MARKDOWN-HEADING-LEVELS",
        "MARKDOWN-CODE-FENCE-LANGUAGE",
    ])

    missing_h1 = OdinJuliaAnalysis.MarkdownEngine.check(
        "missing.md",
        "## Section\n",
        configuration)
    @test any(item -> item.rule_id == "MARKDOWN-SINGLE-H1", missing_h1)

    mktempdir() do root
        write(joinpath(root, "existing.md"), "# Existing\n")
        link_source = """
            # Links and Images

            [Existing](existing.md#section)
            [Missing](missing.md)
            [Web](https://example.com)
            [Email](mailto:docs@example.com)
            [Section](#links-and-images)

            ![**Useful** description](image.png)
            ![](empty.png)
            """
        path = joinpath(root, "guide.md")
        diagnostics = OdinJuliaAnalysis.MarkdownEngine.check(
            "guide.md",
            link_source,
            configuration;
            filesystem_path=path)
        @test count(
            item -> item.rule_id == "MARKDOWN-RELATIVE-LINK",
            diagnostics) == 1
        @test count(
            item -> item.rule_id == "MARKDOWN-IMAGE-ALT-TEXT",
            diagnostics) == 1
        @test only(filter(
            item -> item.rule_id == "MARKDOWN-RELATIVE-LINK",
            diagnostics)).line == 4
        @test only(filter(
            item -> item.rule_id == "MARKDOWN-IMAGE-ALT-TEXT",
            diagnostics)).line == 10

        disabled = with_rules(configuration, Dict(
            "MARKDOWN-RELATIVE-LINK" => RuleSetting(
                "MARKDOWN-RELATIVE-LINK", false, Warn),
            "MARKDOWN-IMAGE-ALT-TEXT" => RuleSetting(
                "MARKDOWN-IMAGE-ALT-TEXT", false, Warn)))
        disabled_diagnostics = OdinJuliaAnalysis.MarkdownEngine.check(
            "guide.md",
            link_source,
            disabled;
            filesystem_path=path)
        @test all(
            item -> item.rule_id ∉ (
                "MARKDOWN-RELATIVE-LINK", "MARKDOWN-IMAGE-ALT-TEXT"),
            disabled_diagnostics)
    end
end

@testset "repository check" begin
    mktempdir() do root
        write(
            joinpath(root, "valid.jl"),
            "\"\"\"Return the selected value.\"\"\"\n" *
            "function choose(a, b)\n" *
            "    return a > 0 ? a : b\n" *
            "end\n")
        write(
            joinpath(root, "valid.odin"),
            "package fixture\n\n" *
            "// Return the selected value.\n" *
            "choose :: proc(a, b: int) -> int {\n" *
            "    if a > 0 {\n" *
            "        return a\n" *
            "    }\n" *
            "    return b\n" *
            "}\n")
        progress = String[]
        configuration = with_odin_build_targets(
            with_jet_entries(
                OdinJuliaAnalysis.load_settings(), JetEntryPoint[]),
            OdinBuildTarget[])
        report = OdinJuliaAnalysis.check_repository(
            root;
            configuration,
            progress=message -> push!(progress, message))
        @test report.files_analyzed == 2
        @test isempty(report.diagnostics)
        @test length(report.files) == 2
        functions = OdinJuliaAnalysis.analysis_functions(report.files)
        @test length(functions) == 2
        julia_function = only(filter(
            item -> item.language == "julia", functions))
        odin_function = only(filter(
            item -> item.language == "odin", functions))
        @test julia_function.name == "choose"
        @test julia_function.parameter_count == 2
        @test julia_function.cyclomatic_complexity == 2
        @test julia_function.cognitive_complexity == 2
        @test julia_function.documented
        @test odin_function.name == "choose"
        @test progress == [
            "Discovering source files",
            "Checking 2 source files",
            "Running JET on 0 configured entry points",
            "Running Odin analysis on 1 files",
            "Running 0 analytical Odin builds",
            "Assembling the canonical report",
        ]
        @test odin_function.parameter_count == 2
        @test odin_function.cyclomatic_complexity == 2
        @test odin_function.cognitive_complexity === nothing
        @test odin_function.documented
        @test any(
            engine -> engine.name == "jet" && engine.status == "complete",
            report.engines)
        @test any(
            engine -> engine.name == "architecture" &&
                engine.status == "not-applicable",
            report.engines)
        jet_rule = only(filter(
            rule -> rule.rule_id == "JULIA-JET-POSSIBLE-ERROR",
            report.rules))
        @test jet_rule.status == "not-applicable"

        output = IOBuffer()
        OdinJuliaAnalysis.write_report(output, report, "json")
        @test occursin("\"schema_version\": \"4.0.0\"", String(take!(output)))

        settings_path = write_jet_settings(
            tempname(),
            "JetEntryPoint[]")
        report_path = joinpath(root, "report.md")
        @test OdinJuliaAnalysis.main([
            "check", root, "--format=text", "--report=$report_path",
            "--settings=$settings_path"]) == 0
        report_text = read(report_path, String)
        @test !occursin("## File Inventory", report_text)
        @test occursin("## Repository Statistics", report_text)
        @test occursin("| Odin |", report_text)
        @test occursin("| Julia |", report_text)
        @test occursin("| Total |", report_text)
        @test occursin("### COCOMO Development Estimate", report_text)
        @test occursin("### LOCOMO Regeneration Estimate", report_text)
        @test !occursin("## Function And Procedure Inventory", report_text)
        @test occursin("## Analytical Odin Builds", report_text)
        @test occursin("No analytical Odin builds were configured.", report_text)
        @test occursin("## Allocation Ledger", report_text)
        @test occursin("## Rule Coverage", report_text)
        @test occursin("## Extension Results", report_text)
        @test occursin("## Complete Findings By File", report_text)
        @test occursin("Functions within thresholds", report_text)
        @test occursin("ODIN-ALLOCATION", report_text)
        @test OdinJuliaAnalysis.main([
            "check", root, "--format=text", "--settings=$settings_path"]) == 0
        @test OdinJuliaAnalysis.main(["check", "--help"]) == 0

        stats_path = joinpath(root, "stats.jl")
        write(stats_path, """
            # File comment.
            documented(value) = value > 0 ? value : 0
            duplicate(value) = value
            duplicate(value, fallback) = value > 0 ? value : fallback
            """)
        stats = OdinJuliaAnalysis.analyze_source_statistics(stats_path)
        @test stats.file.function_count == 3
        @test stats.file.total_cyclomatic_complexity == 5
        @test [item.name for item in stats.functions] == [
            "documented", "duplicate", "duplicate"]

        selected = OdinJuliaAnalysis.analyze_source_statistics(
            stats_path; function_name="duplicate")
        @test selected.selection.matches == 2
        @test length(selected.functions) == 2

        line_selected = OdinJuliaAnalysis.analyze_source_statistics(
            stats_path; line=2)
        @test only(line_selected.functions).name == "documented"

        stats_output = IOBuffer()
        OdinJuliaAnalysis.write_statistics_report(stats_output, selected, "text")
        stats_text = String(take!(stats_output))
        @test occursin("FILE STATISTICS", stats_text)
        @test occursin("SELECTED FUNCTIONS", stats_text)
        @test count("duplicate", stats_text) == 2

        json_output = IOBuffer()
        OdinJuliaAnalysis.write_statistics_report(json_output, selected, "json")
        stats_json = JSON3.read(String(take!(json_output)))
        @test stats_json.schema_version == "1.0.0"
        @test stats_json.selection.matches == 2
        @test OdinJuliaAnalysis.main([
            "stats", stats_path, "--function=documented"]) == 0
        @test OdinJuliaAnalysis.main(["stats", stats_path, "--line=0"]) == 2
        @test OdinJuliaAnalysis.main([
            "stats", stats_path, "--function=missing"]) == 2
    end
end

@testset "analytical Odin build" begin
    base = with_jet_entries(
        OdinJuliaAnalysis.load_settings(), JetEntryPoint[])
    strict_flags = [
        "-vet",
        "-strict-style",
        "-disallow-do",
        "-warnings-as-errors",
    ]

    mktempdir() do root
        package = joinpath(root, "fixture")
        mkpath(package)
        write(
            joinpath(package, "main.odin"),
            "package fixture\n\n// Run the fixture.\nmain :: proc() {}\n")
        target = OdinBuildTarget(
            "fixture", "fixture", "fixture-analysis", strict_flags)
        configuration = with_odin_build_targets(base, [target])
        report = OdinJuliaAnalysis.check_repository(root; configuration)

        @test report.exit_code == 0
        build = only(report.odin_builds)
        @test build.status == "passed"
        @test build.exit_code == 0
        @test build.input == "fixture"
        @test build.output == joinpath(
            ".build", "analysis", "odin", "fixture-analysis")
        @test isfile(joinpath(root, build.output))
        @test build.flags == strict_flags
        @test build.command[1:3] == ["odin", "build", "fixture"]
    end

    mktempdir() do root
        target = OdinBuildTarget(
            "missing", "missing", "missing-analysis", strict_flags)
        configuration = with_odin_build_targets(base, [target])
        report = OdinJuliaAnalysis.check_repository(root; configuration)

        @test report.exit_code == 1
        build = only(report.odin_builds)
        @test build.status == "failed"
        @test build.exit_code != 0
        @test !isempty(build.stdout) || !isempty(build.stderr)
        failure = only(filter(
            item -> item.rule_id == "ODIN-BUILD-FAILED",
            report.diagnostics))
        @test failure.response == Fail
        rule = only(filter(
            item -> item.rule_id == "ODIN-BUILD-FAILED",
            report.rules))
        @test rule.status == "evaluated"
        @test rule.files_checked == 1
        @test rule.findings == 1

        output = IOBuffer()
        OdinJuliaAnalysis.write_markdown_report(output, report)
        report_text = String(take!(output))
        @test occursin("## Analytical Odin Builds", report_text)
        @test occursin("### `missing`", report_text)
        @test occursin("| Status | FAILED |", report_text)
        @test occursin("#### Standard Error", report_text)

        rules = Dict(
            "ODIN-BUILD-FAILED" => RuleSetting(
                "ODIN-BUILD-FAILED", true, Warn))
        warning_configuration = with_rules(configuration, rules)
        warning_report = OdinJuliaAnalysis.check_repository(
            root; configuration=warning_configuration)
        @test warning_report.exit_code == 0
        @test only(filter(
            item -> item.rule_id == "ODIN-BUILD-FAILED",
            warning_report.diagnostics)).response == Warn
    end
end

@testset "report status and color" begin
    mktempdir() do root
        write(joinpath(root, "long.jl"), repeat("x", 91))
        configuration = OdinJuliaAnalysis.load_settings()
        blocking = with_rules(configuration, Dict(
            "JULIA-JET-POSSIBLE-ERROR" => RuleSetting(
                "JULIA-JET-POSSIBLE-ERROR", false, Report));
            failure_threshold=Warn)
        blocking = with_odin_build_targets(blocking, OdinBuildTarget[])
        report = OdinJuliaAnalysis.check_repository(root; configuration=blocking)
        @test report.exit_code == 1

        plain = IOBuffer()
        OdinJuliaAnalysis.write_report(plain, report, "text"; color=:never)
        plain_text = String(take!(plain))
        @test occursin("Target:", plain_text)
        @test occursin("$(joinpath(root, "long.jl")):1:91:", plain_text)
        @test occursin("ENGINES", plain_text)
        @test occursin("RULES", plain_text)
        @test occursin("EVALUATED  COMMON-LINE-90 [WARN]", plain_text)
        @test occursin("EVALUATED  JULIA-DOC-MISSING [FAIL]", plain_text)
        @test occursin("WARN (1)", plain_text)
        @test endswith(plain_text, "POLICY FAILURE (exit 1)\n")
        @test !occursin('\e', plain_text)

        colored = IOBuffer()
        OdinJuliaAnalysis.write_report(colored, report, "text"; color=:always)
        colored_text = String(take!(colored))
        @test occursin('\e', colored_text)
        @test occursin(
            "\e[1;33m[\e[0m\e[1;33mCOMMON-LINE-90\e[0m" *
                "\e[1;33m]\e[0m \e[1;33mLine exceeds",
            colored_text)
        @test occursin(
            "Report            |        0      0      0\n" *
            "\e[1;33mWarn             \e[0m |        1      1      1\n" *
            "Fail              |        0      0      0",
            colored_text)

        json = IOBuffer()
        OdinJuliaAnalysis.write_report(json, report, "json"; color=:always)
        json_text = String(take!(json))
        @test occursin("\"response\": \"warn\"", json_text)
        @test !occursin('\e', json_text)

        reviewed = OdinJuliaAnalysis.Diagnostic(
            "ODIN-ALLOCATION-IMPLICIT",
            Report,
            "reviewed.odin",
            1,
            1,
            "new may allocate memory.",
            nothing,
            nothing,
            "odin-ast",
            "new",
            "new",
            nothing,
            "definite",
            "reviewed",
            "int",
            "reviewed-new",
            "Fixture decision.")
        @test OdinJuliaAnalysis.reviewed_policy_label(reviewed, false) ==
            " [REVIEWED: reviewed-new]"
        reviewed_summary = IOBuffer()
        OdinJuliaAnalysis.write_analysis_summary(
            reviewed_summary,
            [reviewed],
            false)
        @test occursin(
            "Reviewed allocations: 1 findings, 1 policies",
            String(take!(reviewed_summary)))
    end
end

@testset "report always shows allocations" begin
    mktempdir() do root
        line_path = joinpath(root, "a_long.jl")
        allocation_path = joinpath(root, "z_allocation.odin")
        write(
            line_path,
            repeat("x", 121) * "\n" *
            repeat("y", 101) * "\n" *
            repeat("z", 101))
        write(
            allocation_path,
            "package fixture\n\n" *
            "value := new(int, context.allocator)\n" *
            "temporary := new(int, context.temp_allocator)\n")
        configuration = with_rules(OdinJuliaAnalysis.load_settings(), Dict(
            "JULIA-JET-POSSIBLE-ERROR" => RuleSetting(
                "JULIA-JET-POSSIBLE-ERROR", false, Report),
            "ODIN-NONCONST-GLOBAL" => RuleSetting(
                "ODIN-NONCONST-GLOBAL", false, Warn)))
        configuration = with_odin_build_targets(
            configuration, OdinBuildTarget[])
        report = OdinJuliaAnalysis.check_repository(
            root; configuration=configuration)

        output = IOBuffer()
        OdinJuliaAnalysis.write_report(
            output,
            report,
            "text";
            color=:never,
            warning_limit=1)
        report_text = String(take!(output))
        @test occursin("[COMMON-LINE-100]", report_text)
        @test occursin("[COMMON-LINE-120]", report_text)
        @test occursin("[ODIN-ALLOCATION-CONTEXT]", report_text)
        @test occursin("$allocation_path:3:10:", report_text)
        report_position = findfirst("\nREPORT (1)\n", report_text)
        warning_position = findfirst("\nWARN (3)\n", report_text)
        failure_position = findfirst("\nFAIL (1)\n", report_text)
        summary_position = findfirst("\nAnalysis Summary:", report_text)
        status_position = findfirst("\nPOLICY FAILURE (exit 1)\n", report_text)
        @test first(report_position) < first(warning_position) <
            first(failure_position)
        @test first(failure_position) < first(summary_position) <
            first(status_position)
        @test occursin(
            "Analysis Summary: | Findings  Files  Rules\n" *
            "Report            |        1      1      1\n" *
            "Warn              |        3      2      2\n" *
            "Fail              |        1      1      1",
            report_text)

        colored = IOBuffer()
        OdinJuliaAnalysis.write_report(
            colored,
            report,
            "text";
            color=:always,
            warning_limit=1)
        colored_text = String(take!(colored))
        @test occursin(
            "\e[1;33m[\e[0m\e[1;31mCOMMON-LINE-100\e[0m" *
                "\e[1;33m]\e[0m \e[1;31mLine exceeds",
            colored_text)
        @test occursin(
            "\e[1;33m[\e[0m\e[1;31mODIN-ALLOCATION-CONTEXT\e[0m" *
                "\e[1;33m]\e[0m \e[1;31mnew may allocate",
            colored_text)
        @test occursin(
            "\e[32m[\e[0m\e[33mODIN-ALLOCATION-TEMPORARY\e[0m" *
                "\e[32m]\e[0m \e[33mnew may allocate memory.\e[0m",
            colored_text)
        @test occursin(
            "\e[36mReport           \e[0m |        1      1      1\n" *
            "\e[1;33mWarn             \e[0m |        3      2      2\n" *
            "\e[1;31mFail             \e[0m |        1      1      1",
            colored_text)
        @test occursin("\nREPORT (1)\n", colored_text)
        @test occursin(
            "1 more non-allocation WARN findings omitted",
            colored_text)
    end
end


