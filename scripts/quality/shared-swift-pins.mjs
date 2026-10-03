export const sharedSwiftLockPaths = [
  "apps/chau7-macos/Package.resolved",
  "apps/chau7-ios/Chau7RemoteApp/Chau7RemoteApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
];
export function sharedSwiftPinFailures(read) {
  try {
    const locks = sharedSwiftLockPaths.map((file) => JSON.parse(read(file)));
    const mac = new Map(locks[0].pins.map((pin) => [pin.identity, pin]));
    const failures = [];
    for (const pin of locks[1].pins) {
      const shared = mac.get(pin.identity);
      if (shared && (shared.state.revision !== pin.state.revision || shared.state.version !== pin.state.version)) failures.push(`Shared Swift pin ${pin.identity} differs between macOS and iOS. Update both resolved files and run native CI.`);
    }
    return failures;
  } catch (error) { return [`Shared Swift lock validation failed: ${error.message}`]; }
}
