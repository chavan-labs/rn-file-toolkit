#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pure Foundation + zlib ZIP reader/writer, kept free of React so it can be
// compiled and exercised on macOS (clang -fobjc-arc -framework Foundation -lz).
// All errors are reported through `error` (domain "RNFileToolkit"); neither
// function throws or allocates a whole entry in memory.

/// Extracts `sourcePath` into `destDir`, appending each extracted file path to
/// `extractedFiles`. Entries that would land outside `destDir` abort with
/// "ZIP entry has invalid path".
BOOL FTKUnzipFile(NSString *sourcePath,
                  NSString *destDir,
                  NSMutableArray<NSString *> *extractedFiles,
                  NSError **error);

/// Writes a deflate archive of `sourcePath` (a file, or a folder whose entries
/// are prefixed with the folder name) to `destPath`.
BOOL FTKZipPath(NSString *sourcePath, NSString *destPath, NSError **error);

NS_ASSUME_NONNULL_END
