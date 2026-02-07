# Architecture Diagram: Path Resolution Refactoring

## Before Refactoring (Shotgun Surgery)

```
┌─────────────────────────────────────────────────────────────┐
│                    Path Resolution Logic                     │
│                     (Scattered Across)                       │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  Progress    │    │  CueTooltip  │    │  Torrent.mm  │
│              │    │              │    │              │
│ • buildCache │    │ • cuePath    │    │ • pathToOpen │
│ • fileIndexes│    │ • pathToOpen │    │              │
└──────────────┘    │ • tooltip    │    └──────────────┘
                    └──────────────┘
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │                   │
                    ▼                   ▼
            ┌──────────────┐    ┌──────────────┐
            │   Playable   │    │  PlayMenu    │
            │              │    │              │
            │ (uses paths) │    │ (uses paths) │
            └──────────────┘    └──────────────┘
                    │                   │
                    └─────────┬─────────┘
                              │
                              ▼
                    ┌──────────────┐
                    │   Category   │
                    │              │
                    │ (uses paths) │
                    └──────────────┘

Problem: To fix path handling bug → Touch 3-7 files
```

## After Refactoring (Single Responsibility)

```
┌─────────────────────────────────────────────────────────────┐
│              Torrent+PathResolution.mm                       │
│         (Single Source of Truth for Paths)                   │
│                                                              │
│  Folder Matching:                                           │
│  • fileName:belongsToFolder:                                │
│  • fileIndexesForFolder:                                    │
│  • buildFolderToFilesCache:                                 │
│                                                              │
│  CUE Resolution:                                            │
│  • cueFilePathForAudioPath:                                 │
│  • cueFilePathForFolder:                                    │
│  • pathToOpenForFolder:                                     │
│  • pathToOpenForAudioPath:                                  │
│                                                              │
│  Path Normalization:                                        │
│  • relativePathInTorrent:                                   │
│  • resolvePathInTorrent:                                    │
│  • tooltipPathForItemPath:type:folder:                      │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  Progress    │    │   Playable   │    │  PlayMenu    │
│              │    │              │    │              │
│ (uses paths) │    │ (uses paths) │    │ (uses paths) │
└──────────────┘    └──────────────┘    └──────────────┘
                              │
                              ▼
                    ┌──────────────┐
                    │   Category   │
                    │              │
                    │ (uses paths) │
                    └──────────────┘

Solution: To fix path handling bug → Touch 1 file (PathResolution)
```

## Key Improvements

### 1. Reduced Coupling
- **Before**: 7 files directly implemented path logic
- **After**: 1 file implements, 6 files consume

### 2. Single Responsibility
- **Before**: CueTooltip.mm mixed concerns (CUE files + tooltips + folder paths)
- **After**: PathResolution.mm has one job: resolve paths correctly

### 3. Easier Testing
- **Before**: Test path logic in 7 different contexts
- **After**: Test path logic in 1 centralized module

### 4. Better Documentation
- **Before**: Path handling rules scattered across multiple files
- **After**: All path handling documented in one place

## File Changes Summary

| Action | File | Lines | Purpose |
|--------|------|-------|---------|
| ✅ Created | Torrent+PathResolution.mm | 310 | Centralized path resolution |
| ❌ Deleted | Torrent+CueTooltip.mm | 240 | Merged into PathResolution |
| ✏️ Modified | Torrent+Progress.mm | -51 | Removed buildCache, fileIndexes |
| ✏️ Modified | Torrent.mm | -7 | Removed duplicate pathToOpen |
| ✏️ Modified | CMakeLists.txt | ±1 | Updated build list |
| ✏️ Modified | Torrent.h | ±1 | Updated documentation |

**Net Result**: +12 lines, -1 file, significantly improved maintainability

## Architectural Principles Applied

1. **Single Responsibility Principle (SRP)**
   - Each module has one reason to change
   - PathResolution owns all path logic

2. **Don't Repeat Yourself (DRY)**
   - Eliminated duplicate path resolution code
   - One implementation, many consumers

3. **Separation of Concerns**
   - Path resolution separated from business logic
   - UI components don't know about path internals

4. **Encapsulation**
   - Path handling details hidden behind clear API
   - Implementation can change without affecting consumers

## Future Maintenance

When path handling needs change (e.g., supporting UNC paths, network shares, etc.):

1. Open `Torrent+PathResolution.mm`
2. Update the relevant method(s)
3. Test the change
4. Done!

No need to hunt through multiple files or risk inconsistent implementations.
