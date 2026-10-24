const CONTROL_BODY_RULES = (
    "ODIN-SINGLE-LINE-CONTROL-BODY",
    "ODIN-DO-CONTROL-BODY")

"""Analyze control formatting without unrelated fixture diagnostics."""
function control_body_diagnostics(root, path, configuration)
    return filter(
        item -> item.rule_id in CONTROL_BODY_RULES,
        OdinJuliaAnalysis.OdinEngine.analyze(root, [path], configuration).diagnostics)
end

@testset "Odin control body syntax and positions" begin
    cases = [
        ("if ready { publish() }", [(1, 10, 1)]),
        ("if ready {} else if other {} else {}", [(1, 10, 1), (1, 27, 1), (1, 35, 1)]),
        ("if ready {\n    publish()\n} else {}", [(3, 8, 1)]),
        ("if first &&\n    second { publish() }", [(2, 12, 1)]),
        ("for true { tick() }", [(1, 10, 1)]),
        ("for { tick() }", [(1, 5, 1)]),
        ("for i := 0; i < 3; i += 1 {}", [(1, 27, 1)]),
        ("for item in items { consume(item) }", [(1, 19, 1)]),
        ("for item, index in items {}", [(1, 26, 1)]),
        ("if ready { first(); second() }", [(1, 10, 1)]),
        ("if ready { for {} }", [(1, 10, 1), (1, 16, 1)]),
        ("if ready do publish()", [(1, 10, 2)]),
        ("if ready {} else do publish()", [(1, 10, 1), (1, 18, 2)]),
        ("for true do tick()", [(1, 10, 2)]),
        ("for item in items do consume(item)", [(1, 19, 2)]),
        ("for do tick()", [(1, 5, 2)]),
        ("if ready /* do { } */ do publish()", [(1, 23, 2)]),
        ("if ready do if other do publish()", [(1, 10, 2), (1, 22, 2)]),
        ("if ready do publish(\n    value)", [(1, 10, 2)]),
        ("if ready {\n    publish()\n} else if other {\n} else {\n}", []),
        ("for {\n}\nfor item in items {\n    consume(item)\n}", []),
        ("when enabled {} else {}", []),
        ("when enabled do publish()", []),
        ("switch value { case: }\ndefer publish()\n{}\nhelper := proc() {}", []),
        ("// if ready {} for do tick()\ntext := \"if ready {}\"\nraw := `for do tick()`", []),
        ("text := \"escaped \\\" if ready {}\"", []),
        ("when enabled { if ready {} }", [(1, 25, 1)]),
    ]
    configuration = OdinJuliaAnalysis.load_settings()
    mktempdir() do root
        path = joinpath(root, "control.odin")
        for (body, expected) in cases, newline in ("\n", "\r\n")
            source = "package fixture\n// Exercise control bodies.\nexample :: proc() {\n" *
                body * "\n}\n"
            write(path, replace(source, "\n" => newline))
            analysis = OdinJuliaAnalysis.OdinEngine.analyze(root, [path], configuration)
            @test !any(item -> item.rule_id == "ODIN-SYNTAX", analysis.diagnostics)
            diagnostics = filter(item -> item.rule_id in CONTROL_BODY_RULES,
                analysis.diagnostics)
            @test [(item.line - 3, item.column,
                findfirst(==(item.rule_id), CONTROL_BODY_RULES)) for item in diagnostics] ==
                expected
            @test all(item -> item.response == Report, diagnostics)
        end
    end
end

@testset "Odin control body configurable responses" begin
    base = OdinJuliaAnalysis.load_settings()
    mktempdir() do root
        path = joinpath(root, "control_test.odin")
        write(path,
            "package fixture\nexample :: proc() {\nif true {} else do return\n}\n")
        for rule in CONTROL_BODY_RULES
            @test base.rules[rule].enabled
            @test base.rules[rule].response == Report
            other = only(filter(!=(rule), CONTROL_BODY_RULES))
            for response in (Ignore, Report, Warn, Fail)
                configuration = with_rules(base, Dict(
                    rule => RuleSetting(rule, true, response),
                    other => RuleSetting(other, false, Fail)))
                diagnostics = control_body_diagnostics(root, path, configuration)
                @test length(diagnostics) == 1
                @test only(diagnostics).rule_id == rule
                @test only(diagnostics).response == response
                @test OdinJuliaAnalysis.analysis_exit_code(
                    diagnostics, [], configuration) ==
                        (response == Fail ? 1 : 0)
                ignored = OdinJuliaAnalysis.remove_ignored_diagnostics!(diagnostics)
                @test length(ignored.diagnostics) == (response == Ignore ? 1 : 0)
                @test length(diagnostics) == (response == Ignore ? 0 : 1)
            end
        end
        configuration = with_rules(base, Dict(
            rule => RuleSetting(rule, true, Fail) for rule in CONTROL_BODY_RULES))
        diagnostics = control_body_diagnostics(root, path, configuration)
        @test length(diagnostics) == 2
        @test OdinJuliaAnalysis.analysis_exit_code(diagnostics, [], configuration) == 1
    end
end
