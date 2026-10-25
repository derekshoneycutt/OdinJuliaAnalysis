const CASE_BODY_RULE = "ODIN-CASE-BODY-PLACEMENT"

"""Analyze case placement without unrelated fixture diagnostics."""
function case_body_diagnostics(root, path, configuration)
    analysis = OdinJuliaAnalysis.OdinEngine.analyze(root, [path], configuration)
    @test !any(item -> item.rule_id == "ODIN-SYNTAX", analysis.diagnostics)
    return filter(item -> item.rule_id == CASE_BODY_RULE, analysis.diagnostics)
end

@testset "Odin case body syntax and positions" begin
    cases = [
        ("switch value {\ncase 1: return\n}", [(2, 9)]),
        ("switch value {\ncase: return\n}", [(2, 7)]),
        ("switch value {\ncase 1: first(); second()\ncase: return\n}", [(2, 9), (3, 7)]),
        ("switch value {\ncase 1: { return }\n}", [(2, 11)]),
        ("switch value {\ncase 1: { { return } }\n}", [(2, 13)]),
        ("switch value {\ncase 1: {}; return\n}", [(2, 13)]),
        ("switch value {\ncase 1: { {} }; return\n}", [(2, 17)]),
        ("switch value {\ncase 1,\n    2: return\n}", [(3, 8)]),
        ("switch value {\ncase\n    1: return\n}", [(3, 8)]),
        ("switch value {\ncase 1: /* inline */ return\n}", [(2, 22)]),
        ("switch value {\ncase 1: {\nreturn\n}\n}", []),
        ("switch value {\ncase 1: { {\nreturn\n} }\n}", []),
        ("switch value {\ncase 1: {}\ncase 2:\ncase:\n}", []),
        ("switch value {\ncase 1: { {} }\ncase: // return\n/* return */\n}", []),
        ("switch value {\ncase 1,\n    2:\nreturn\n}", []),
        ("switch value {\ncase 1:\nreturn\n}", []),
        ("#partial switch value {\ncase 1: return\ncase: return\n}", [(2, 9), (3, 7)]),
        ("switch item in value {\ncase int: return\ncase: return\n}", [(2, 11), (3, 7)]),
        ("#partial switch item in value {\ncase int: { return }\n}", [(2, 13)]),
        ("switch value {\ncase 1: if true {\nreturn\n}\n}", [(2, 9)]),
        ("switch value {\ncase 1:\nif true { return }\n}", []),
        ("switch value {\ncase 1:\nswitch other {\ncase: return\n}\n}", [(4, 7)]),
        ("// switch value { case: return }\ntext := \"case 1: return\"\n" *
            "raw := `case: { return }`\n/* switch value { case: return } */", []),
    ]
    configuration = OdinJuliaAnalysis.load_settings()
    mktempdir() do root
        path = joinpath(root, "case_test.odin")
        for (body, expected) in cases, newline in ("\n", "\r\n")
            source = "package fixture\n// Exercise case bodies.\nexample :: proc() {\n" *
                body * "\n}\n"
            write(path, replace(source, "\n" => newline))
            diagnostics = case_body_diagnostics(root, path, configuration)
            @test [(item.line - 3, item.column) for item in diagnostics] == expected
            @test all(item -> item.response == Report, diagnostics)
        end
    end
end

@testset "Odin case body configurable responses" begin
    base = OdinJuliaAnalysis.load_settings()
    @test base.rules[CASE_BODY_RULE].enabled
    @test base.rules[CASE_BODY_RULE].response == Report
    mktempdir() do root
        path = joinpath(root, "case_test.odin")
        write(path, "package fixture\nexample :: proc() {\nswitch value {\ncase: return\n}\n}\n")
        for response in (Ignore, Report, Warn, Fail)
            configuration = with_rules(base, Dict(
                CASE_BODY_RULE => RuleSetting(CASE_BODY_RULE, true, response)))
            diagnostics = case_body_diagnostics(root, path, configuration)
            @test length(diagnostics) == 1
            @test only(diagnostics).response == response
            @test (only(diagnostics).line, only(diagnostics).column) == (4, 7)
            @test OdinJuliaAnalysis.analysis_exit_code(diagnostics, [], configuration) ==
                (response == Fail ? 1 : 0)
            ignored = OdinJuliaAnalysis.remove_ignored_diagnostics!(diagnostics)
            @test length(ignored.diagnostics) == (response == Ignore ? 1 : 0)
            @test length(diagnostics) == (response == Ignore ? 0 : 1)
        end
        configuration = with_rules(base, Dict(
            CASE_BODY_RULE => RuleSetting(CASE_BODY_RULE, false, Fail)))
        @test isempty(case_body_diagnostics(root, path, configuration))
    end
end
