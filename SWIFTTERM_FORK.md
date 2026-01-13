# SwiftTerm Fork Documentation

## Overview

Chau7 uses a forked version of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal emulation.

**Fork Repository**: https://github.com/schiste/Chau7-SwiftTerm
**Pinned Revision**: `7a6f4acd84c152170336832db4b2fda87722f3ef`

## Why a Fork?

The fork exists to provide:

1. **Stability**: Pin to a known-good version for production use
2. **Customization**: Minor adjustments for Chau7-specific requirements
3. **Control**: Independent release schedule from upstream

## Modifications from Upstream

### Current Modifications

| Change | File | Description |
|--------|------|-------------|
| None significant | - | Fork is primarily for version pinning |

### Potential Future Modifications

- Custom OSC sequence handling for AI CLI detection
- Enhanced accessibility hooks
- Performance optimizations for large scrollback

## Upstream Sync Strategy

### When to Sync

1. **Security fixes**: Immediately sync security patches
2. **Bug fixes**: Sync after testing in development
3. **Features**: Evaluate usefulness before syncing
4. **Breaking changes**: Careful evaluation required

### Sync Process

```bash
# Add upstream remote (one-time)
cd Chau7-SwiftTerm
git remote add upstream https://github.com/migueldeicaza/SwiftTerm.git

# Fetch upstream changes
git fetch upstream

# Review changes
git log upstream/main --oneline -20

# Create sync branch
git checkout -b sync-upstream-YYYY-MM-DD

# Merge or cherry-pick
git merge upstream/main
# OR
git cherry-pick <commit-hash>

# Test thoroughly
swift test

# Push to fork
git push origin sync-upstream-YYYY-MM-DD

# Create PR and merge after review
```

### After Sync

1. Update `Package.swift` revision in Chau7
2. Run full test suite
3. Test terminal emulation manually
4. Update this document with changes

## Testing Terminal Emulation

### Manual Tests

1. **Basic I/O**: Type commands, verify output
2. **Colors**: Run `ls --color`, verify ANSI colors
3. **Cursor**: Test cursor movement (vim, nano)
4. **Scrollback**: Test scroll with large output
5. **Unicode**: Test emoji and CJK characters
6. **Control sequences**: Test Ctrl+C, Ctrl+D, etc.

### Automated Tests

```bash
# Run SwiftTerm's test suite
cd Chau7-SwiftTerm
swift test
```

## Known Issues

| Issue | Status | Workaround |
|-------|--------|------------|
| None currently | - | - |

## Contact

For issues with the fork:
1. Check if issue exists in upstream SwiftTerm
2. If Chau7-specific, file issue in Chau7 repository
3. If upstream issue, consider filing upstream and syncing fix

## License

SwiftTerm is licensed under the MIT License. The fork maintains the same license.

## Version History

| Date | Revision | Changes |
|------|----------|---------|
| Initial | 7a6f4ac | Initial fork for Chau7 |
