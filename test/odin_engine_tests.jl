@testset "Odin syntax" begin
    mktempdir() do root
        path = joinpath(root, "broken.odin")
        write(path, "package fixture\n\nbroken :: proc( {\n")
        diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(root, [path])
        @test only(diagnostics).rule_id == "ODIN-SYNTAX"
        @test only(diagnostics).source == "odin-ast"
    end
end

@testset "Odin procedure documentation" begin
    mktempdir() do root
        path = joinpath(root, "documentation.odin")
        write(path, """
            package fixture

            // Return without performing work.
            documented :: proc() {}

            undocumented :: proc() {}

            // Exercise local procedure declarations.
            container :: proc() {
                // Return from the local helper.
                local_documented := proc() {}
                local_undocumented := proc() {}
            }
            """)
        diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(root, [path])
        missing_docs = filter(
            item -> item.rule_id == "ODIN-DOC-MISSING",
            diagnostics)
        @test [item.line for item in missing_docs] == [6, 12]
        @test [item.subject for item in missing_docs] == [
            "undocumented",
            "local_undocumented",
        ]
        @test all(item -> item.response == Fail, missing_docs)

        template_configuration = with_documentation(
            OdinJuliaAnalysis.load_settings(),
            DocumentationSettings(r"\S", r"(?m)^Parameters:$"))
        template_configuration = with_rules(template_configuration, Dict(
            "ODIN-DOC-MISSING" => RuleSetting(
                "ODIN-DOC-MISSING", true, Report)))
        write(path, """
            package fixture

            // Summary only.
            missing_parameters :: proc(value: int) {}

            // Summary.
            // Parameters:
            // - value: Ignored value.
            documented_parameters :: proc(value: int) {}

            //
            empty_documentation :: proc() {}
            """)
        template_diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
            root, [path], template_configuration)
        template_findings = filter(
            item -> item.rule_id == "ODIN-DOC-MISSING", template_diagnostics)
        @test [item.subject for item in template_findings] == [
            "missing_parameters",
            "empty_documentation",
        ]
        @test all(item -> item.response == Report, template_findings)
    end
end

@testset "Odin separator spacing syntax boundaries" begin
    cases = [
        ("value : int", ["ODIN-DECLARATION-COLON-SPACING"]),
        ("first, second : int", ["ODIN-DECLARATION-COLON-SPACING"]),
        ("value: int", String[]),
        ("helper :: proc(value :=1) {}", ["ODIN-INFERRED-DECLARATION-SPACING"]),
        ("helper :: proc(locale := \"en-US\") {}", String[]),
        ("helper :: proc(x := f32(0)) {}", String[]),
        ("helper :: proc(x: f32 = 0) {}", String[]),
        ("helper :: proc(locale:= \"en-US\") {}",
            ["ODIN-INFERRED-DECLARATION-SPACING"]),
        ("helper :: proc(x: f32=0) {}", ["ODIN-EQUALS-SPACING"]),
        ("helper :: proc(x : = 0) {}", ["ODIN-INFERRED-DECLARATION-SPACING"]),
        ("helper :: proc() -> (result : int) {}", ["ODIN-DECLARATION-COLON-SPACING"]),
        ("value : = 1", ["ODIN-INFERRED-DECLARATION-SPACING"]),
        ("VALUE : /* split */ : 1", ["ODIN-CONSTANT-DECLARATION-SPACING"]),
        ("value : int : 1", ["ODIN-DECLARATION-COLON-SPACING"]),
        ("value /* comment */:int", ["ODIN-DECLARATION-COLON-SPACING"]),
        ("value:\n    int", String[]),
        ("value: /* comment */ int", String[]),
        ("value += 1\ncheck := value == 1\nother := value != 2", String[]),
        ("text := \"value : int\"\nraw := `NAME::1`", String[]),
        ("switch value { case 1: }\npart := values[1:2]", String[]),
        ("δοκιμή : int", ["ODIN-DECLARATION-COLON-SPACING"]),
    ]
    configuration = OdinJuliaAnalysis.load_settings()
    mktempdir() do root
        path = joinpath(root, "boundaries.odin")
        for (body, expected) in cases, newline in ("\n", "\r\n")
            write(path, replace(
                "package fixture\n// Exercise separator boundaries.\nexample :: proc() {\n" *
                body * "\n}\n", "\n" => newline))
            analysis = OdinJuliaAnalysis.OdinEngine.analyze(root, [path], configuration)
            @test !any(item -> item.rule_id == "ODIN-SYNTAX", analysis.diagnostics)
            spacing = filter(item -> endswith(item.rule_id, "-SPACING"),
                analysis.diagnostics)
            @test [item.rule_id for item in spacing] == expected
        end
    end
end

@testset "Odin separator spacing policies" begin
    mktempdir() do root
        path = joinpath(root, "spacing.odin")
        write(path, """
            package fixture

            typed : int=1
            typed_constant: int: 2
            inferred:= 3
            CONSTANT:: 4
            wrapped:
                int = 5
            commented /* before */: /* after */ int = 6

            example :: proc() {
                assigned=7
                consume(named=8)
                Point{x=9}
                multiple:  int = 10
                tabbed:\tint = 11
                before_commented /* before */:int = 12
            }
            """)
        configuration = OdinJuliaAnalysis.load_settings()
        overridden = with_rules(configuration, Dict(
            "ODIN-DECLARATION-COLON-SPACING" => RuleSetting(
                "ODIN-DECLARATION-COLON-SPACING", true, Warn),
            "ODIN-EQUALS-SPACING" => RuleSetting(
                "ODIN-EQUALS-SPACING", true, Fail),
            "ODIN-INFERRED-DECLARATION-SPACING" => RuleSetting(
                "ODIN-INFERRED-DECLARATION-SPACING", true, Report),
            "ODIN-CONSTANT-DECLARATION-SPACING" => RuleSetting(
                "ODIN-CONSTANT-DECLARATION-SPACING", true, Ignore)))
        diagnostics = OdinJuliaAnalysis.OdinEngine.analyze(
            root, [path], overridden).diagnostics
        @test isempty(filter(item -> item.rule_id == "ODIN-SYNTAX", diagnostics))
        spacing = filter(
            item -> endswith(item.rule_id, "-SPACING"), diagnostics)
        @test all(item -> item.source == "odin-ast-spacing", spacing)
        @test all(item -> item.path == "spacing.odin", spacing)
        @test [item.rule_id for item in spacing] == [
            "ODIN-DECLARATION-COLON-SPACING",
            "ODIN-EQUALS-SPACING",
            "ODIN-CONSTANT-DECLARATION-SPACING",
            "ODIN-INFERRED-DECLARATION-SPACING",
            "ODIN-CONSTANT-DECLARATION-SPACING",
            "ODIN-EQUALS-SPACING",
            "ODIN-EQUALS-SPACING",
            "ODIN-EQUALS-SPACING",
            "ODIN-DECLARATION-COLON-SPACING",
            "ODIN-DECLARATION-COLON-SPACING",
            "ODIN-DECLARATION-COLON-SPACING",
        ]
        @test [item.response for item in spacing] == [
            Warn, Fail, Ignore, Report, Ignore, Fail, Fail, Fail,
            Warn, Warn, Warn]
        @test spacing[1].line == 3
        @test spacing[1].column == 7
        @test occursin("before expects 0 ASCII space(s)", spacing[1].message)
        @test occursin("operator punctuation must be adjacent", spacing[3].message) ==
            false
        @test occursin("typed constant value", spacing[3].message)
        @test all(item -> item.line ∉ (8, 9), spacing)
        single_side = only(filter(item -> item.line == 17, spacing))
        @test occursin("after expects 1 ASCII space(s)", single_side.message)
        @test !occursin("before expects", single_side.message)

        exact_after = SeparatorSpacing(
            HorizontalSpacing(nothing), HorizontalSpacing(2))
        unrestricted_side = SeparatorSpacing(
            HorizontalSpacing(nothing), HorizontalSpacing(nothing))
        exact_configuration = with_odin_spacing(
            configuration,
            OdinSpacingSettings(
                exact_after,
                unrestricted_side,
                unrestricted_side,
                unrestricted_side))
        exact_diagnostics = OdinJuliaAnalysis.OdinEngine.analyze(
            root, [path], exact_configuration).diagnostics
        exact_colons = filter(
            item -> item.rule_id == "ODIN-DECLARATION-COLON-SPACING",
            exact_diagnostics)
        @test [item.line for item in exact_colons] == [3, 4, 16, 17]
        @test occursin("other horizontal whitespace", only(filter(
            item -> item.line == 16, exact_colons)).message)

        unrestricted = SeparatorSpacing(
            HorizontalSpacing(nothing), HorizontalSpacing(nothing))
        unrestricted_configuration = with_odin_spacing(
            configuration,
            OdinSpacingSettings(
                unrestricted, unrestricted, unrestricted, unrestricted))
        unrestricted_diagnostics = OdinJuliaAnalysis.OdinEngine.analyze(
            root, [path], unrestricted_configuration).diagnostics
        @test isempty(filter(
            item -> endswith(item.rule_id, "-SPACING"),
            unrestricted_diagnostics))

        disabled_configuration = with_rules(configuration, Dict(
            "ODIN-EQUALS-SPACING" => RuleSetting(
                "ODIN-EQUALS-SPACING", false, Ignore)))
        disabled_diagnostics = OdinJuliaAnalysis.OdinEngine.analyze(
            root, [path], disabled_configuration).diagnostics
        @test isempty(filter(
            item -> item.rule_id == "ODIN-EQUALS-SPACING",
            disabled_diagnostics))
    end
end

@testset verbose=TEST_VERBOSE "Odin allocation analysis" begin
    mktempdir() do root
        path = joinpath(root, "allocations.odin")
        write(path, """
            package fixture

            import "core:mem/heap"
            import vmem "core:mem/virtual"

            allocations :: proc(custom_allocator: runtime.Allocator) {
                arena: vmem.Arena
                _ = vmem.arena_init_static(&arena)
                _ = new(int)
                _ = new(int, context.allocator)
                _ = new(int, context.temp_allocator)
                _ = new(int, heap.allocator())
                _ = new(int, custom_allocator)
                _ = new(int, select_allocator())
                _ = new(int, allocator = context.temp_allocator)
                values := make([dynamic]int)
                values = make([dynamic]int, 0, context.allocator)
                append(&values, 1)
            }
            """)
        diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(root, [path])
        allocations = filter(
            item -> startswith(item.rule_id, "ODIN-ALLOCATION-"),
            diagnostics)
        @test [item.rule_id for item in allocations] == [
            "ODIN-ALLOCATION-ARENA",
            "ODIN-ALLOCATION-IMPLICIT",
            "ODIN-ALLOCATION-CONTEXT",
            "ODIN-ALLOCATION-TEMPORARY",
            "ODIN-ALLOCATION-HEAP",
            "ODIN-ALLOCATION-CUSTOM",
            "ODIN-ALLOCATION-UNKNOWN",
            "ODIN-ALLOCATION-TEMPORARY",
            "ODIN-ALLOCATION-IMPLICIT",
            "ODIN-ALLOCATION-CONTEXT",
            "ODIN-ALLOCATION-DYNAMIC-GROWTH",
        ]
        @test [item.response for item in allocations] == [
            Warn,
            Warn,
            Warn,
            Report,
            Warn,
            Report,
            Fail,
            Report,
            Warn,
            Warn,
            Report,
        ]
        @test allocations[6].allocator_source == "custom_allocator"
        @test allocations[7].allocator_source == "select_allocator()"
        @test allocations[11].certainty == "potential"
        @test all(item -> item.procedure == "allocations", allocations)
        @test allocations[1].allocation_target == "arena"
        @test allocations[2].allocation_target == "int"
        @test allocations[11].allocation_target == "values"
        @test all(item -> item.source == "odin-ast", allocations)
    end
end

@testset verbose=TEST_VERBOSE "owned allocator source patterns" begin
    mktempdir() do root
        path = joinpath(root, "owner.odin")
        write(path, """
            package fixture

            // Allocate through the owner-selected backing domain.
            allocate :: proc(owner: Owner) {
                value := new(int, owner.backing_allocator)
            }
            """)
        configuration = OdinJuliaAnalysis.load_settings()
        configuration = with_allocator_source_patterns(configuration, [
            AllocatorSourcePattern("owner.backing_allocator", :custom)])
        allocations = filter(
            item -> startswith(item.rule_id, "ODIN-ALLOCATION-"),
            OdinJuliaAnalysis.OdinEngine.analyze(
                root, [path], configuration).diagnostics)
        @test length(allocations) == 1
        @test only(allocations).rule_id == "ODIN-ALLOCATION-CUSTOM"
        @test only(allocations).allocator_source == "owner.backing_allocator"
        @test only(allocations).allocation_target == "int"
        @test only(allocations).procedure == "allocate"
    end
end

@testset verbose=TEST_VERBOSE "allocation filename response overrides" begin
    configuration = OdinJuliaAnalysis.load_settings()
    override = AllocationResponseOverride(r"_test\.odin$", :context, Ignore)
    configuration = with_allocation_response_overrides(configuration, [override])
    mktempdir() do root
        test_path = joinpath(root, "allocation_test.odin")
        source_path = joinpath(root, "allocation.odin")
        fixture = """
            package fixture

            // Allocate fixture values.
            allocate :: proc() {
                _ = new(int, context.allocator)
                _ = new(int)
            }
            """
        write(test_path, fixture)
        write(source_path, fixture)
        test_diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
            root, [test_path], configuration)
        source_diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
            root, [source_path], configuration)
        test_allocations = filter(
            item -> startswith(item.rule_id, "ODIN-ALLOCATION-"),
            test_diagnostics)
        source_allocations = filter(
            item -> startswith(item.rule_id, "ODIN-ALLOCATION-"),
            source_diagnostics)
        @test [item.response for item in test_allocations] == [Ignore, Warn]
        @test [item.response for item in source_allocations] == [Warn, Warn]
    end
end

@testset verbose=TEST_VERBOSE "reviewed allocation policies" begin
    configuration = OdinJuliaAnalysis.load_settings()
    mktempdir() do root
        path = joinpath(root, "reviewed.odin")
        write(path, """
            package fixture

            // Allocate reviewed values.
            reviewed :: proc() {
                _ = new(int)
                _ = new(int)
            }
            """)
        policy_path = relpath(path, root)
        policy = ReviewedAllocationPolicy(
            "reviewed-new",
            policy_path,
            "reviewed",
            :implicit,
            "Fixture allocation is reviewed.";
            operation="new",
            target="int",
            response=Report,
            minimum_matches=2,
            maximum_matches=2)
        reviewed_configuration = with_allocation_policies(
            configuration,
            [policy])
        diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
            root,
            [path],
            reviewed_configuration)
        allocations = filter(
            item -> item.rule_id == "ODIN-ALLOCATION-IMPLICIT",
            diagnostics)
        @test length(allocations) == 2
        @test all(item -> item.response == Report, allocations)
        @test all(item -> item.reviewed_policy_id == "reviewed-new", allocations)
        @test all(
            item -> item.reviewed_policy_reason == policy.reason,
            allocations)
        @test !any(
            item -> item.rule_id == "ODIN-ALLOCATION-POLICY-DRIFT",
            diagnostics)

        missing = ReviewedAllocationPolicy(
            "missing-new",
            policy_path,
            "reviewed",
            :implicit,
            "Selector intentionally misses.";
            operation="new",
            target="string")
        missing_diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
            root,
            [path],
            with_allocation_policies(configuration, [missing]))
        missing_drift = filter(
            item -> item.rule_id == "ODIN-ALLOCATION-POLICY-DRIFT",
            missing_diagnostics)
        @test length(missing_drift) == 1
        @test only(missing_drift).response == Fail
        @test occursin("found 0", only(missing_drift).message)

        excess = ReviewedAllocationPolicy(
            "excess-new",
            policy_path,
            "reviewed",
            :implicit,
            "Only one allocation was expected.";
            operation="new",
            target="int")
        excess_diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
            root,
            [path],
            with_allocation_policies(configuration, [excess]))
        excess_drift = filter(
            item -> item.rule_id == "ODIN-ALLOCATION-POLICY-DRIFT",
            excess_diagnostics)
        @test length(excess_drift) == 1
        @test occursin("found 2", only(excess_drift).message)

        ambiguous = ReviewedAllocationPolicy(
            "ambiguous-new",
            policy_path,
            "reviewed",
            :implicit,
            "Overlapping selector.";
            operation="new",
            target="int",
            minimum_matches=2,
            maximum_matches=2)
        ambiguous_diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
            root,
            [path],
            with_allocation_policies(configuration, [policy, ambiguous]))
        ambiguous_drift = filter(
            item -> item.rule_id == "ODIN-ALLOCATION-POLICY-DRIFT",
            ambiguous_diagnostics)
        @test length(ambiguous_drift) == 2
        @test all(
            item -> occursin("multiple reviewed policies", item.message),
            ambiguous_drift)
    end

end

@testset verbose=TEST_VERBOSE "Odin closing parenthesis placement" begin
    mktempdir() do root
        @testset "accepts close beside final parameter" begin
            path = joinpath(root, "valid.odin")
            write(
                path,
                "package fixture\n\n" *
                "// Return the input value.\n" *
                "value :: proc(\n    input: int) {}\n")
            @test isempty(OdinJuliaAnalysis.OdinEngine.check_syntax(root, [path]))
        end

        @testset "rejects isolated close" begin
            path = joinpath(root, "invalid.odin")
            write(
                path,
                "package fixture\n\nvalue :: proc(\n    input: int\n) {}\n")
            diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(root, [path])
            closing = filter(
                item -> item.rule_id == "ODIN-CLOSING-PAREN-PLACEMENT",
                diagnostics)
            @test only(closing).line == 5
            @test only(closing).response == Fail
        end
    end
end

@testset "native Odin engine" begin
    build_directory = joinpath(
        OdinJuliaAnalysis.ANALYSIS_ROOT,
        ".build")
    mkpath(build_directory)
    flags = [
        "-vet",
        "-strict-style",
        "-disallow-do",
        "-warnings-as-errors",
        "-error-pos-style:unix",
        "-out:" * joinpath(build_directory,
            Sys.iswindows() ? "odin-engine-tests.exe" : "odin-engine-tests"),
    ]
    command = Cmd(
        Cmd(vcat(["odin", "test", joinpath(
            OdinJuliaAnalysis.ANALYSIS_ROOT, "odin_engine")], flags));
        dir=build_directory)
    output = IOBuffer()
    process = run(pipeline(ignorestatus(command), stdout=output, stderr=output))
    text = String(take!(output))
    @test process.exitcode == 0
    @test occursin("Finished 6 tests", text)
end
