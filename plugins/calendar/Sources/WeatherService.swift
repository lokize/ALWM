import Foundation
import CoreLocation

/// Open-Meteo WMO weather interpretation codes → SF Symbol + kind.
enum WeatherCondition: String, Sendable {
    case clear
    case partlyCloudy
    case cloudy
    case fog
    case drizzle
    case rain
    case snow
    case thunderstorm

    var symbolName: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .partlyCloudy: return "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        }
    }

    static func from(wmoCode code: Int) -> WeatherCondition {
        switch code {
        case 0: return .clear
        case 1, 2: return .partlyCloudy
        case 3: return .cloudy
        case 45, 48: return .fog
        case 51, 53, 55, 56, 57: return .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82: return .rain
        case 71, 73, 75, 77, 85, 86: return .snow
        case 95, 96, 99: return .thunderstorm
        default: return .cloudy
        }
    }
}

struct WeatherDay: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let weatherCode: Int
    let tempMax: Double
    let tempMin: Double

    var condition: WeatherCondition { .from(wmoCode: weatherCode) }
}

struct WeatherSnapshot: Equatable, Sendable {
    var locationLabel: String
    var currentTemp: Double?
    var currentCode: Int?
    var days: [WeatherDay]

    var currentCondition: WeatherCondition {
        .from(wmoCode: currentCode ?? days.first?.weatherCode ?? 3)
    }
}

enum WeatherService {
    struct GeoResult: Sendable, Identifiable, Equatable {
        var id: String { "\(latitude),\(longitude),\(name)" }
        let name: String
        let admin1: String?
        let country: String?
        let latitude: Double
        let longitude: Double

        var displayName: String {
            var parts: [String] = [name]
            if let admin1, !admin1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(admin1)
            }
            if let country, !country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(country)
            }
            return parts.joined(separator: ", ")
        }
    }

    static func geocode(query: String, count: Int = 1) async throws -> GeoResult {
        let results = try await search(query: query, count: max(1, count))
        guard let first = results.first else { throw WeatherError.notFound }
        return first
    }

    static func search(query: String, count: Int = 6) async throws -> [GeoResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: String(min(10, max(1, count)))),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WeatherError.network
        }
        let decoded = try JSONDecoder().decode(GeoResponse.self, from: data)
        return (decoded.results ?? []).map {
            GeoResult(
                name: $0.name,
                admin1: $0.admin1,
                country: $0.country,
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }
    }

    /// Best-effort place label for GPS coordinates (Open-Meteo search near point via reverse Nominatim-style).
    static func reverseGeocodeLabel(latitude: Double, longitude: Double) async -> String? {
        // Prefer Apple reverse geocoder when available.
        if let apple = await reverseViaCLGeocoder(latitude: latitude, longitude: longitude) {
            return apple
        }
        // Fallback: Open-Meteo has no reverse API — use BigDataCloud free client endpoint.
        var comps = URLComponents(string: "https://api.bigdatacloud.net/data/reverse-geocode-client")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "localityLanguage", value: Locale.current.language.languageCode?.identifier ?? "en")
        ]
        guard let url = comps.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(BigDataCloudResponse.self, from: data)
        else { return nil }
        var parts: [String] = []
        if let city = decoded.city, !city.isEmpty { parts.append(city) }
        else if let loc = decoded.locality, !loc.isEmpty { parts.append(loc) }
        if let region = decoded.principalSubdivision, !region.isEmpty { parts.append(region) }
        if let country = decoded.countryName, !country.isEmpty { parts.append(country) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func reverseViaCLGeocoder(latitude: Double, longitude: Double) async -> String? {
        await withCheckedContinuation { cont in
            let geocoder = CLGeocoder()
            let location = CLLocation(latitude: latitude, longitude: longitude)
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                guard let p = placemarks?.first else {
                    cont.resume(returning: nil)
                    return
                }
                var parts: [String] = []
                if let locality = p.locality, !locality.isEmpty { parts.append(locality) }
                else if let name = p.name, !name.isEmpty { parts.append(name) }
                if let admin = p.administrativeArea, !admin.isEmpty { parts.append(admin) }
                if let country = p.country, !country.isEmpty { parts.append(country) }
                cont.resume(returning: parts.isEmpty ? nil : parts.joined(separator: ", "))
            }
        }
    }

    static func forecast(latitude: Double, longitude: Double, locationLabel: String) async throws -> WeatherSnapshot {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7")
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WeatherError.network
        }
        let decoded = try JSONDecoder().decode(ForecastResponse.self, from: data)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var days: [WeatherDay] = []
        let daily = decoded.daily
        let count = min(
            daily.time.count,
            daily.weather_code.count,
            daily.temperature_2m_max.count,
            daily.temperature_2m_min.count
        )
        for i in 0..<count {
            guard let date = formatter.date(from: daily.time[i]) else { continue }
            days.append(WeatherDay(
                id: daily.time[i],
                date: date,
                weatherCode: daily.weather_code[i],
                tempMax: daily.temperature_2m_max[i],
                tempMin: daily.temperature_2m_min[i]
            ))
        }

        return WeatherSnapshot(
            locationLabel: locationLabel,
            currentTemp: decoded.current?.temperature_2m,
            currentCode: decoded.current?.weather_code,
            days: days
        )
    }

    enum WeatherError: Error {
        case emptyQuery
        case notFound
        case network
    }

    private struct GeoResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let admin1: String?
            let country: String?
            let latitude: Double
            let longitude: Double
        }
        let results: [Result]?
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double?
            let weather_code: Int?
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current?
        let daily: Daily
    }

    private struct BigDataCloudResponse: Decodable {
        let city: String?
        let locality: String?
        let principalSubdivision: String?
        let countryName: String?
    }
}
