const COMPOUND_DECLARATION_RULE = "ODIN-COMPOUND-LITERAL-DECLARATION"

"""Return only declaration-type placement diagnostics from an initializer fixture."""
function compound_declaration_findings(fixture)
    return filter(item -> item.rule_id == COMPOUND_DECLARATION_RULE,
        fixture.analysis.diagnostics)
end

@testset "Odin compound declaration responses and independence" begin
    base = OdinJuliaAnalysis.load_settings()
    @test base.rules[COMPOUND_DECLARATION_RULE].enabled
    @test base.rules[COMPOUND_DECLARATION_RULE].response == Report
    mktempdir() do root
        for response in (Ignore, Report, Warn, Fail), newline in ("\n", "\r\n")
            configuration = with_rules(base, Dict(COMPOUND_DECLARATION_RULE =>
                RuleSetting(COMPOUND_DECLARATION_RULE, true, response)))
            fixture = initializer_fixture(root, "value := Thing{}";
                configuration, newline)
            finding = only(compound_declaration_findings(fixture))
            @test finding.response == response
            @test finding.line == 4
            @test finding.column == 5
            @test occursin("name: Type = {...}", finding.message)
            @test OdinJuliaAnalysis.analysis_exit_code([finding], [], configuration) ==
                (response == Fail ? 1 : 0)
        end
        disabled = with_rules(base, Dict(COMPOUND_DECLARATION_RULE =>
            RuleSetting(COMPOUND_DECLARATION_RULE, false, Fail)))
        @test isempty(compound_declaration_findings(
            initializer_fixture(root, "value := Thing{}"; configuration=disabled)))
        inferred = initializer_fixture(root, "value := Thing{\n    x = 1,\n}")
        typed = initializer_fixture(root, "value: Thing = {\n    x = 1,\n}")
        @test length(compound_declaration_findings(inferred)) == 1
        @test isempty(compound_declaration_findings(typed))
        @test inferred.item.executable_lines == typed.item.executable_lines == 3
        @test inferred.item.initializer_reduced_lines ==
            typed.item.initializer_reduced_lines == 1
        inline = initializer_fixture(root, "value := Thing{x = 1}")
        @test length(compound_declaration_findings(inline)) == 1
        @test count(item -> item.rule_id == INITIALIZER_LAYOUT_RULE,
            inline.analysis.diagnostics) == 1
    end
end

@testset "Odin compound declaration expression boundaries" begin
    accepted = [
        "value: Thing = {}", "VALUE :: Thing{}", "a, b := Thing{}, Thing{}",
        "value := [?]int{1, 2}", "value := [2][?]int{}",
        "value := existing", "value := build()", "value := int(1)",
        "value := &Thing{}", "value := Thing{}.field", "value := []int{1}[0]",
        "call(Thing{})", "value = Thing{}", "return Thing{}",
    ]
    reported = [
        "value := Thing{}", "value := Point{1, 2}", "value := pkg.Thing{}",
        "value := (Thing{})", "value := Box(int){}", "value := []int{}",
        "value := [2]int{1, 2}", "value := [dynamic]int{}", "value := map[int]int{}",
        "value := matrix[2, 2]f32{}", "value := bit_set[Choice]{.A}",
        "value := struct {x: int}{1}",
        "value := Thing{values = [?]int{1, 2}}",
        "value := [len([?]int{1, 2})]int{1, 2}",
    ]
    mktempdir() do root
        for body in accepted
            @test isempty(compound_declaration_findings(initializer_fixture(root, body)))
        end
        for body in reported
            @test length(compound_declaration_findings(
                initializer_fixture(root, body))) == 1
        end
        path = joinpath(root, "global.odin")
        write(path, "package fixture\n@(rodata)\nvalue := Thing{}\n")
        analysis = OdinJuliaAnalysis.OdinEngine.analyze(root, [path])
        @test count(item -> item.rule_id == COMPOUND_DECLARATION_RULE,
            analysis.diagnostics) == 1
    end
end

"""Compile a complete policy fixture and expose compiler output on failure."""
function compile_compound_declaration(path; expected=true)
    output = IOBuffer()
    result = success(pipeline(
        `odin check $path -file -no-entry-point -vet -strict-style -disallow-do
        -warnings-as-errors`; stdout=output, stderr=output))
    text = String(take!(output))
    result == expected || @info "Odin compound declaration compiler output" text
    if !expected
        @test occursin("? can only be used in conjunction with compound literals", text)
    end
    return result
end

@testset "Odin compound declaration compiler equivalence" begin
    cases = [
        ("Point", "1"), ("Alias", ""), ("Distinct", ""),
        ("linalg.Vector2f32", "1, 2"), ("[2][2]int", "{1, 2}, {3, 4}"),
        ("[]int", "1, 2"), ("[dynamic]int", "1, 2"), ("map[int]int", "1 = 2"),
        ("matrix[2, 2]f32", "1, 2, 3, 4"), ("bit_set[Choice]", ".A"),
        ("struct {x: int}", "1"), ("Box(int)", "1"),
        ("[len([?]int{1, 2})]int", "1, 2"),
    ]
    header = """
        #+feature dynamic-literals
        package fixture
        import "core:math/linalg"
        Point :: struct {x: int}
        Alias :: Point
        Distinct :: distinct Point
        Box :: struct(\$T: typeid) {value: T}
        Choice :: enum {A, B}
        // Verify equivalent binding types.
        probe :: proc() {
        """
    mktempdir() do root
        path = joinpath(root, "equivalence.odin")
        declarations = map(enumerate(cases)) do (index, (type, elements))
            return """
                a$index := $type{$elements}
                b$index: $type = {$elements}
                #assert(type_of(a$index) == type_of(b$index))
                _ = a$index
                _ = b$index
                """
        end
        write(path, header * join(declarations, "\n") * "}\n")
        @test compile_compound_declaration(path)
        inferred = "package fixture\n// Preserve inferred lengths.\nprobe :: proc() {\n" *
            "    value := [?]int{1, 2}\n    _ = value\n}\n"
        write(path, inferred)
        @test compile_compound_declaration(path)
        write(path, replace(inferred, "value := [?]int{1, 2}" =>
            "value: [?]int = {1, 2}"))
        @test !compile_compound_declaration(path; expected=false)
    end
end
