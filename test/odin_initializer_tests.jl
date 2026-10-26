const INITIALIZER_LAYOUT_RULE = "ODIN-NAMED-INITIALIZER-LAYOUT"

"""Analyze a statement inside an ordinary indented procedure fixture."""
function initializer_fixture(root, body;
    newline="\n", configuration=OdinJuliaAnalysis.load_settings())
    path = joinpath(root, "initializer_test.odin")
    indented = join(("    " * line for line in split(body, '\n')), '\n')
    source = "package fixture\n// Exercise initializer policy.\nexample :: proc() {\n" *
        indented * "\n}\n"
    write(path, replace(source, "\n" => newline))
    analysis = OdinJuliaAnalysis.OdinEngine.analyze(root, [path], configuration)
    @test !any(item -> item.rule_id == "ODIN-SYNTAX", analysis.diagnostics)
    return (; path, analysis, item=only(analysis.functions))
end

"""Select fixture thresholds and counting mode without changing other policy."""
function initializer_metrics(mode; reviewed=ReviewedComplexity[])
    thresholds = ResponseThresholds(1, 3, 5)
    return FunctionMetricSettings(
        thresholds, thresholds, ResponseThresholds(10, 13, 16),
        ResponseThresholds(10, 15, 18), reviewed;
        odin_line_count_mode=mode)
end

@testset "Odin initializer counting examples and expression boundaries" begin
    cases = [
        (
            "calling_something(1, {\n" *
            "    fu = bar,\n    fu2 = 123,\n    poo = another_call(),\n" *
            "    blech =\n        (this || that) &&\n        (anotherthis || anotherthat),\n" *
            "}, another_datum)", 8, 5),
        (
            "mydata: My_Struct = {\n    x = 123123.234,\n    y = 548.234,\n" *
            "    z = 3485.2394824,\n    meta = \"something\",\n}", 6, 1),
        ("value := Thing{\n    x = -1,\n    y = (.Ready),\n" *
            "    z = settings.width,\n}", 5, 1),
        ("value := Thing{\n    x = call(),\n}", 3, 2),
        ("value := Thing{\n    x =\n        call(),\n}", 4, 2),
        ("value := Thing{\n    x = call(\n        argument),\n}", 4, 3),
        ("value := Thing{\n    x = values[0],\n    y = f32(1),\n" *
            "    z = a + b,\n}", 5, 4),
        ("value := Thing{\n    child = Inner{\n        x = 1,\n    },\n" *
            "    flag = true,\n}", 6, 1),
        ("value := Thing{\n    child = Inner{\n        x = call(),\n    },\n" *
            "    flag = true,\n}", 6, 2),
        ("value := Thing{\n    child = build(Inner{\n        x = 1,\n    }),\n}", 5, 2),
        ("call(Thing{\n    x = 1,\n})", 3, 1),
        ("call(Thing{\n    x = 1,\n}, other)", 3, 2),
        ("(Thing{\n    x = 1,\n})", 3, 1),
        ("value := Thing{\n    x = 1,\n}.field", 3, 2),
        ("call(Thing{\n    x = 1,\n}, Thing{\n    y = 2,\n})", 5, 2),
        ("value := Thing{x = 1}", 1, 1),
        ("value := Thing{}", 1, 1),
        ("value := [2]int{\n    1,\n    2,\n}", 4, 1),
        ("value := []f64{\n    -1,\n    (.Ready),\n    settings.width,\n}", 5, 1),
        ("value := []f64{\n    1,\n    calculate_value(),\n" *
            "    (left + right) *\n        scale,\n}", 6, 4),
        ("value := Thing{\n    1,\n    call(),\n}", 4, 2),
        ("value := [3][3]f64{\n    {1, 0, 0},\n    {0, 1, 0},\n" *
            "    {0, 0, 1},\n}", 5, 1),
        ("value := []Point{\n    {\n        x = 1,\n        y = 2,\n    },\n" *
            "    {\n        x = 3,\n        y = compute_y(),\n    },\n}", 10, 2),
        ("value := Thing{\n    values = []int{\n        1,\n        call(),\n    },\n}",
            6, 2),
        ("call([]int{\n    1,\n    2,\n}, other)", 4, 2),
        ("value := []int{\n    build(Inner{\n        x = 1,\n    }),\n}", 5, 2),
        ("value := []int{\n    values[0],\n    int(1),\n    a + b,\n}", 5, 4),
        ("value := Thing{\n    // field comment\n\n    x = 1, // trailing\n" *
            "    /* block comment */\n}", 3, 1),
        ("value := Thing{\n    x =\n        // RHS comment\n        call(),\n}", 4, 2),
    ]
    mktempdir() do root
        for (body, ordinary, reduced) in cases, newline in ("\n", "\r\n")
            @testset "$body ($newline)" begin
                fixture = initializer_fixture(root, body; newline)
                @test fixture.item.executable_lines == ordinary
                @test fixture.item.initializer_reduced_lines == reduced
                @test reduced <= ordinary
                ordinary > reduced && @test !any(
                    item -> item.rule_id == INITIALIZER_LAYOUT_RULE,
                    fixture.analysis.diagnostics)
            end

        end
    end
end

@testset "Odin initializer layout responses and count independence" begin
    base = OdinJuliaAnalysis.load_settings()
    @test base.rules[INITIALIZER_LAYOUT_RULE].response == Report
    @test base.function_metrics.odin_line_count_mode == :physical
    mktempdir() do root
        for response in (Ignore, Report, Warn, Fail)
            configuration = with_rules(base, Dict(INITIALIZER_LAYOUT_RULE =>
                RuleSetting(INITIALIZER_LAYOUT_RULE, true, response)))
            fixture = initializer_fixture(root, "value := Thing{x = 1}"; configuration)
            findings = filter(item -> item.rule_id == INITIALIZER_LAYOUT_RULE,
                fixture.analysis.diagnostics)
            @test length(findings) == 1
            @test only(findings).response == response
            @test only(findings).line == 4
            @test OdinJuliaAnalysis.analysis_exit_code(findings, [], configuration) ==
                (response == Fail ? 1 : 0)
        end
        configuration = with_rules(base, Dict(INITIALIZER_LAYOUT_RULE =>
            RuleSetting(INITIALIZER_LAYOUT_RULE, false, Fail)))
        valid = initializer_fixture(root, "value := Thing{\n    x = 1,\n}";
            configuration)
        @test valid.item.initializer_reduced_lines == 1
        @test !any(item -> item.rule_id == INITIALIZER_LAYOUT_RULE,
            valid.analysis.diagnostics)
        invalid = initializer_fixture(root, "value := Thing{\n x = 1,\n}"; configuration)
        @test invalid.item.initializer_reduced_lines == 3
        @test !any(item -> item.rule_id == INITIALIZER_LAYOUT_RULE,
            invalid.analysis.diagnostics)
    end
end

@testset "Odin enforcement thresholds, reports, and ordinary statistics" begin
    base = OdinJuliaAnalysis.load_settings()
    @test_throws ArgumentError OdinJuliaAnalysis.validate_function_metric_settings(
        initializer_metrics(:invalid))
    mktempdir() do root
        fixture = initializer_fixture(root,
            "value := Thing{\n    x = call(),\n    y = 1,\n    z = 2,\n}")
        physical = initializer_metrics(:physical)
        reduced = initializer_metrics(:fancy_initializers)
        aggregate = initializer_metrics(:aggregate_initializers)
        OdinJuliaAnalysis.validate_function_metric_settings(aggregate)
        @test OdinJuliaAnalysis.function_enforcement_lines(fixture.item, aggregate) == 2
        @test fixture.item.executable_lines == 5
        @test fixture.item.initializer_reduced_lines == 2
        diagnostics = OdinJuliaAnalysis.function_metric_diagnostics(
            [fixture.item], with_function_metrics(base, physical))
        @test only(diagnostics).rule_id == "ODIN-FUNCTION-LINES-WARN"
        diagnostics = OdinJuliaAnalysis.function_metric_diagnostics(
            [fixture.item], with_function_metrics(base, reduced))
        @test only(diagnostics).rule_id == "ODIN-FUNCTION-LINES-REPORT"
        @test only(diagnostics).measured == 2
        @test only(diagnostics).operation == "executable_lines"
        @test occursin("2 enforcement lines (5 ordinary code lines)",
            only(diagnostics).message)
        @test OdinJuliaAnalysis.function_status(
            fixture.item, base.thresholds, base.parameter_counts, reduced) == "review"
        selected = FunctionMetricSettings(
            ResponseThresholds(2, 3, 4), ResponseThresholds(2, 3, 4),
            reduced.julia_cyclomatic, reduced.odin_cyclomatic;
            odin_line_count_mode=:fancy_initializers)
        @test isempty(OdinJuliaAnalysis.function_metric_diagnostics(
            [fixture.item], with_function_metrics(base, selected)))
        @test OdinJuliaAnalysis.function_status(
            fixture.item, base.thresholds, base.parameter_counts, selected) ==
            "within thresholds"
        @test OdinJuliaAnalysis.function_status(
            fixture.item, base.thresholds, base.parameter_counts,
            FunctionMetricSettings(selected.julia_lines, selected.odin_lines,
                selected.julia_cyclomatic, selected.odin_cyclomatic)) == "exceeds maximum"
        nested = OdinJuliaAnalysis.nested_function(
            fixture.item, OdinJuliaAnalysis.AnalysisEvidence())
        @test nested.initializer_reduced_lines == 2
        @test nested.executable_lines == 5
        encoded = JSON.parse(JSON.json(nested))
        @test encoded.executable_lines == 5
        @test encoded.initializer_reduced_lines == 2
        stats = analyze_source_statistics(fixture.path)
        @test only(stats.functions).executable_lines == 5
        @test stats.file.average_executable_lines == 5
        @test !haskey(
            JSON.parse(JSON.json(stats)).functions[1], :initializer_reduced_lines)
        review = ReviewedComplexity(
            "initializer-lines", basename(fixture.path), :odin, "example",
            :executable_lines, "Fixture reduction must preserve review matching.")
        reviewed = with_function_metrics(base,
            initializer_metrics(:fancy_initializers; reviewed=[review]))
        OdinJuliaAnalysis.apply_reviewed_complexity!(
            diagnostics, root, [fixture.path], reviewed)
        @test only(diagnostics).reviewed_policy_id == "initializer-lines"
        stale = with_function_metrics(base, FunctionMetricSettings(
            selected.julia_lines, selected.odin_lines, selected.julia_cyclomatic,
            selected.odin_cyclomatic, [review]; odin_line_count_mode=:fancy_initializers))
        no_findings = OdinJuliaAnalysis.function_metric_diagnostics([fixture.item], stale)
        OdinJuliaAnalysis.apply_reviewed_complexity!(
            no_findings, root, [fixture.path], stale)
        @test only(no_findings).rule_id == "FUNCTION-METRIC-POLICY-DRIFT"
    end
end

@testset "Odin initializer report and statistics consistency" begin
    base = with_odin_build_targets(with_jet_entries(
        OdinJuliaAnalysis.load_settings(), JetEntryPoint[]), OdinBuildTarget[])
    mktempdir() do root
        initializer_fixture(root,
            "value := Thing{\n    x = 1,\n    y = 2,\n    z = 3,\n}")
        physical = OdinJuliaAnalysis.check_repository(root;
            configuration=with_function_metrics(base, initializer_metrics(:physical)))
        reduced = OdinJuliaAnalysis.check_repository(root;
            configuration=with_function_metrics(
                base, initializer_metrics(:aggregate_initializers)))
        @test physical.statistics.code.code_lines == reduced.statistics.code.code_lines
        @test physical.statistics.code.complexity_per_code_line ==
            reduced.statistics.code.complexity_per_code_line
        @test only(only(reduced.files).functions).initializer_reduced_lines == 1
        @test only(only(reduced.files).functions).executable_lines == 5
        @test any(item -> startswith(item.rule_id, "ODIN-FUNCTION-LINES"),
            physical.diagnostics)
        @test !any(item -> startswith(item.rule_id, "ODIN-FUNCTION-LINES"),
            reduced.diagnostics)
        output = IOBuffer()
        OdinJuliaAnalysis.write_markdown_report(output, reduced; comprehensive=true)
        markdown = String(take!(output))
        @test occursin("`aggregate_initializers`", markdown)
        @test occursin("| NLOC | Enforcement |", markdown)
        @test occursin("| 5 | 1 | 0 | 1 | - | yes | within thresholds |", markdown)
        @test occursin("| Functions within thresholds | 1 |", markdown)
        OdinJuliaAnalysis.write_report(output, reduced, "text"; color=:never)
        @test occursin("enforcement: aggregate_initializers", String(take!(output)))
        OdinJuliaAnalysis.write_report(output, reduced, "json")
        encoded = JSON.parse(String(take!(output)))
        @test encoded.function_metrics.odin_line_count_mode == "aggregate_initializers"
        @test encoded.files[1].functions[1].executable_lines == 5
        @test encoded.files[1].functions[1].initializer_reduced_lines == 1
    end

    @testset "Odin aggregate mode threshold selection" begin
        base = OdinJuliaAnalysis.load_settings()
        mktempdir() do root
            fixture = initializer_fixture(root, "value := []int{\n    1,\n    2,\n}")
            @test fixture.item.executable_lines == 4
            for mode in (:aggregate_initializers, :fancy_initializers)
                configuration = with_function_metrics(base, initializer_metrics(mode))
                @test isempty(OdinJuliaAnalysis.function_metric_diagnostics(
                    [fixture.item], configuration))
            end
            configuration = with_function_metrics(base, initializer_metrics(:physical))
            diagnostics = OdinJuliaAnalysis.function_metric_diagnostics(
                [fixture.item], configuration)
            @test only(diagnostics).measured == 4
            @test only(diagnostics).rule_id == "ODIN-FUNCTION-LINES-WARN"
        end
    end
end
