"""Build metric settings with deliberately low thresholds for exemption tests."""
function flat_switch_metrics(; enabled=true, limit=6, mode=:physical,
    reviewed=ReviewedComplexity[])
    tiers = ResponseThresholds(3, 5, 7)
    return FunctionMetricSettings(tiers, tiers, tiers, tiers, reviewed;
        odin_line_count_mode=mode,
        odin_flat_switch_enabled=enabled,
        odin_flat_switch_max_outside_lines=limit)
end

"""Analyze one parser fixture without imposing compiler semantics on test expressions."""
function flat_switch_fixture(root, body; newline="\n", parameters="")
    path = joinpath(root, "switch.odin")
    source = "package fixture\n// Exercise flat-switch policy.\n" *
        "choose :: proc($parameters) {\n$body\n}\n"
    write(path, replace(source, "\n" => newline))
    analysis = OdinJuliaAnalysis.OdinEngine.analyze(root, [path])
    @test !any(item -> item.rule_id == "ODIN-SYNTAX", analysis.diagnostics)
    item = only(filter(item -> item.name == "choose", analysis.functions))
    return (; path, item, analysis)
end

"""Generate a switch that exceeds both line and cyclomatic thresholds."""
function large_flat_switch(; statement="return 1")
    cases = join(("case $index:\n    $statement\n" for index in 1:40))
    return "switch value {\n" * cases * "case:\n    return 0\n}"
end

@testset "Odin flat-switch structural eligibility" begin
    cases = [
        ("switch x {\ncase 1:\nreturn\ncase:\n}", true),
        ("#partial switch x {\ncase 1:\ncall()\n}", true),
        ("switch x in y {\ncase int:\nreturn x\ncase:\n}", true),
        ("#partial switch x in y {\ncase int:\nreturn x\n}", true),
        ("switch x {\ncase 1, 2:\n{}\ncase:\n{{return}}\n}", true),
        ("switch x {\ncase:\nreturn Thing{\n    x = 1,\n    y = 2,\n}\n}", true),
        ("switch x := call(); x {\ncase:\nreturn\n}", true),
        ("switch x {\ncase:\nreturn proc() {\nif true {\nreturn\n}\n}\n}", true),
        ("switch x {\ncase:\ncall(); other()\n}", false),
        ("switch x {\ncase:\n{{call(); other()}}\n}", false),
        ("switch x {\ncase:\nif true {\nreturn\n}\n}", false),
        ("switch x {\ncase:\nfor true {\ncall()\n}\n}", false),
        ("switch x {\ncase:\nwhen true {\ncall()\n}\n}", false),
        ("switch x {\ncase:\ndefer call()\n}", false),
        ("switch x {\ncase:\nfallthrough\n}", false),
        ("switch x {\ncase:\nswitch y {\ncase:\nreturn\n}\n}", false),
        ("if true {\nswitch x {\ncase:\nreturn\n}\n}", false),
        ("switch x {\ncase:\nreturn\n}\nswitch y {\ncase:\nreturn\n}", false),
        ("switch x && y {\ncase:\nreturn\n}", false),
        ("switch x {\ncase a || b:\nreturn\n}", false),
        ("switch x {\ncase:\nreturn a if b else c\n}", false),
        ("switch x {\ncase:\nreturn a when b else c\n}", false),
        ("switch x {\ncase:\nreturn a or_else b\n}", false),
        ("switch x {\ncase:\nreturn call() or_return\n}", false),
        ("switch x {\ncase:\nx &&= y\n}", false),
        ("x := a && b\nswitch x {\ncase:\nreturn\n}", false),
        ("switch x := a || b; x {\ncase:\nreturn\n}", false),
        ("call()", false),
    ]
    mktempdir() do root
        for (body, expected) in cases, newline in ("\n", "\r\n")
            @testset "$body ($newline)" begin
                fixture = flat_switch_fixture(root, body; newline)
                @test fixture.item.flat_switch_candidate == expected
            end
        end
    end
end

@testset "Odin flat-switch outside-line boundaries and settings" begin
    base = OdinJuliaAnalysis.load_settings()
    @test !base.function_metrics.odin_flat_switch_enabled
    @test base.function_metrics.odin_flat_switch_max_outside_lines == 6
    @test_throws ArgumentError OdinJuliaAnalysis.validate_function_metric_settings(
        flat_switch_metrics(limit=-1))
    @test OdinJuliaAnalysis.validate_function_metric_settings(
        flat_switch_metrics(limit=0)) === nothing
    mktempdir() do root
        for count in (0, 6, 7), mode in (:physical, :aggregate_initializers)
            setup = join(("call()\n" for _ in 1:count))
            fixture = flat_switch_fixture(root, setup * large_flat_switch())
            @test fixture.item.flat_switch_candidate
            @test fixture.item.flat_switch_outside_lines == count
            settings = flat_switch_metrics(; mode)
            @test OdinJuliaAnalysis.flat_switch_exempt(fixture.item, settings) == (count <= 6)
            diagnostics = OdinJuliaAnalysis.function_metric_diagnostics(
                [fixture.item], with_function_metrics(base, settings))
            @test length(diagnostics) == (count <= 6 ? 0 : 2)
            @test !OdinJuliaAnalysis.flat_switch_exempt(
                fixture.item, flat_switch_metrics(enabled=false))
            @test OdinJuliaAnalysis.flat_switch_exempt(
                fixture.item, flat_switch_metrics(limit=0)) == (count == 0)
        end
        fixture = flat_switch_fixture(root,
            "// setup comment\nx: Thing = {\n    a = 1,\n    b = 2,\n}\n\n" *
            large_flat_switch() * "\nreturn x")
        @test fixture.item.flat_switch_outside_lines == 4
        @test fixture.item.flat_switch_candidate
    end
end

@testset "Odin flat-switch enforcement, reports, and waiver drift" begin
    base = with_odin_build_targets(with_jet_entries(
        OdinJuliaAnalysis.load_settings(), JetEntryPoint[]), OdinBuildTarget[])
    mktempdir() do root
        fixture = flat_switch_fixture(root, large_flat_switch())
        disabled = with_function_metrics(base, flat_switch_metrics(enabled=false))
        enabled = with_function_metrics(base, flat_switch_metrics())
        ordinary = OdinJuliaAnalysis.check_repository(root; configuration=disabled)
        exempt = OdinJuliaAnalysis.check_repository(root; configuration=enabled)
        raw = only(only(ordinary.files).functions)
        item = only(only(exempt.files).functions)
        @test raw.executable_lines > 65
        @test raw.cyclomatic_complexity > 15
        @test item.flat_switch_candidate
        @test (raw.executable_lines, raw.cyclomatic_complexity) ==
            (item.executable_lines, item.cyclomatic_complexity)
        @test ordinary.statistics.code == exempt.statistics.code
        @test length(OdinJuliaAnalysis.function_metric_diagnostics([raw], disabled)) == 2
        @test isempty(OdinJuliaAnalysis.function_metric_diagnostics([item], enabled))
        @test OdinJuliaAnalysis.function_status(item, base.thresholds,
            base.parameter_counts, enabled.function_metrics) == "within thresholds"
        @test OdinJuliaAnalysis.function_status(raw, base.thresholds,
            base.parameter_counts, disabled.function_metrics) == "exceeds maximum"
        output = IOBuffer()
        OdinJuliaAnalysis.write_report(output, exempt, "json")
        encoded = JSON.parse(String(take!(output)))
        @test encoded.schema_version == "4.3.0"
        @test encoded.files[1].functions[1].flat_switch_candidate
        @test encoded.files[1].functions[1].executable_lines == raw.executable_lines
        @test only(encoded.function_metric_exemptions).name == "choose"
        @test only(encoded.function_metric_exemptions).outside_lines == 0
        @test !isempty(only(encoded.function_metric_exemptions).reason)
        OdinJuliaAnalysis.write_report(output, exempt, "text"; color=:never)
        @test occursin("Flat-switch policy exempts NLOC and CC", String(take!(output)))
        OdinJuliaAnalysis.write_markdown_report(output, exempt; comprehensive=true)
        markdown = String(take!(output))
        @test occursin("flat-switch NLOC/CC exempt (0 outside lines)", markdown)
        @test occursin("| Functions within thresholds | 1 |", markdown)
        stats = OdinJuliaAnalysis.analyze_source_statistics(fixture.path)
        @test only(stats.functions).executable_lines == raw.executable_lines
        @test only(stats.functions).cyclomatic_complexity == raw.cyclomatic_complexity
        review = ReviewedComplexity("stale-flat-switch", "switch.odin", :odin, "choose",
            :cyclomatic_complexity, "A former switch complexity waiver.")
        reviewed = with_function_metrics(base, flat_switch_metrics(reviewed=[review]))
        diagnostics = OdinJuliaAnalysis.function_metric_diagnostics([item], reviewed)
        OdinJuliaAnalysis.apply_reviewed_complexity!(
            diagnostics, root, [fixture.path], reviewed)
        @test only(diagnostics).rule_id == "FUNCTION-METRIC-POLICY-DRIFT"

        mutated = flat_switch_fixture(root,
            replace(large_flat_switch(), "return 1" => "call(); return 1"; count=1))
        @test !mutated.item.flat_switch_candidate
        @test length(OdinJuliaAnalysis.function_metric_diagnostics(
            [mutated.item], enabled)) == 2
        inline = flat_switch_fixture(root,
            replace(large_flat_switch(), "case 1:\n    " => "case 1: "))
        @test inline.item.flat_switch_candidate
        @test any(item -> item.rule_id == "ODIN-CASE-BODY-PLACEMENT",
            inline.analysis.diagnostics)
        parameters = flat_switch_fixture(root, large_flat_switch();
            parameters="a, b, c, d, e, f, g, h, i: int")
        @test parameters.item.flat_switch_candidate
        @test any(item -> startswith(item.rule_id, "ODIN-PARAMETERS"),
            parameters.analysis.diagnostics)
        @test OdinJuliaAnalysis.function_status(parameters.item, base.thresholds,
            base.parameter_counts, enabled.function_metrics) == "exceeds maximum"
    end
end
