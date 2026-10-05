#import "FileToolkitZip.h"
#include <zlib.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <time.h>

// Streaming buffer size for both inflate and deflate; nothing larger is ever
// allocated per entry, whatever size the archive claims.
static const size_t kFTKZipChunk = 256 * 1024;

static NSError *FTKZipError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"RNFileToolkit"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *FTKZipErrno(NSString *what, NSString *path) {
    return FTKZipError(errno, [NSString stringWithFormat:@"%@ %@: %s", what, path, strerror(errno)]);
}

// ZIP fields are little-endian; read them byte-wise so alignment never matters.
static inline uint16_t FTKRd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t FTKRd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline uint64_t FTKRd64(const uint8_t *p) { return (uint64_t)FTKRd32(p) | ((uint64_t)FTKRd32(p + 4) << 32); }
static inline void FTKPut16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void FTKPut32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

/// YES when [offset, offset + len) lies inside `total` bytes. Written so that a
/// hostile offset or length can never wrap around.
static inline BOOL FTKInBounds(uint64_t offset, uint64_t len, uint64_t total) {
    return offset <= total && len <= total - offset;
}

/**
 * Lexically normalises an entry name to a relative path, or returns nil when a
 * `..` would climb above the extraction root (zip-slip). Done on the name alone
 * rather than with -stringByStandardizingPath, which consults the file system
 * (e.g. strips /private only when the path already exists) and only resolves
 * `..` for absolute paths.
 */
static NSString *FTKSafeRelativePath(NSString *name) {
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *component in [name componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."]) {
            if (parts.count == 0) return nil;
            [parts removeLastObject];
            continue;
        }
        [parts addObject:component];
    }
    return [parts componentsJoinedByString:@"/"];
}

static BOOL FTKWriteAll(FILE *out, const void *buf, size_t len, NSString *path, NSError **error) {
    if (len > 0 && fwrite(buf, 1, len, out) != len) {
        if (error) *error = FTKZipErrno(@"Failed to write", path);
        return NO;
    }
    return YES;
}

// ─── Unzip ────────────────────────────────────────────────────────────────────

/** Streams one stored or deflated entry to `out`, enforcing the declared size. */
static BOOL FTKExtractEntryData(const uint8_t *in, uint64_t compSize, uint64_t uncompSize,
                                uint16_t method, FILE *out, uint8_t *buf, uLong *crcOut,
                                NSString *entryName, NSString *destPath, NSError **error) {
    uLong crc = crc32(0L, Z_NULL, 0);

    if (method == 0) {
        if (compSize != uncompSize) {
            if (error) *error = FTKZipError(-6, [NSString stringWithFormat:@"ZIP entry sizes disagree: %@", entryName]);
            return NO;
        }
        while (compSize > 0) {
            size_t n = compSize > kFTKZipChunk ? kFTKZipChunk : (size_t)compSize;
            if (!FTKWriteAll(out, in, n, destPath, error)) return NO;
            crc = crc32(crc, in, (uInt)n);
            in += n;
            compSize -= n;
        }
        *crcOut = crc;
        return YES;
    }

    // Raw deflate (no zlib header), fed and drained in fixed-size chunks.
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) {
        if (error) *error = FTKZipError(-1, @"zlib inflateInit2 failed");
        return NO;
    }

    uint64_t inLeft = compSize;
    uint64_t written = 0;
    NSError *failure = nil;
    int ret = Z_OK;
    while (ret != Z_STREAM_END) {
        if (strm.avail_in == 0 && inLeft > 0) {
            size_t n = inLeft > kFTKZipChunk ? kFTKZipChunk : (size_t)inLeft;
            strm.next_in  = (Bytef *)in;
            strm.avail_in = (uInt)n;
            in     += n;
            inLeft -= n;
        }
        strm.next_out  = buf;
        strm.avail_out = (uInt)kFTKZipChunk;
        ret = inflate(&strm, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END) {
            // Output space is always free here, so Z_BUF_ERROR means the input
            // ran out before the deflate stream ended: the entry is truncated.
            failure = ret == Z_BUF_ERROR
                ? FTKZipError(-2, [NSString stringWithFormat:@"ZIP entry is truncated: %@", entryName])
                : FTKZipError(-2, [NSString stringWithFormat:@"inflate error %d for entry: %@", ret, entryName]);
            break;
        }
        size_t produced = kFTKZipChunk - strm.avail_out;
        if (produced > uncompSize - written) {
            failure = FTKZipError(-4, [NSString stringWithFormat:@"ZIP entry exceeds its declared size: %@", entryName]);
            break;
        }
        NSError *writeError = nil;
        if (!FTKWriteAll(out, buf, produced, destPath, &writeError)) {
            failure = writeError;
            break;
        }
        crc = crc32(crc, buf, (uInt)produced);
        written += produced;
    }
    inflateEnd(&strm);

    if (!failure && written != uncompSize) {
        failure = FTKZipError(-4, [NSString stringWithFormat:@"ZIP entry is shorter than its declared size: %@", entryName]);
    }
    if (failure) {
        if (error) *error = failure;
        return NO;
    }
    *crcOut = crc;
    return YES;
}

/**
 * Reads the archive through its central directory (EOCD, with Zip64 support),
 * which is the only authoritative list of entries and sizes. Walking local
 * headers instead breaks on data descriptors (bit 3), which Java's
 * ZipOutputStream — and therefore Android's zip() — writes for every entry.
 */
/**
 * mkdir -p that records, outermost first, every directory it actually created,
 * so a failed extraction can remove them again without touching existing ones.
 */
static BOOL FTKMakeDirectories(NSString *path, NSMutableArray<NSString *> *createdDirs, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *missing = [NSMutableArray new];
    for (NSString *p = path; p.length > 1 && ![fm fileExistsAtPath:p]; p = [p stringByDeletingLastPathComponent]) {
        [missing insertObject:p atIndex:0];
    }
    if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    [createdDirs addObjectsFromArray:missing];
    return YES;
}

static BOOL FTKExtractArchive(NSString *sourcePath, NSString *destDir,
                              NSMutableArray<NSString *> *extractedFiles,
                              NSMutableArray<NSString *> *createdFiles,
                              NSMutableArray<NSString *> *createdDirs,
                              NSError **error);

BOOL FTKUnzipFile(NSString *sourcePath,
                  NSString *destDir,
                  NSMutableArray<NSString *> *extractedFiles,
                  NSError **error) {
    NSMutableArray<NSString *> *createdFiles = [NSMutableArray new];
    NSMutableArray<NSString *> *createdDirs = [NSMutableArray new];
    if (FTKExtractArchive(sourcePath, destDir, extractedFiles, createdFiles, createdDirs, error)) return YES;
    // All or nothing: undo what this call created. Pre-existing files and folders
    // are left alone; rmdir only removes a directory that is empty again.
    for (NSString *path in createdFiles) unlink(path.fileSystemRepresentation);
    for (NSString *path in createdDirs.reverseObjectEnumerator) rmdir(path.fileSystemRepresentation);
    [extractedFiles removeAllObjects];
    return NO;
}

static BOOL FTKExtractArchive(NSString *sourcePath, NSString *destDir,
                              NSMutableArray<NSString *> *extractedFiles,
                              NSMutableArray<NSString *> *createdFiles,
                              NSMutableArray<NSString *> *createdDirs,
                              NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:sourcePath]) {
        if (error) *error = FTKZipError(-7, [NSString stringWithFormat:@"Source zip file does not exist: %@", sourcePath]);
        return NO;
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:sourcePath options:NSDataReadingMappedIfSafe error:&readError];
    if (!data) {
        if (error) *error = readError ?: FTKZipError(-7, @"Cannot read zip file");
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    const uint64_t length = data.length;
    NSError *corrupt = FTKZipError(-8, @"Invalid or corrupt ZIP archive");

    // End of central directory: 22 bytes plus an optional comment of up to 64 KB.
    if (length < 22) {
        if (error) *error = corrupt;
        return NO;
    }
    uint64_t eocd = UINT64_MAX;
    const uint64_t scanStop = length > 65557 ? length - 65557 : 0;
    for (uint64_t pos = length - 22; ; pos--) {
        if (FTKRd32(bytes + pos) == 0x06054b50 && FTKRd16(bytes + pos + 20) <= length - pos - 22) {
            eocd = pos;
            break;
        }
        if (pos == scanStop) break;
    }
    if (eocd == UINT64_MAX) {
        if (error) *error = corrupt;
        return NO;
    }

    uint64_t entryCount = FTKRd16(bytes + eocd + 10);
    uint64_t cdSize     = FTKRd32(bytes + eocd + 12);
    uint64_t cdOffset   = FTKRd32(bytes + eocd + 16);

    // Zip64 end of central directory locator sits immediately before the EOCD.
    if (eocd >= 20 && FTKRd32(bytes + eocd - 20) == 0x07064b50) {
        uint64_t z64 = FTKRd64(bytes + eocd - 20 + 8);
        if (!FTKInBounds(z64, 56, length) || FTKRd32(bytes + z64) != 0x06064b50) {
            if (error) *error = corrupt;
            return NO;
        }
        entryCount = FTKRd64(bytes + z64 + 32);
        cdSize     = FTKRd64(bytes + z64 + 40);
        cdOffset   = FTKRd64(bytes + z64 + 48);
    }
    if (!FTKInBounds(cdOffset, cdSize, length)) {
        if (error) *error = corrupt;
        return NO;
    }

    // Relative destinations are anchored to the working directory so every
    // extracted path is absolute and the containment check below is lexical.
    NSString *root = destDir.isAbsolutePath
        ? destDir
        : [fm.currentDirectoryPath stringByAppendingPathComponent:destDir];
    NSError *mkdirError = nil;
    if (!FTKMakeDirectories(root, createdDirs, &mkdirError)) {
        if (error) *error = mkdirError;
        return NO;
    }

    NSMutableData *bufData = [NSMutableData dataWithLength:kFTKZipChunk];
    uint8_t *buf = (uint8_t *)bufData.mutableBytes;

    const uint64_t cdEnd = cdOffset + cdSize;
    uint64_t p = cdOffset;
    for (uint64_t i = 0; i < entryCount; i++) {
        if (!FTKInBounds(p, 46, cdEnd) || FTKRd32(bytes + p) != 0x02014b50) {
            if (error) *error = corrupt;
            return NO;
        }
        const uint8_t *h = bytes + p;
        uint16_t flags      = FTKRd16(h + 8);
        uint16_t method     = FTKRd16(h + 10);
        uint32_t crcExpect  = FTKRd32(h + 16);
        uint64_t compSize   = FTKRd32(h + 20);
        uint64_t uncompSize = FTKRd32(h + 24);
        uint16_t nameLen    = FTKRd16(h + 28);
        uint16_t extraLen   = FTKRd16(h + 30);
        uint16_t commentLen = FTKRd16(h + 32);
        uint64_t localOff   = FTKRd32(h + 42);
        uint64_t recordLen  = 46 + (uint64_t)nameLen + extraLen + commentLen;
        if (!FTKInBounds(p, recordLen, cdEnd)) {
            if (error) *error = corrupt;
            return NO;
        }
        const uint8_t *namePtr = h + 46;
        const uint8_t *extra   = namePtr + nameLen;
        p += recordLen;

        // Zip64 extended information: present only for fields saturated at 0xFFFFFFFF,
        // in the fixed order uncompressed, compressed, local header offset.
        if (uncompSize == 0xFFFFFFFF || compSize == 0xFFFFFFFF || localOff == 0xFFFFFFFF) {
            BOOL resolved = NO;
            uint32_t q = 0;
            while (q + 4 <= extraLen) {
                uint16_t tag  = FTKRd16(extra + q);
                uint16_t size = FTKRd16(extra + q + 2);
                if (size > extraLen - q - 4) break;
                if (tag == 0x0001) {
                    const uint8_t *z = extra + q + 4;
                    uint32_t used = 0;
                    BOOL ok = YES;
                    if (uncompSize == 0xFFFFFFFF) {
                        if (used + 8 > size) ok = NO; else { uncompSize = FTKRd64(z + used); used += 8; }
                    }
                    if (ok && compSize == 0xFFFFFFFF) {
                        if (used + 8 > size) ok = NO; else { compSize = FTKRd64(z + used); used += 8; }
                    }
                    if (ok && localOff == 0xFFFFFFFF) {
                        if (used + 8 > size) ok = NO; else { localOff = FTKRd64(z + used); used += 8; }
                    }
                    resolved = ok;
                    break;
                }
                q += 4 + size;
            }
            if (!resolved) {
                if (error) *error = corrupt;
                return NO;
            }
        }

        if (memchr(namePtr, 0, nameLen) != NULL) {
            if (error) *error = FTKZipError(-100, @"ZIP entry has invalid path");
            return NO;
        }
        // Bit 11 marks UTF-8 names; older archives are usually CP437/Latin-1, so
        // fall back to Latin-1 (which accepts any byte sequence).
        NSString *entryName = [[NSString alloc] initWithBytes:namePtr length:nameLen encoding:NSUTF8StringEncoding];
        if (!entryName) entryName = [[NSString alloc] initWithBytes:namePtr length:nameLen encoding:NSISOLatin1StringEncoding];
        if (!entryName) {
            if (error) *error = corrupt;
            return NO;
        }

        // Protect against zip-slip/path traversal (e.g. ../../outside.txt)
        NSString *relative = FTKSafeRelativePath(entryName);
        BOOL isDirectory = [entryName hasSuffix:@"/"];
        if (!relative || (relative.length == 0 && !isDirectory)) {
            if (error) *error = FTKZipError(-100, @"ZIP entry has invalid path");
            return NO;
        }
        NSString *destPath = relative.length > 0 ? [root stringByAppendingPathComponent:relative] : root;

        if (isDirectory) {
            NSError *dirError = nil;
            if (!FTKMakeDirectories(destPath, createdDirs, &dirError)) {
                if (error) *error = dirError;
                return NO;
            }
            continue;
        }

        if (flags & 0x0001) {
            if (error) *error = FTKZipError(-5, [NSString stringWithFormat:@"Encrypted ZIP entries are not supported: %@", entryName]);
            return NO;
        }
        if (method != 0 && method != 8) {
            if (error) *error = FTKZipError(-5, [NSString stringWithFormat:@"Unsupported ZIP compression method %u for entry: %@", method, entryName]);
            return NO;
        }

        // The local header is read only for its own name/extra lengths, which may
        // differ from the central copy; sizes come from the central directory.
        if (!FTKInBounds(localOff, 30, length) || FTKRd32(bytes + localOff) != 0x04034b50) {
            if (error) *error = corrupt;
            return NO;
        }
        uint64_t dataStart = localOff + 30 + FTKRd16(bytes + localOff + 26) + FTKRd16(bytes + localOff + 28);
        if (!FTKInBounds(dataStart, compSize, length)) {
            if (error) *error = FTKZipError(-2, [NSString stringWithFormat:@"ZIP entry is truncated: %@", entryName]);
            return NO;
        }

        NSError *dirError = nil;
        if (!FTKMakeDirectories([destPath stringByDeletingLastPathComponent], createdDirs, &dirError)) {
            if (error) *error = dirError;
            return NO;
        }

        // Written to a temp file beside the target and renamed into place, so a
        // failed entry never clobbers an existing file and a symlink planted at
        // the destination is replaced rather than followed.
        char tmpPath[PATH_MAX];
        NSString *tmpTemplate = [[destPath stringByDeletingLastPathComponent]
                                 stringByAppendingPathComponent:@".ftkunzip-XXXXXX"];
        if (strlcpy(tmpPath, tmpTemplate.fileSystemRepresentation, sizeof(tmpPath)) >= sizeof(tmpPath)) {
            if (error) *error = FTKZipError(-100, @"ZIP entry has invalid path");
            return NO;
        }
        int fd = mkstemp(tmpPath);
        if (fd >= 0) fchmod(fd, 0644);
        FILE *out = fd >= 0 ? fdopen(fd, "wb") : NULL;
        if (!out) {
            if (error) *error = FTKZipErrno(@"Cannot create", destPath);
            if (fd >= 0) { close(fd); unlink(tmpPath); }
            return NO;
        }

        uLong crcActual = 0;
        NSError *entryError = nil;
        BOOL ok = FTKExtractEntryData(bytes + dataStart, compSize, uncompSize, method, out, buf,
                                      &crcActual, entryName, destPath, &entryError);
        if (ok && (uint32_t)crcActual != crcExpect) {
            ok = NO;
            entryError = FTKZipError(-3, [NSString stringWithFormat:@"CRC32 mismatch for entry: %@", entryName]);
        }
        if (fclose(out) != 0 && ok) {
            ok = NO;
            entryError = FTKZipErrno(@"Failed to write", destPath);
        }
        const char *fsPath = destPath.fileSystemRepresentation;
        struct stat existing;
        BOOL preexisting = lstat(fsPath, &existing) == 0;
        if (ok && rename(tmpPath, fsPath) != 0) {
            ok = NO;
            entryError = FTKZipErrno(@"Cannot create", destPath);
        }
        if (!ok) {
            unlink(tmpPath);
            if (error) *error = entryError;
            return NO;
        }
        if (!preexisting) [createdFiles addObject:destPath];
        [extractedFiles addObject:destPath];
    }

    return YES;
}

// ─── Zip ──────────────────────────────────────────────────────────────────────

static NSError *FTKZip64Error(void) {
    return FTKZipError(-9, @"ZIP64_NOT_SUPPORTED: archive exceeds 4 GB / 65535 entries");
}

static void FTKDosDateTime(time_t t, uint16_t *dosTime, uint16_t *dosDate) {
    struct tm tm;
    localtime_r(&t, &tm);
    if (tm.tm_year < 80) {          // DOS dates start at 1980-01-01 00:00
        *dosTime = 0;
        *dosDate = (1 << 5) | 1;
        return;
    }
    if (tm.tm_year > 207) {         // …and end at 2107-12-31 23:59:58
        tm.tm_year = 207; tm.tm_mon = 11; tm.tm_mday = 31;
        tm.tm_hour = 23; tm.tm_min = 59; tm.tm_sec = 58;
    }
    *dosTime = (uint16_t)((tm.tm_hour << 11) | (tm.tm_min << 5) | (tm.tm_sec / 2));
    *dosDate = (uint16_t)(((tm.tm_year - 80) << 9) | ((tm.tm_mon + 1) << 5) | tm.tm_mday);
}

/** Deflates `fullPath` into `out`, returning CRC and both sizes. */
static BOOL FTKDeflateFile(NSString *fullPath, FILE *out, NSString *destPath,
                           uint8_t *inBuf, uint8_t *outBuf,
                           uint32_t *crcOut, uint64_t *compOut, uint64_t *uncompOut, NSError **error) {
    FILE *in = fopen(fullPath.fileSystemRepresentation, "rb");
    if (!in) {
        if (error) *error = FTKZipErrno(@"Cannot read", fullPath);
        return NO;
    }
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        fclose(in);
        if (error) *error = FTKZipError(-1, @"zlib deflateInit2 failed");
        return NO;
    }

    uLong crc = crc32(0L, Z_NULL, 0);
    uint64_t comp = 0, uncomp = 0;
    BOOL ok = YES;
    int flush = Z_NO_FLUSH;
    do {
        size_t n = fread(inBuf, 1, kFTKZipChunk, in);
        if (ferror(in)) {
            if (error) *error = FTKZipErrno(@"Cannot read", fullPath);
            ok = NO;
            break;
        }
        flush = feof(in) ? Z_FINISH : Z_NO_FLUSH;
        crc = crc32(crc, inBuf, (uInt)n);
        uncomp += n;
        strm.next_in  = inBuf;
        strm.avail_in = (uInt)n;
        do {
            strm.next_out  = outBuf;
            strm.avail_out = (uInt)kFTKZipChunk;
            deflate(&strm, flush);
            size_t have = kFTKZipChunk - strm.avail_out;
            if (!FTKWriteAll(out, outBuf, have, destPath, error)) { ok = NO; break; }
            comp += have;
        } while (strm.avail_out == 0);
    } while (ok && flush != Z_FINISH);

    deflateEnd(&strm);
    fclose(in);
    if (!ok) return NO;
    *crcOut = (uint32_t)crc;
    *compOut = comp;
    *uncompOut = uncomp;
    return YES;
}

// ponytail: no Zip64 writer — archives are capped at 4 GB and 65534 entries
// (ZIP64_NOT_SUPPORTED); add Zip64 extra fields + EOCD64 if users hit it.
BOOL FTKZipPath(NSString *sourcePath, NSString *destPath, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:sourcePath isDirectory:&isDir]) {
        if (error) *error = FTKZipError(-7, @"Source path does not exist");
        return NO;
    }
    if (destPath.length == 0) {
        if (error) *error = FTKZipError(-7, @"Destination path is required");
        return NO;
    }

    // An existing destination is replaced below. Never let that delete a folder
    // (possibly the source itself), and remember its identity so an old archive
    // living inside the source folder is not zipped into the new one.
    BOOL destIsDir = NO;
    struct stat destSt;
    BOOL destExists = [fm fileExistsAtPath:destPath isDirectory:&destIsDir] &&
                      stat(destPath.fileSystemRepresentation, &destSt) == 0;
    if (destExists && destIsDir) {
        if (error) *error = FTKZipError(-7, @"Destination path is a directory");
        return NO;
    }

    NSString *baseDir;
    NSArray<NSString *> *relativePaths;
    // Entry names are prefixed with the source folder name so the archive
    // expands into `<folder>/…` — matching Android and what `zip -r` produces.
    NSString *entryPrefix = @"";
    if (isDir) {
        NSMutableArray<NSString *> *paths = [NSMutableArray new];
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:sourcePath];
        NSString *file;
        while ((file = [enumerator nextObject])) [paths addObject:file];
        relativePaths = paths;
        baseDir = sourcePath;
        entryPrefix = [sourcePath lastPathComponent];
    } else {
        relativePaths = @[[sourcePath lastPathComponent]];
        baseDir = [sourcePath stringByDeletingLastPathComponent];
    }

    // Collect everything up front (before the destination exists) so the entry
    // count and total size can be checked before a single byte is written.
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray new];
    uint64_t estimatedSize = 22;
    for (NSString *relativePath in relativePaths) {
        NSString *fullPath = [baseDir stringByAppendingPathComponent:relativePath];
        struct stat st;
        if (stat(fullPath.fileSystemRepresentation, &st) != 0) {
            if (errno == ENOENT) continue; // vanished, or a dangling symlink
            if (error) *error = FTKZipErrno(@"Cannot read", fullPath);
            return NO;
        }
        BOOL entryIsDir = S_ISDIR(st.st_mode);
        if (!entryIsDir && !S_ISREG(st.st_mode)) continue; // sockets, FIFOs, devices
        if (destExists && st.st_dev == destSt.st_dev && st.st_ino == destSt.st_ino) {
            if (!isDir) {
                if (error) *error = FTKZipError(-7, @"Destination path must differ from the source");
                return NO;
            }
            continue;
        }

        NSString *entryName = entryPrefix.length > 0
            ? [entryPrefix stringByAppendingPathComponent:relativePath]
            : relativePath;
        // Directory entries must end in "/" or extractors treat them as files.
        if (entryIsDir) entryName = [entryName stringByAppendingString:@"/"];
        NSData *nameData = [entryName dataUsingEncoding:NSUTF8StringEncoding];
        uint64_t size = entryIsDir ? 0 : (uint64_t)st.st_size;
        estimatedSize += 30 + 46 + 2 * (uint64_t)nameData.length + size;
        [entries addObject:@{
            @"path":  fullPath,
            @"name":  nameData,
            @"dir":   @(entryIsDir),
            @"mtime": @((long long)st.st_mtime),
            @"mode":  @((unsigned)(st.st_mode & 07777)),
        }];
    }
    // 0xFFFF / 0xFFFFFFFF are the Zip64 sentinels, so they are already too big.
    if (entries.count >= 0xFFFF || estimatedSize >= 0xFFFFFFFF) {
        if (error) *error = FTKZip64Error();
        return NO;
    }

    [fm createDirectoryAtPath:[destPath stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:destPath error:nil];
    FILE *out = fopen(destPath.fileSystemRepresentation, "wb");
    if (!out) {
        if (error) *error = FTKZipErrno(@"Failed to create destination zip file", destPath);
        return NO;
    }

    NSMutableData *inData = [NSMutableData dataWithLength:kFTKZipChunk];
    NSMutableData *outData = [NSMutableData dataWithLength:kFTKZipChunk];
    NSMutableData *centralDirectory = [NSMutableData new];
    uint64_t pos = 0;
    NSError *failure = nil;

    for (NSDictionary *entry in entries) {
        NSData *nameData = entry[@"name"];
        BOOL entryIsDir = [entry[@"dir"] boolValue];
        uint16_t method = entryIsDir ? 0 : 8;
        uint16_t dosTime = 0, dosDate = 0;
        FTKDosDateTime((time_t)[entry[@"mtime"] longLongValue], &dosTime, &dosDate);
        uint64_t headerOffset = pos;

        // Local file header; CRC and sizes are patched in once the data is written.
        uint8_t lh[30] = {0};
        FTKPut32(lh, 0x04034b50);
        FTKPut16(lh + 4, 20);          // version needed
        FTKPut16(lh + 6, 0x0800);      // bit 11: names are UTF-8
        FTKPut16(lh + 8, method);
        FTKPut16(lh + 10, dosTime);
        FTKPut16(lh + 12, dosDate);
        FTKPut16(lh + 26, (uint16_t)nameData.length);
        if (!FTKWriteAll(out, lh, sizeof(lh), destPath, &failure) ||
            !FTKWriteAll(out, nameData.bytes, nameData.length, destPath, &failure)) break;
        pos += sizeof(lh) + nameData.length;

        uint32_t crc = 0;
        uint64_t compSize = 0, uncompSize = 0;
        if (!entryIsDir) {
            if (!FTKDeflateFile(entry[@"path"], out, destPath,
                                (uint8_t *)inData.mutableBytes, (uint8_t *)outData.mutableBytes,
                                &crc, &compSize, &uncompSize, &failure)) break;
            pos += compSize;
            // A file can grow between the size check and now, and deflate can
            // expand incompressible data slightly.
            if (uncompSize >= 0xFFFFFFFF || pos >= 0xFFFFFFFF) {
                failure = FTKZip64Error();
                break;
            }
            uint8_t patch[12];
            FTKPut32(patch, crc);
            FTKPut32(patch + 4, (uint32_t)compSize);
            FTKPut32(patch + 8, (uint32_t)uncompSize);
            if (fseeko(out, (off_t)(headerOffset + 14), SEEK_SET) != 0 ||
                !FTKWriteAll(out, patch, sizeof(patch), destPath, &failure) ||
                fseeko(out, 0, SEEK_END) != 0) {
                if (!failure) failure = FTKZipErrno(@"Failed to write", destPath);
                break;
            }
        }

        uint8_t cd[46] = {0};
        FTKPut32(cd, 0x02014b50);
        // Made by Unix (high byte 3) so extractors honour the UTF-8 names as-is
        // and restore permissions from the high half of the external attributes;
        // with the MS-DOS default, Info-ZIP re-encodes names as CP437.
        FTKPut16(cd + 4, (3 << 8) | 20);
        FTKPut16(cd + 6, 20);          // version needed
        FTKPut16(cd + 8, 0x0800);
        FTKPut16(cd + 10, method);
        FTKPut16(cd + 12, dosTime);
        FTKPut16(cd + 14, dosDate);
        FTKPut32(cd + 16, crc);
        FTKPut32(cd + 20, (uint32_t)compSize);
        FTKPut32(cd + 24, (uint32_t)uncompSize);
        FTKPut16(cd + 28, (uint16_t)nameData.length);
        uint32_t mode = (uint32_t)[entry[@"mode"] unsignedIntValue] | (entryIsDir ? S_IFDIR : S_IFREG);
        FTKPut32(cd + 38, (mode << 16) | (entryIsDir ? 0x10 : 0)); // 0x10: MS-DOS directory bit
        FTKPut32(cd + 42, (uint32_t)headerOffset);
        [centralDirectory appendBytes:cd length:sizeof(cd)];
        [centralDirectory appendData:nameData];
    }

    if (!failure) {
        uint64_t cdOffset = pos;
        uint64_t cdSize = centralDirectory.length;
        if (cdOffset + cdSize >= 0xFFFFFFFF) {
            failure = FTKZip64Error();
        } else {
            uint8_t eocd[22] = {0};
            FTKPut32(eocd, 0x06054b50);
            FTKPut16(eocd + 8, (uint16_t)entries.count);
            FTKPut16(eocd + 10, (uint16_t)entries.count);
            FTKPut32(eocd + 12, (uint32_t)cdSize);
            FTKPut32(eocd + 16, (uint32_t)cdOffset);
            if (FTKWriteAll(out, centralDirectory.bytes, centralDirectory.length, destPath, &failure)) {
                FTKWriteAll(out, eocd, sizeof(eocd), destPath, &failure);
            }
        }
    }

    // Buffered data (and disk-full errors) only surface on close.
    if (fclose(out) != 0 && !failure) failure = FTKZipErrno(@"Failed to write", destPath);
    if (failure) {
        [fm removeItemAtPath:destPath error:nil];
        if (error) *error = failure;
        return NO;
    }
    return YES;
}
