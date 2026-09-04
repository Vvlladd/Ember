import Foundation
import FoundationModels

/// Guided generation for the `structured` scenario. The inspector records the request's response format
/// as `CityFacts` and shows the schema the model was given.
@Generable
struct CityFacts {
    @Guide(description: "The city's common English name.")
    var name: String
    var country: String
    @Guide(.range(1...50_000_000))
    var population: Int
    var oneLineFact: String
}
