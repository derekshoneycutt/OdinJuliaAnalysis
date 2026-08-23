using OdinJuliaAnalysis

import OdinJuliaAnalysis: analyze_extension, extension_api_version, extension_id
import OdinJuliaAnalysis: extension_phases, extension_rules

struct SampleExtension <: AnalysisExtension end

"""Return the stable sample extension identity."""
extension_id(_extension::SampleExtension) = "hello-world-sample"

"""Declare compatibility with the current nested analysis context."""
extension_api_version(_extension::SampleExtension) = EXTENSION_API_VERSION

"""Register the sample's cross-language repository rule."""
function extension_rules(_extension::SampleExtension)
    return RuleDefinition[
        RuleDefinition(
            "SAMPLE-BOTH-LANGUAGES",
            "common",
            "Sample Repository > Language Coverage",
            "repository inventory",
            "high",
            "default",
            false),
    ]
end

"""Run the sample rule after core repository analysis is complete."""
extension_phases(_extension::SampleExtension) = Set((AfterRepositoryAnalysis,))

"""Require both sample languages and publish their inventory as an artifact."""
function analyze_extension(
    extension::SampleExtension,
    context::AnalysisContext,
    _prior_results)
    languages = Set(file.language for file in context.files)
    missing = sort!(collect(setdiff(Set(("julia", "odin")), languages)))
    diagnostics = isempty(missing) ? Diagnostic[] : [
        Diagnostic(
            "SAMPLE-BOTH-LANGUAGES",
            Report,
            ".",
            1,
            1,
            "Sample is missing source languages: $(join(missing, ", "))",
            nothing,
            nothing,
            "extension:$(extension_id(extension))"),
    ]
    return ExtensionResult(
        extension_id(extension),
        context.phase;
        diagnostics,
        artifacts=Dict{String, Any}(
            "languages" => sort!(collect(languages))))
end
