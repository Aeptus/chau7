# CrossCutting Tests

Tests that verify interactions between multiple modules and system-wide concerns.

## Files

| File | Tests |
|------|-------|
| `IntegrationTests.swift` | Component interactions like command detection with shell escaping |
| `PerformanceTests.swift` | Performance benchmarks for critical operations |
| `PropertyBasedTests.swift` | Fuzz-style tests verifying invariants across randomized inputs |
| `SendableTests.swift` | Compile-time verification of Sendable conformance for concurrency |

## Corresponding Source

- Multiple modules across `Sources/Chau7/` and `Sources/Chau7Core/`
