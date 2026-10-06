// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HotelWiFi", platforms: [.macOS(.v14)],
    products: [.library(name: "HotelWiFiCore", targets: ["HotelWiFiCore"]),
               .executable(name: "HotelWiFiApp", targets: ["HotelWiFiApp"]),
               .executable(name: "hotelwifi", targets: ["HotelWiFiCLI"]),
               .executable(name: "HotelWiFiHelper", targets: ["HotelWiFiHelper"]),
               .executable(name: "HotelWiFiRecoveryHarness", targets: ["HotelWiFiRecoveryHarness"])],
    targets: [
        .target(name: "HotelWiFiPlatform", path: "HotelWiFi/Platform", publicHeadersPath: "include"),
        .target(name: "HotelWiFiCore", path: "HotelWiFi/Core"),
        .executableTarget(name: "HotelWiFiApp", dependencies: ["HotelWiFiCore"], path: "HotelWiFi/App"),
        .executableTarget(name: "HotelWiFiCLI", dependencies: ["HotelWiFiCore"], path: "HotelWiFi/CLI"),
        .executableTarget(name: "HotelWiFiHelper", dependencies: ["HotelWiFiCore", "HotelWiFiPlatform"], path: "HotelWiFi/Helper"),
        .executableTarget(name: "HotelWiFiRecoveryHarness", dependencies: ["HotelWiFiCore"], path: "HotelWiFi/Tests/FaultHarness"),
        .testTarget(name: "HotelWiFiTests", dependencies: ["HotelWiFiCore"], path: "HotelWiFi/Tests", exclude: ["FaultHarness"], resources: [.copy("Fixtures")])
    ])
