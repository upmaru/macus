# Spec Delta

## MODIFIED Requirements

### Requirement: SwiftPM delivery

The project SHALL build and test with SwiftPM and strict Swift 6 concurrency, with a package named macus, library product Macus and one minimal macus executable serving daemon and client commands. The package MAY additionally provide an optional application product for the native macOS application; user-interface code and its dependencies MUST NOT be linked into the Macus library or the macus executable. Debug/release builds, formatting and warnings-as-errors SHALL be canonical commands and SHALL cover the application targets.

#### Scenario: Clean toolchain build

- **WHEN** the documented build and test commands run on the supported toolchain
- **THEN** they succeed without concurrency diagnostics and produce the Macus library and macus executable

#### Scenario: Application product

- **WHEN** the application product is built
- **THEN** the macus executable is unchanged and links no user-interface framework or application dependency

## ADDED Requirements

### Requirement: Optional application delivery

The native macOS application SHALL be assembled from the SwiftPM build by a documented script and SHALL NOT be installed, required or activated by the package that delivers the macus executable and server. Building, installing or removing the application MUST NOT modify state directories, launchd jobs or gateway trust. Signed and notarized distribution of the application SHALL remain future scope and MUST NOT be claimed.

#### Scenario: Package install

- **WHEN** the Macus package is installed
- **THEN** no application is installed and the runtime is fully usable without one

#### Scenario: Application removed

- **WHEN** the application bundle is deleted
- **THEN** the runtime, services, state and gateway trust are unchanged
