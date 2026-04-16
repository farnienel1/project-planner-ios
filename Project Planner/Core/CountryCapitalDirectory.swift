import Foundation

struct CountryOption: Hashable, Codable {
    let code: String
    let name: String
    let capital: String
    let latitude: Double
    let longitude: Double
}

enum CountryCapitalDirectory {
    static let supported: [CountryOption] = [
        CountryOption(code: "GB", name: "United Kingdom", capital: "London", latitude: 51.5074, longitude: -0.1278),
        CountryOption(code: "IE", name: "Ireland", capital: "Dublin", latitude: 53.3498, longitude: -6.2603),
        CountryOption(code: "US", name: "United States", capital: "Washington, DC", latitude: 38.9072, longitude: -77.0369),
        CountryOption(code: "CA", name: "Canada", capital: "Ottawa", latitude: 45.4215, longitude: -75.6972),
        CountryOption(code: "AU", name: "Australia", capital: "Canberra", latitude: -35.2809, longitude: 149.1300),
        CountryOption(code: "NZ", name: "New Zealand", capital: "Wellington", latitude: -41.2865, longitude: 174.7762),
        CountryOption(code: "FR", name: "France", capital: "Paris", latitude: 48.8566, longitude: 2.3522),
        CountryOption(code: "DE", name: "Germany", capital: "Berlin", latitude: 52.5200, longitude: 13.4050),
        CountryOption(code: "ES", name: "Spain", capital: "Madrid", latitude: 40.4168, longitude: -3.7038),
        CountryOption(code: "IT", name: "Italy", capital: "Rome", latitude: 41.9028, longitude: 12.4964),
        CountryOption(code: "NL", name: "Netherlands", capital: "Amsterdam", latitude: 52.3676, longitude: 4.9041),
        CountryOption(code: "SE", name: "Sweden", capital: "Stockholm", latitude: 59.3293, longitude: 18.0686),
        CountryOption(code: "NO", name: "Norway", capital: "Oslo", latitude: 59.9139, longitude: 10.7522),
        CountryOption(code: "DK", name: "Denmark", capital: "Copenhagen", latitude: 55.6761, longitude: 12.5683),
        CountryOption(code: "PL", name: "Poland", capital: "Warsaw", latitude: 52.2297, longitude: 21.0122),
        CountryOption(code: "AE", name: "United Arab Emirates", capital: "Abu Dhabi", latitude: 24.4539, longitude: 54.3773)
    ]

    static func option(for code: String) -> CountryOption? {
        supported.first(where: { $0.code == code.uppercased() })
    }

    static func fallbackDescription(for code: String) -> String {
        guard let country = option(for: code) else { return "country capital" }
        if country.code == "GB" { return "London, UK" }
        return "\(country.capital), \(country.name)"
    }
}
