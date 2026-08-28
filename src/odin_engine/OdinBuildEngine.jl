module OdinBuildEngine

using ..OdinJuliaAnalysis: Diagnostic
using ..OdinJuliaAnalysis: EffectiveSettings
using ..OdinJuliaAnalysis: Ignore
using ..OdinJuliaAnalysis: OdinBuildAnalysis
using ..OdinJuliaAnalysis: configured_diagnostic

export analyze

const OUTPUT_DIRECTORY = joinpath(".build", "analysis", "odin")

"""Run every configured analytical Odin build and retain complete command results."""
function analyze(root::String, configuration::EffectiveSettings)
    diagnostics = Diagnostic[]
    builds = OdinBuildAnalysis[]
    output_directory = joinpath(root, OUTPUT_DIRECTORY)
    mkpath(output_directory)

    for target in configuration.odin_build.targets
        build = run_build_target(root, target)
        push!(builds, build)
        build.exit_code == 0 && continue
        diagnostic = Diagnostic(
            "ODIN-BUILD-FAILED",
            Ignore,
            target.input,
            1,
            1,
            "Analytical Odin build `$(target.id)` exited with code $(build.exit_code).",
            build.exit_code,
            0,
            "odin-build")
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    return (; diagnostics, builds)
end

"""Execute one analytical Odin build and retain its complete result."""
function run_build_target(root, target)
    relative_output = joinpath(OUTPUT_DIRECTORY, target.output_name)
    rm(joinpath(root, relative_output); force=true)
    arguments = vcat(
        ["odin", "build", target.input, "-out:$relative_output"],
        target.flags)
    if target.include_julia_linker_flags
        push!(arguments, "-extra-linker-flags:$(resolve_julia_linker_flags())")
    end
    output = IOBuffer()
    errors = IOBuffer()
    process = run(pipeline(
        ignorestatus(Cmd(Cmd(arguments); dir=root)),
        stdout=output,
        stderr=errors))
    exit_code = process.exitcode
    return OdinBuildAnalysis(
        target.id,
        target.input,
        relative_output,
        arguments,
        copy(target.flags),
        exit_code == 0 ? "passed" : "failed",
        exit_code,
        String(take!(output)),
        String(take!(errors)))
end

"""Resolve Julia linker flags via julia-config.jl, matching the tools/make.jl build."""
function resolve_julia_linker_flags()
    Sys.iswindows() && error(
        "Julia linker flags for analytical Odin builds are not supported on Windows.")
    julia_config_path = joinpath(
        Sys.BINDIR, Base.DATAROOTDIR, "julia", "julia-config.jl")
    isfile(julia_config_path) || error("Could not resolve julia-config.jl path.")
    output = IOBuffer()
    process = run(pipeline(
        ignorestatus(Cmd(vcat(
            Base.julia_cmd().exec, [
                julia_config_path,
                "--ldflags",
                "--ldlibs",
            ]))),
        stdout=output,
        stderr=devnull))
    process.exitcode == 0 || error("Failed to query Julia linker flags.")
    return join(split(String(take!(output))), " ")
end

end