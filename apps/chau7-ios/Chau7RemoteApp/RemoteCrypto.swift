// RemoteCryptoSession moved to Chau7Core (`RemoteCryptoSession.swift`) so the
// security-critical AEAD code lives in the shared package and is covered by unit tests
// (`Chau7Core/Tests/Chau7CoreTests/Remote/RemoteCryptoSessionTests.swift`). It is used here
// via `import Chau7Core`.
//
// This file is intentionally left as a stub because it still has an explicit
// reference in the Xcode project; delete the file and its project reference
// when convenient (the `Chau7RemoteApp` folder is a synchronized group, so no
// replacement reference is needed).
