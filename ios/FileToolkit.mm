#import <Foundation/Foundation.h>
#import <React/RCTLog.h>
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import "FileToolkit.h"
#include <zlib.h>

// ─── Foreground session delegate ──────────────────────────────────────────────
@interface FileToolkit () <NSURLSessionDownloadDelegate, NSURLSessionDataDelegate, UIDocumentInteractionControllerDelegate>
@property (nonatomic, strong) NSURLSession *fgSession;       // foreground
@property (nonatomic, strong) NSURLSession *bgSession;       // background
// downloadId → resolve/reject blocks
@property (nonatomic, strong) NSMutableDictionary *activePromises;
// downloadId → original options dict
@property (nonatomic, strong) NSMutableDictionary *downloadOptions;
// downloadId → NSURLSessionDownloadTask
@property (nonatomic, strong) NSMutableDictionary *activeTasks;
// downloadId → NSData (resume data for paused tasks)
@property (nonatomic, strong) NSMutableDictionary *resumeDataStore;
// NSURLSessionTask identifier (int) → downloadId (string)
@property (nonatomic, strong) NSMutableDictionary *taskIdMap;
// downloadId → current retry attempt count (NSNumber)
@property (nonatomic, strong) NSMutableDictionary *retryAttempts;
// Upload tracking
@property (nonatomic, strong) NSMutableDictionary *uploadPromises;     // uploadId → {resolve, reject}
@property (nonatomic, strong) NSMutableDictionary *uploadUrls;         // uploadId → URL string
@property (nonatomic, strong) NSMutableDictionary *uploadResponseData; // uploadId → NSMutableData
@property (nonatomic, strong) NSMutableDictionary *uploadTaskIdMap;    // taskIdentifier → uploadId
// Strong ref to prevent ARC deallocation during preview
@property (nonatomic, strong) UIDocumentInteractionController *documentController;
// Serial queue for thread-safe dictionary access
@property (nonatomic, strong) dispatch_queue_t syncQueue;
@property (nonatomic, assign) BOOL hasListeners;
@end

@implementation FileToolkit

RCT_EXPORT_MODULE()

- (instancetype)init {
    if (self = [super init]) {
        self.syncQueue = dispatch_queue_create("com.filetoolkit.syncQueue", DISPATCH_QUEUE_SERIAL);
        self.activePromises  = [NSMutableDictionary new];
        self.downloadOptions = [NSMutableDictionary new];
        self.activeTasks     = [NSMutableDictionary new];
        self.resumeDataStore = [NSMutableDictionary new];
        self.taskIdMap       = [NSMutableDictionary new];
        self.retryAttempts   = [NSMutableDictionary new];
        self.uploadPromises  = [NSMutableDictionary new];
        self.uploadUrls      = [NSMutableDictionary new];
        self.uploadResponseData = [NSMutableDictionary new];
        self.uploadTaskIdMap = [NSMutableDictionary new];

        // Foreground session
        NSURLSessionConfiguration *fgConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
        self.fgSession = [NSURLSession sessionWithConfiguration:fgConfig delegate:self delegateQueue:nil];

        // Background session (survives app suspension)
        NSString *bgId = [NSString stringWithFormat:@"%@.filetoolkit.background", NSBundle.mainBundle.bundleIdentifier];
        NSURLSessionConfiguration *bgConfig =
            [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:bgId];
        bgConfig.discretionary = NO;
        bgConfig.sessionSendsLaunchEvents = YES;
        self.bgSession = [NSURLSession sessionWithConfiguration:bgConfig delegate:self delegateQueue:nil];
    }
    return self;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"onDownloadProgress", @"onDownloadComplete", @"onDownloadError", @"onUploadProgress", @"onDownloadRetry"];
}

- (void)startObserving {
    self.hasListeners = YES;
}

- (void)stopObserving {
    self.hasListeners = NO;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

- (NSString *)generateDownloadId {
    return [[NSUUID UUID] UUIDString];
}

- (NSURL *)destURLForFileName:(NSString *)fileName destination:(NSString *)destType {
    NSSearchPathDirectory dirType = NSDownloadsDirectory;
    if ([destType isEqualToString:@"cache"]) {
        dirType = NSCachesDirectory;
    } else if ([destType isEqualToString:@"documents"]) {
        dirType = NSDocumentDirectory;
    }

    NSURL *dirURL = [[NSFileManager defaultManager]
        URLsForDirectory:dirType inDomains:NSUserDomainMask].firstObject;
    
    // For iOS < 16 some directories might not exist or need subfolders
    if ([destType isEqualToString:@"downloads"] && !dirURL) {
        NSURL *docsDir = [[NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        dirURL = [docsDir URLByAppendingPathComponent:@"Downloads"];
        [[NSFileManager defaultManager] createDirectoryAtURL:dirURL withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    // Use a toolkit-owned subdirectory for cache and documents to avoid
    // conflicts with the app's own files (clearCache only removes this folder)
    if ([destType isEqualToString:@"cache"] || [destType isEqualToString:@"documents"]) {
        dirURL = [dirURL URLByAppendingPathComponent:@"RNFileToolkit"];
        [[NSFileManager defaultManager] createDirectoryAtURL:dirURL withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    return [dirURL URLByAppendingPathComponent:fileName];
}

- (NSString *)calculateChecksumForPath:(NSString *)path algorithm:(NSString *)algo {
    NSInputStream *inputStream = [NSInputStream inputStreamWithFileAtPath:path];
    if (!inputStream) return nil;
    [inputStream open];

    const NSUInteger bufferSize = 65536; // 64KB
    uint8_t buffer[bufferSize];

    if ([algo isEqualToString:@"MD5"]) {
        CC_MD5_CTX ctx;
        CC_MD5_Init(&ctx);
        while ([inputStream hasBytesAvailable]) {
            NSInteger bytesRead = [inputStream read:buffer maxLength:bufferSize];
            if (bytesRead > 0) CC_MD5_Update(&ctx, buffer, (CC_LONG)bytesRead);
            else break;
        }
        [inputStream close];
        unsigned char digest[CC_MD5_DIGEST_LENGTH];
        CC_MD5_Final(digest, &ctx);
        NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [output appendFormat:@"%02x", digest[i]];
        return output;
    } else if ([algo isEqualToString:@"SHA1"]) {
        CC_SHA1_CTX ctx;
        CC_SHA1_Init(&ctx);
        while ([inputStream hasBytesAvailable]) {
            NSInteger bytesRead = [inputStream read:buffer maxLength:bufferSize];
            if (bytesRead > 0) CC_SHA1_Update(&ctx, buffer, (CC_LONG)bytesRead);
            else break;
        }
        [inputStream close];
        unsigned char digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1_Final(digest, &ctx);
        NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [output appendFormat:@"%02x", digest[i]];
        return output;
    } else {
        CC_SHA256_CTX ctx;
        CC_SHA256_Init(&ctx);
        while ([inputStream hasBytesAvailable]) {
            NSInteger bytesRead = [inputStream read:buffer maxLength:bufferSize];
            if (bytesRead > 0) CC_SHA256_Update(&ctx, buffer, (CC_LONG)bytesRead);
            else break;
        }
        [inputStream close];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &ctx);
        NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [output appendFormat:@"%02x", digest[i]];
        return output;
    }
}

- (NSString *)fileNameFromOptions:(NSDictionary *)options task:(NSURLSessionDownloadTask *)task {
    NSString *name = options[@"fileName"];
    if (!name || [name isEqualToString:@""]) {
        name = task.originalRequest.URL.lastPathComponent;
    }
    if (!name || [name isEqualToString:@""]) {
        name = @"downloaded_file";
    }
    return name;
}

// ─── download ─────────────────────────────────────────────────────────────────

- (void)download:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSString *urlString = options[@"url"];
    if (!urlString) {
        resolve(@{@"success": @NO, @"error": @"URL is missing"});
        return;
    }

    BOOL isBackground = [options[@"background"] boolValue];
    NSString *downloadId = options[@"downloadId"] ?: [self generateDownloadId];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        resolve(@{@"success": @NO, @"error": @"Invalid URL"});
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    
    // Add custom headers
    NSDictionary *headers = options[@"headers"];
    if (headers) {
        for (NSString *key in headers) {
            [request setValue:headers[key] forHTTPHeaderField:key];
        }
    }

    NSURLSession *session = isBackground ? self.bgSession : self.fgSession;
    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request];
    NSString *taskKey = [NSString stringWithFormat:@"%lu", (unsigned long)task.taskIdentifier];

    dispatch_sync(self.syncQueue, ^{
        self.taskIdMap[taskKey]       = downloadId;
        self.activeTasks[downloadId]  = task;
        self.downloadOptions[downloadId] = options;
    });
    task.taskDescription = downloadId;

    if (isBackground) {
        // Resolve immediately with the downloadId — result comes via event
        resolve(@{@"success": @YES, @"downloadId": downloadId});
    } else {
        dispatch_sync(self.syncQueue, ^{
            self.activePromises[downloadId] = @{@"resolve": resolve, @"reject": reject};
        });
    }

    [task resume];
}

// ─── pauseDownload ────────────────────────────────────────────────────────────

- (void)pauseDownload:(NSString *)downloadId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    __block NSURLSessionDownloadTask *task = nil;
    dispatch_sync(self.syncQueue, ^{
        task = self.activeTasks[downloadId];
    });
    if (!task) {
        resolve(@{@"success": @NO, @"error": @"Download not found"});
        return;
    }

    [task cancelByProducingResumeData:^(NSData *resumeData) {
        __block RCTPromiseResolveBlock originalResolve = nil;
        dispatch_sync(self.syncQueue, ^{
            if (resumeData) {
                self.resumeDataStore[downloadId] = resumeData;
            } else {
                NSDictionary *funcs = self.activePromises[downloadId];
                if (funcs) {
                    originalResolve = funcs[@"resolve"];
                }
                [self.activePromises removeObjectForKey:downloadId];
                [self.downloadOptions removeObjectForKey:downloadId];
            }
            [self.activeTasks removeObjectForKey:downloadId];
        });
        if (originalResolve) {
            originalResolve(@{@"success": @NO, @"error": @"Download could not be paused and was cancelled"});
        }
        resolve(@{@"success": resumeData ? @YES : @NO});
    }];
}

// ─── resumeDownload ───────────────────────────────────────────────────────────

- (void)resumeDownload:(NSString *)downloadId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    __block NSData *resumeData = nil;
    __block NSDictionary *options = nil;
    dispatch_sync(self.syncQueue, ^{
        resumeData = self.resumeDataStore[downloadId];
        options = self.downloadOptions[downloadId];
    });
    if (!resumeData) {
        resolve(@{@"success": @NO, @"error": @"No resume data — download was not paused or was cancelled"});
        return;
    }

    BOOL isBackground = [options[@"background"] boolValue];
    NSURLSession *session = isBackground ? self.bgSession : self.fgSession;

    NSURLSessionDownloadTask *task = [session downloadTaskWithResumeData:resumeData];
    NSString *taskKey = [NSString stringWithFormat:@"%lu", (unsigned long)task.taskIdentifier];

    dispatch_sync(self.syncQueue, ^{
        self.taskIdMap[taskKey]      = downloadId;
        self.activeTasks[downloadId] = task;
        [self.resumeDataStore removeObjectForKey:downloadId];
    });

    [task resume];
    resolve(@{@"success": @YES});
}

// ─── cancelDownload ───────────────────────────────────────────────────────────

- (void)cancelDownload:(NSString *)downloadId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    __block NSURLSessionDownloadTask *task = nil;
    __block NSDictionary *funcs = nil;
    dispatch_sync(self.syncQueue, ^{
        task = self.activeTasks[downloadId];
        funcs = self.activePromises[downloadId];
        if (task) {
            [self.activeTasks removeObjectForKey:downloadId];
        }
        [self.resumeDataStore removeObjectForKey:downloadId];
        [self.activePromises  removeObjectForKey:downloadId];
        [self.downloadOptions removeObjectForKey:downloadId];
        [self.retryAttempts   removeObjectForKey:downloadId];
    });
    if (funcs) {
        RCTPromiseResolveBlock dlResolve = funcs[@"resolve"];
        if (dlResolve) dlResolve(@{@"success": @NO, @"error": @"Cancelled"});
    }
    if (task) {
        [task cancel];
    }
    resolve(@{@"success": @YES});
}

// ─── getCachedFiles ───────────────────────────────────────────────────────────

- (void)getCachedFiles:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSMutableArray *result = [NSMutableArray new];

    // Scan all three directories: Downloads, Caches, Documents
    NSURL *downloadsDir = [[NSFileManager defaultManager]
        URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
    if (!downloadsDir) {
        NSURL *fallbackDocs = [[NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        downloadsDir = [fallbackDocs URLByAppendingPathComponent:@"Downloads"];
    }
    NSURL *cacheDir = [[[NSFileManager defaultManager]
        URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"RNFileToolkit"];
    NSURL *docsDir = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"RNFileToolkit"];

    NSMutableArray<NSURL *> *dirs = [NSMutableArray new];
    if (downloadsDir) [dirs addObject:downloadsDir];
    if (cacheDir) [dirs addObject:cacheDir];
    if (docsDir) [dirs addObject:docsDir];

    for (NSURL *dirURL in dirs) {
        NSArray<NSURL *> *files = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:dirURL
            includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLContentModificationDateKey, NSURLIsDirectoryKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles
            error:nil];

        for (NSURL *fileURL in files) {
            NSNumber *isDir;
            [fileURL getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
            if ([isDir boolValue]) continue; // skip directories

            NSNumber *size;
            NSDate *modDate;
            [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            [fileURL getResourceValue:&modDate forKey:NSURLContentModificationDateKey error:nil];
            [result addObject:@{
                @"fileName": fileURL.lastPathComponent,
                @"filePath": fileURL.path,
                @"size":     size ?: @0,
                @"modifiedAt": @((long long)([modDate timeIntervalSince1970] * 1000))
            }];
        }
    }

    resolve(@{@"success": @YES, @"files": result});
}

// ─── deleteFile ───────────────────────────────────────────────────────────────

- (void)deleteFile:(NSString *)filePath resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSError *error;
    [[NSFileManager defaultManager] removeItemAtPath:filePath error:&error];
    if (error) {
        resolve(@{@"success": @NO, @"error": error.localizedDescription});
    } else {
        resolve(@{@"success": @YES});
    }
}

// ─── clearCache ───────────────────────────────────────────────────────────────

- (void)clearCache:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    // Only clear the toolkit-owned subdirectory — never touch the app's own files or Downloads
    NSURL *cacheDir = [[NSFileManager defaultManager]
        URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *docsDir = [[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;

    NSMutableArray<NSURL *> *dirs = [NSMutableArray new];
    if (cacheDir) [dirs addObject:[cacheDir URLByAppendingPathComponent:@"RNFileToolkit"]];
    if (docsDir) [dirs addObject:[docsDir URLByAppendingPathComponent:@"RNFileToolkit"]];

    for (NSURL *dirURL in dirs) {
        NSArray<NSURL *> *files = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:dirURL
            includingPropertiesForKeys:nil
            options:NSDirectoryEnumerationSkipsHiddenFiles
            error:nil];

        for (NSURL *fileURL in files) {
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
        }
    }
    resolve(@{@"success": @YES});
}

// ─── exists ──────────────────────────────────────────────────────────────────

- (void)exists:(NSString *)filePath resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    @try {
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:filePath];
        resolve(@{
            @"success": @YES,
            @"exists": @(exists)
        });
    } @catch (NSException *exception) {
        resolve(@{
            @"success": @NO,
            @"error": exception.reason ?: @"EXISTS_ERROR"
        });
    }
}

// ─── stat ────────────────────────────────────────────────────────────────────

- (void)stat:(NSString *)filePath resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        BOOL exists = [fm fileExistsAtPath:filePath isDirectory:&isDir];
        if (!exists) {
            resolve(@{@"success": @NO, @"error": @"Path does not exist"});
            return;
        }

        NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
        NSNumber *size = attrs[NSFileSize] ?: @0;
        NSDate *modDate = attrs[NSFileModificationDate] ?: [NSDate dateWithTimeIntervalSince1970:0];

        resolve(@{
            @"success": @YES,
            @"stat": @{
                @"path": filePath,
                @"name": [filePath lastPathComponent] ?: @"",
                @"isDir": @(isDir),
                @"size": isDir ? @0 : size,
                @"modified": @((long long)([modDate timeIntervalSince1970] * 1000))
            }
        });
    } @catch (NSException *exception) {
        resolve(@{
            @"success": @NO,
            @"error": exception.reason ?: @"STAT_ERROR"
        });
    }
}

// ─── readFile ────────────────────────────────────────────────────────────────

- (void)readFile:(NSString *)filePath encoding:(NSString *)encoding resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:filePath isDirectory:&isDir] || isDir) {
        resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"File not found: %@", filePath]});
        return;
    }

    // Safety check: reject files > 50MB to prevent crashing the RN bridge
    NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
    unsigned long long fileSize = [attrs fileSize];
    if (fileSize > 50 * 1024 * 1024) {
        resolve(@{@"success": @NO, @"error": @"File exceeds 50MB limit for readFile. Use streaming or base64 encoding for large files."});
        return;
    }

    NSError *readError = nil;
    NSData *raw = [NSData dataWithContentsOfFile:filePath options:0 error:&readError];
    if (!raw || readError) {
        resolve(@{@"success": @NO, @"error": readError.localizedDescription ?: @"READ_FILE_ERROR"});
        return;
    }

    NSString *dataString = nil;
    if ([[encoding lowercaseString] isEqualToString:@"base64"]) {
        dataString = [raw base64EncodedStringWithOptions:0];
    } else {
        dataString = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
        if (!dataString) {
            resolve(@{@"success": @NO, @"error": @"File is not valid UTF-8. Try base64 encoding."});
            return;
        }
    }

    resolve(@{
        @"success": @YES,
        @"data": dataString ?: @""
    });
}

// ─── writeFile ───────────────────────────────────────────────────────────────

- (void)writeFile:(NSString *)filePath data:(NSString *)data encoding:(NSString *)encoding resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *parent = [filePath stringByDeletingLastPathComponent];
    if (parent.length > 0) {
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSError *writeError = nil;
    BOOL success = NO;

    if ([[encoding lowercaseString] isEqualToString:@"base64"]) {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:data options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!decoded) {
            resolve(@{@"success": @NO, @"error": @"Invalid base64 string"});
            return;
        }
        success = [decoded writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
    } else {
        success = [data writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    }

    if (!success || writeError) {
        resolve(@{@"success": @NO, @"error": writeError.localizedDescription ?: @"WRITE_FILE_ERROR"});
        return;
    }

    resolve(@{@"success": @YES});
}

// ─── copyFile ────────────────────────────────────────────────────────────────

- (void)copyFile:(NSString *)fromPath toPath:(NSString *)toPath resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:fromPath isDirectory:&isDir] || isDir) {
        resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"Source file not found: %@", fromPath]});
        return;
    }

    NSString *parent = [toPath stringByDeletingLastPathComponent];
    if (parent.length > 0) {
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    }

    [fm removeItemAtPath:toPath error:nil];
    NSError *copyError = nil;
    BOOL success = [fm copyItemAtPath:fromPath toPath:toPath error:&copyError];

    if (!success || copyError) {
        resolve(@{@"success": @NO, @"error": copyError.localizedDescription ?: @"COPY_FILE_ERROR"});
        return;
    }

    resolve(@{@"success": @YES});
}

// ─── moveFile ────────────────────────────────────────────────────────────────

- (void)moveFile:(NSString *)fromPath toPath:(NSString *)toPath resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:fromPath]) {
        resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"Source path not found: %@", fromPath]});
        return;
    }

    NSString *parent = [toPath stringByDeletingLastPathComponent];
    if (parent.length > 0) {
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    }

    [fm removeItemAtPath:toPath error:nil];
    NSError *moveError = nil;
    BOOL success = [fm moveItemAtPath:fromPath toPath:toPath error:&moveError];

    if (!success || moveError) {
        resolve(@{@"success": @NO, @"error": moveError.localizedDescription ?: @"MOVE_FILE_ERROR"});
        return;
    }

    resolve(@{@"success": @YES});
}

// ─── mkdir ───────────────────────────────────────────────────────────────────

- (void)mkdir:(NSString *)dirPath resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:dirPath isDirectory:&isDir];
    if (exists && isDir) {
        resolve(@{@"success": @YES});
        return;
    }

    NSError *mkdirError = nil;
    BOOL success = [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&mkdirError];
    if (!success || mkdirError) {
        resolve(@{@"success": @NO, @"error": mkdirError.localizedDescription ?: @"MKDIR_ERROR"});
        return;
    }

    resolve(@{@"success": @YES});
}

// ─── ls ──────────────────────────────────────────────────────────────────────

- (void)ls:(NSString *)dirPath resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir) {
        resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"Directory not found: %@", dirPath]});
        return;
    }

    NSError *lsError = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dirPath error:&lsError];
    if (lsError) {
        resolve(@{@"success": @NO, @"error": lsError.localizedDescription ?: @"LS_ERROR"});
        return;
    }

    resolve(@{
        @"success": @YES,
        @"entries": entries ?: @[]
    });
}

// ─── getBackgroundDownloads ───────────────────────────────────────────────────

- (void)getBackgroundDownloads:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    [self.bgSession getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        NSMutableArray *results = [NSMutableArray new];
        for (NSURLSessionDownloadTask *task in downloadTasks) {
            NSString *downloadId = task.taskDescription ?: @"";
            NSString *url = task.originalRequest.URL.absoluteString ?: @"";
            
            int progress = 0;
            if (task.countOfBytesExpectedToReceive > 0) {
                progress = (int)((task.countOfBytesReceived * 100) / task.countOfBytesExpectedToReceive);
            }
            
            [results addObject:@{
                @"downloadId": downloadId,
                @"url": url,
                @"status": @(task.state), // 0=Running, 1=Suspended, 2=Canceling, 3=Completed
                @"progress": @(progress)
            }];
        }
        resolve(@{@"success": @YES, @"downloads": results});
    }];
}

// ─── NSURLSession delegates ───────────────────────────────────────────────────

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite > 0) {
        int progress = (int)((totalBytesWritten * 100) / totalBytesExpectedToWrite);
        NSString *taskKey = [NSString stringWithFormat:@"%lu", (unsigned long)downloadTask.taskIdentifier];
        NSString *url = downloadTask.originalRequest.URL.absoluteString ?: @"";

        __weak typeof(self) weakSelf = self;
        dispatch_async(self.syncQueue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *downloadId = strongSelf.taskIdMap[taskKey];
            if (!downloadId) return;
            
            if (strongSelf.hasListeners) {
                [strongSelf sendEventWithName:@"onDownloadProgress"
                                   body:@{
                                       @"url": url,
                                       @"downloadId": downloadId,
                                       @"progress": @(progress),
                                       @"bytesDownloaded": @(totalBytesWritten),
                                       @"totalBytes": @(totalBytesExpectedToWrite)
                                   }];
            }
        });
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSString *taskKey = [NSString stringWithFormat:@"%lu", (unsigned long)downloadTask.taskIdentifier];
    __block NSString *downloadId = nil;
    __block NSDictionary *options = nil;
    dispatch_sync(self.syncQueue, ^{
        downloadId = self.taskIdMap[taskKey];
        if (downloadId) {
            options = self.downloadOptions[downloadId];
        }
    });
    if (!downloadId) return;

    NSString *fileName = [self fileNameFromOptions:options task:downloadTask];
    NSString *destType = options[@"destination"] ?: @"downloads";
    NSURL *destURL = [self destURLForFileName:fileName destination:destType];

    NSError *error;
    [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];
    [[NSFileManager defaultManager] moveItemAtURL:location toURL:destURL error:&error];

    NSDictionary *resultDict;
    BOOL isError = NO;
    if (error) {
        isError = YES;
        resultDict = @{@"success": @NO, @"downloadId": downloadId, @"error": error.localizedDescription};
    } else {
        // Checksum verification
        NSDictionary *checksum = options[@"checksum"];
        if (checksum) {
            NSString *expectedHash = checksum[@"hash"];
            NSString *algo = checksum[@"algorithm"] ?: @"MD5";
            NSString *actualHash = [self calculateChecksumForPath:destURL.path algorithm:algo.uppercaseString];
            if (![actualHash.lowercaseString isEqualToString:expectedHash.lowercaseString]) {
                [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];
                isError = YES;
                resultDict = @{
                    @"success": @NO,
                    @"downloadId": downloadId,
                    @"error": [NSString stringWithFormat:@"CHECKSUM_MISMATCH: expected %@, got %@", expectedHash, actualHash]
                };
            } else {
                resultDict = @{@"success": @YES, @"downloadId": downloadId, @"filePath": destURL.path};
            }
        } else {
            resultDict = @{@"success": @YES, @"downloadId": downloadId, @"filePath": destURL.path};
        }
    }

    __block NSDictionary *funcs = nil;
    BOOL isBackground = [options[@"background"] boolValue];
    dispatch_sync(self.syncQueue, ^{
        funcs = self.activePromises[downloadId];
    });

    if (funcs && !isBackground) {
        // Foreground: resolve the promise
        RCTPromiseResolveBlock resolve = funcs[@"resolve"];
        resolve(resultDict);
        // Also emit the error event for foreground failures so global listeners fire
        // consistently across platforms (mirrors Android behaviour).
        if (isError && self.hasListeners) {
            [self sendEventWithName:@"onDownloadError" body:resultDict];
        }
    } else {
        // Background: fire the correct event based on isError flag
        NSString *event = isError ? @"onDownloadError" : @"onDownloadComplete";
        if (self.hasListeners) {
            [self sendEventWithName:event body:resultDict];
        }
    }

    dispatch_sync(self.syncQueue, ^{
        [self.activePromises  removeObjectForKey:downloadId];
        [self.downloadOptions removeObjectForKey:downloadId];
        [self.activeTasks     removeObjectForKey:downloadId];
        [self.taskIdMap       removeObjectForKey:taskKey];
        [self.retryAttempts   removeObjectForKey:downloadId];
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    NSString *taskKey = [NSString stringWithFormat:@"%lu", (unsigned long)task.taskIdentifier];

    // ── Upload task completion ─────────────────────────────────────────────────
    __block NSString *uploadId = nil;
    __block NSDictionary *uploadFuncs = nil;
    __block NSData *uploadRespData = nil;
    dispatch_sync(self.syncQueue, ^{
        uploadId = self.uploadTaskIdMap[taskKey];
        if (uploadId) {
            uploadFuncs = self.uploadPromises[uploadId];
            uploadRespData = self.uploadResponseData[uploadId];
        }
    });
    if (uploadId) {
        RCTPromiseResolveBlock uploadResolve = uploadFuncs[@"resolve"];
        NSString *tempFile = uploadFuncs[@"tempFile"];

        if (tempFile) {
            [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
        }

        if (error) {
            if (uploadResolve) uploadResolve(@{@"success": @NO, @"error": error.localizedDescription, @"uploadId": uploadId});
        } else {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)task.response;
            NSData *responseData = uploadRespData ?: [NSData data];
            NSString *respString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] ?: @"";

            if (uploadResolve) uploadResolve(@{
                @"success": @(httpResponse.statusCode >= 200 && httpResponse.statusCode < 300),
                @"status": @(httpResponse.statusCode),
                @"data": respString,
                @"uploadId": uploadId
            });
        }

        dispatch_sync(self.syncQueue, ^{
            // Guard against double-resolution in upload
            if (self.uploadPromises[uploadId]) {
                [self.uploadPromises removeObjectForKey:uploadId];
                [self.uploadUrls removeObjectForKey:uploadId];
                [self.uploadResponseData removeObjectForKey:uploadId];
                [self.uploadTaskIdMap removeObjectForKey:taskKey];
            } else {
                uploadId = nil; // Already resolved
            }
        });
        if (!uploadId) return;
    }

    // ── Download task error handling ───────────────────────────────────────
    if (!error) return;
    // Ignore cancellation — but still clean up taskIdMap to prevent memory leak
    if (error.code == NSURLErrorCancelled) {
        dispatch_sync(self.syncQueue, ^{
            [self.taskIdMap removeObjectForKey:taskKey];
        });
        return;
    }

    __block NSString *downloadId = nil;
    __block NSDictionary *options = nil;
    __block NSInteger currentAttempt = 0;
    dispatch_sync(self.syncQueue, ^{
        downloadId = self.taskIdMap[taskKey];
        if (downloadId) {
            options = self.downloadOptions[downloadId];
            currentAttempt = [self.retryAttempts[downloadId] integerValue];
        }
    });
    if (!downloadId) return;

    BOOL isBackground = [options[@"background"] boolValue];

    // ── Retry logic ────────────────────────────────────────────────────
    NSDictionary *retryConfig = options[@"retry"];
    NSInteger maxAttempts = retryConfig ? [retryConfig[@"attempts"] integerValue] : 0;
    NSInteger baseDelay   = retryConfig ? ([retryConfig[@"delay"] integerValue] ?: 1000) : 1000;

    // Remove old task mapping — will be replaced on retry
    dispatch_sync(self.syncQueue, ^{
        [self.taskIdMap  removeObjectForKey:taskKey];
        [self.activeTasks removeObjectForKey:downloadId];
    });

    if (currentAttempt < maxAttempts) {
        // Schedule a retry
        NSInteger nextAttempt = currentAttempt + 1;
        dispatch_sync(self.syncQueue, ^{
            self.retryAttempts[downloadId] = @(nextAttempt);
        });

        NSInteger shiftBits = currentAttempt < 15 ? currentAttempt : 15;
        NSInteger delayMs = MIN(baseDelay * (1 << shiftBits), (NSInteger)30000);

        // Emit retry event so JS onRetry callback is called
        if (self.hasListeners) {
            [self sendEventWithName:@"onDownloadRetry" body:@{
                @"downloadId": downloadId,
                @"url": options[@"url"] ?: @"",
                @"attempt": @(nextAttempt),
                @"error": error.localizedDescription ?: @""
            }];
        }

        __weak typeof(self) weakSelf = self;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
            ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;

                NSString *urlString = options[@"url"];
                if (!urlString) return;
                NSURL *url = [NSURL URLWithString:urlString];
                if (!url) return;
                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
                NSDictionary *headers = options[@"headers"];
                if (headers) {
                    for (NSString *key in headers) {
                        [request setValue:headers[key] forHTTPHeaderField:key];
                    }
                }
                NSURLSession *sess = isBackground ? strongSelf.bgSession : strongSelf.fgSession;
                NSURLSessionDownloadTask *newTask = [sess downloadTaskWithRequest:request];
                NSString *newTaskKey = [NSString stringWithFormat:@"%lu",
                                        (unsigned long)newTask.taskIdentifier];
                dispatch_sync(strongSelf.syncQueue, ^{
                    strongSelf.taskIdMap[newTaskKey]      = downloadId;
                    strongSelf.activeTasks[downloadId]   = newTask;
                });
                newTask.taskDescription              = downloadId;
                [newTask resume];
            }
        );
        return; // Don't resolve promise yet — retry is in flight
    }

    // ── No more retries — normal error path ──────────────────────────────
    NSDictionary *errDict = @{@"success": @NO, @"downloadId": downloadId, @"error": error.localizedDescription};

    __block NSDictionary *funcs = nil;
    dispatch_sync(self.syncQueue, ^{
        [self.retryAttempts removeObjectForKey:downloadId];
        funcs = self.activePromises[downloadId];
    });
    // Always emit the event so global onDownloadError listeners fire on both platforms.
    if (self.hasListeners) {
        [self sendEventWithName:@"onDownloadError" body:errDict];
    }
    if (funcs && !isBackground) {
        RCTPromiseResolveBlock resolve = funcs[@"resolve"];
        resolve(errDict);
    }

    dispatch_sync(self.syncQueue, ^{
        [self.activePromises  removeObjectForKey:downloadId];
        [self.downloadOptions removeObjectForKey:downloadId];
    });
}

// ─── Upload progress delegate ────────────────────────────────────────────────

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    if (totalBytesExpectedToSend > 0) {
        NSString *taskKey = [NSString stringWithFormat:@"%lu", (unsigned long)task.taskIdentifier];
        int progress = (int)((totalBytesSent * 100) / totalBytesExpectedToSend);
        
        __weak typeof(self) weakSelf = self;
        dispatch_async(self.syncQueue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            NSString *uploadId = strongSelf.uploadTaskIdMap[taskKey];
            if (uploadId) {
                NSString *url = strongSelf.uploadUrls[uploadId] ?: @"";
                if (strongSelf.hasListeners) {
                    [strongSelf sendEventWithName:@"onUploadProgress"
                                       body:@{@"url": url, @"uploadId": uploadId, @"progress": @(progress)}];
                }
            }
        });
    }
}

// ─── Upload response data accumulation ───────────────────────────────────────

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    NSString *taskKey = [NSString stringWithFormat:@"%lu", (unsigned long)dataTask.taskIdentifier];
    __block NSString *uploadId = nil;
    dispatch_sync(self.syncQueue, ^{
        uploadId = self.uploadTaskIdMap[taskKey];
    });
    if (!uploadId) return;

    dispatch_sync(self.syncQueue, ^{
        NSMutableData *responseData = self.uploadResponseData[uploadId];
        if (!responseData) {
            responseData = [NSMutableData new];
            self.uploadResponseData[uploadId] = responseData;
        }
        [responseData appendData:data];
    });
}

// ─── TurboModule ──────────────────────────────────────────────────────────────

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeFileToolkitSpecJSI>(params);
}

+ (NSString *)moduleName
{
  return @"FileToolkit";
}

// ─── upload ───────────────────────────────────────────────────────────────────

- (void)upload:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSString *urlString = options[@"url"];
    NSString *filePath  = options[@"filePath"];
    if (!urlString || !filePath) {
        resolve(@{@"success": @NO, @"error": @"URL or filePath is missing"});
        return;
    }

    NSString *uploadId = options[@"uploadId"] ?: [self generateDownloadId];
    NSString *fieldName = options[@"fieldName"] ?: @"file";
    NSDictionary *headers = options[@"headers"];
    NSDictionary *params  = options[@"parameters"];
    
    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    [request setHTTPMethod:@"POST"];
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    
    if (headers) {
        for (NSString *key in headers) {
            [request setValue:headers[key] forHTTPHeaderField:key];
        }
    }

    // Create a temporary file to avoid OutOfMemory crash for large uploads
    NSString *tempFileName = [NSString stringWithFormat:@"upload_%@.tmp", [[NSUUID UUID] UUIDString]];
    NSString *tempFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempFileName];
    
    [[NSFileManager defaultManager] createFileAtPath:tempFilePath contents:nil attributes:nil];
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:tempFilePath];
    if (!fileHandle) {
        resolve(@{@"success": @NO, @"error": @"Failed to create temp file for upload"});
        return;
    }

    NSMutableData *preamble = [NSMutableData data];
    [params enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        [preamble appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [preamble appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", key] dataUsingEncoding:NSUTF8StringEncoding]];
        [preamble appendData:[[NSString stringWithFormat:@"%@\r\n", value] dataUsingEncoding:NSUTF8StringEncoding]];
    }];

    NSString *fileName = [filePath lastPathComponent];
    [preamble appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [preamble appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n", fieldName, fileName] dataUsingEncoding:NSUTF8StringEncoding]];
    [preamble appendData:[@"Content-Type: application/octet-stream\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    
    [fileHandle writeData:preamble];

    // Stream the actual file content to the temp file
    NSInputStream *inputStream = [NSInputStream inputStreamWithFileAtPath:filePath];
    [inputStream open];
    uint8_t buffer[32768]; // 32KB chunks
    while ([inputStream hasBytesAvailable]) {
        NSInteger bytesRead = [inputStream read:buffer maxLength:sizeof(buffer)];
        if (bytesRead > 0) {
            [fileHandle writeData:[NSData dataWithBytes:buffer length:bytesRead]];
        } else if (bytesRead < 0) {
            break;
        }
    }
    [inputStream close];

    NSMutableData *postamble = [NSMutableData data];
    [postamble appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [postamble appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [fileHandle writeData:postamble];
    [fileHandle closeFile];

    NSURL *tempFileURL = [NSURL fileURLWithPath:tempFilePath];

    // Use delegate-based session for upload progress support with fromFile: instead of fromData:
    NSURLSessionUploadTask *task = [self.fgSession uploadTaskWithRequest:request fromFile:tempFileURL];
    NSString *taskKey = [NSString stringWithFormat:@"%lu", (unsigned long)task.taskIdentifier];

    dispatch_sync(self.syncQueue, ^{
        self.uploadTaskIdMap[taskKey] = uploadId;
        self.uploadPromises[uploadId] = @{
            @"resolve": resolve, 
            @"reject": reject, 
            @"tempFile": tempFilePath
        };
        self.uploadUrls[uploadId] = urlString;
    });

    [task resume];
}

// ─── saveBase64AsFile ─────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(saveBase64AsFile:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    NSString *base64String = options[@"base64Data"];
    if (!base64String || base64String.length == 0) {
        resolve(@{@"success": @NO, @"error": @"base64Data is required"});
        return;
    }
    
    NSString *fileName = options[@"fileName"];
    if (!fileName || fileName.length == 0) {
        fileName = [NSString stringWithFormat:@"base64_file_%lld", (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
    }
    
    NSString *destination = options[@"destination"] ?: @"downloads";
    
    // Decode base64
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:base64String options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!decodedData) {
        resolve(@{@"success": @NO, @"error": @"Invalid base64 string"});
        return;
    }
    
    NSURL *destURL = [self destURLForFileName:fileName destination:destination];
    NSError *writeError = nil;
    BOOL success = [decodedData writeToURL:destURL options:NSDataWritingAtomic error:&writeError];
    
    if (!success || writeError) {
        resolve(@{@"success": @NO, @"error": writeError ? writeError.localizedDescription : @"Failed to write file"});
        return;
    }
    
    resolve(@{
        @"success": @YES,
        @"filePath": destURL.path
    });
}

// ─── urlToBase64 ──────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(urlToBase64:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    NSString *urlString = options[@"url"];
    if (!urlString || urlString.length == 0) {
        resolve(@{@"success": @NO, @"error": @"URL is required"});
        return;
    }
    
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        resolve(@{@"success": @NO, @"error": @"Invalid URL"});
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    
    // Add custom headers if provided
    NSDictionary *headers = options[@"headers"];
    if (headers) {
        for (NSString *key in headers) {
            [request setValue:headers[key] forHTTPHeaderField:key];
        }
    }
    
    // Create ephemeral session instead of using sharedSession
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            resolve(@{@"success": @NO, @"error": error.localizedDescription});
            return;
        }
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]});
            return;
        }
        
        if (!data || data.length == 0) {
            resolve(@{@"success": @NO, @"error": @"No data received"});
            return;
        }
        
        // Get MIME type from response
        NSString *mimeType = httpResponse.MIMEType ?: @"application/octet-stream";
        
        // Encode to base64
        NSString *base64String = [data base64EncodedStringWithOptions:0];
        NSString *dataUri = [NSString stringWithFormat:@"data:%@;base64,%@", mimeType, base64String];
        
        resolve(@{
            @"success": @YES,
            @"base64": base64String,
            @"mimeType": mimeType,
            @"dataUri": dataUri
        });
    }];
    
    [task resume];
    [session finishTasksAndInvalidate];
}

// ─── topMostViewController (works with both AppDelegate-window and SceneDelegate) ─────

- (UIViewController *)topMostViewController {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                window = ((UIWindowScene *)scene).windows.firstObject;
                break;
            }
        }
    }
    if (!window) {
        window = [UIApplication sharedApplication].delegate.window;
    }
    UIViewController *rootVC = window.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    return rootVC;
}

// ─── shareFile ────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(shareFile:(NSString *)filePath
                  options:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    if (!filePath || filePath.length == 0) {
        resolve(@{@"success": @NO, @"error": @"File path is required"});
        return;
    }
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"File not found: %@", filePath]});
        return;
    }
    
    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *rootViewController = [self topMostViewController];
        if (!rootViewController) {
            resolve(@{@"success": @NO, @"error": @"No visible view controller found"});
            return;
        }
        
        NSArray *itemsToShare = @[fileURL];
        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:itemsToShare applicationActivities:nil];
        
        // For iPad, set the popover presentation controller
        if (activityVC.popoverPresentationController) {
            activityVC.popoverPresentationController.sourceView = rootViewController.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(rootViewController.view.bounds.size.width / 2,
                                                                              rootViewController.view.bounds.size.height / 2,
                                                                              0, 0);
            activityVC.popoverPresentationController.permittedArrowDirections = 0;
        }
        
        activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
            if (activityError) {
                resolve(@{@"success": @NO, @"error": activityError.localizedDescription});
            } else {
                resolve(@{@"success": @YES, @"completed": @(completed)});
            }
        };
        
        [rootViewController presentViewController:activityVC animated:YES completion:nil];
    });
}

// ─── openFile ─────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(openFile:(NSString *)filePath
                  mimeType:(NSString *)mimeType
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    if (!filePath || filePath.length == 0) {
        resolve(@{@"success": @NO, @"error": @"File path is required"});
        return;
    }
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"File not found: %@", filePath]});
        return;
    }
    
    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *rootViewController = [self topMostViewController];
        if (!rootViewController) {
            resolve(@{@"success": @NO, @"error": @"No visible view controller found"});
            return;
        }
        
        // Use UIDocumentInteractionController for opening files
        self.documentController = [UIDocumentInteractionController interactionControllerWithURL:fileURL];
        self.documentController.delegate = (id<UIDocumentInteractionControllerDelegate>)self;
        
        BOOL canOpen = [self.documentController presentPreviewAnimated:YES];
        
        if (!canOpen) {
            // Fallback: Try to open with options menu
            canOpen = [self.documentController presentOptionsMenuFromRect:CGRectMake(rootViewController.view.bounds.size.width / 2,
                                                                                 rootViewController.view.bounds.size.height / 2,
                                                                                 0, 0)
                                                              inView:rootViewController.view
                                                            animated:YES];
        }
        
        if (canOpen) {
            resolve(@{@"success": @YES});
        } else {
            resolve(@{@"success": @NO, @"error": @"No app found to open this file"});
        }
    });
}

// UIDocumentInteractionControllerDelegate method
- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller {
    return [self topMostViewController];
}

// ─── Unzip ────────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(unzip:(NSString *)sourcePath
                  destDir:(NSString *)destDir
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
        NSURL *destURL   = [NSURL fileURLWithPath:destDir];

        // Ensure destination directory exists
        NSError *mkdirErr = nil;
        [fm createDirectoryAtURL:destURL withIntermediateDirectories:YES attributes:nil error:&mkdirErr];

        // Use NSData + manual zip parsing via Foundation's built-in zip support
        // (available via -[NSFileManager createDirectoryAtPath] + zlib read loop)
        // We use the C-level zlib (linked via s.libraries = 'z') through minizip-style reading.
        // Simpler approach: use the Objective-C Archive API available on all iOS versions.

        // Primary path: try SSZipArchive-style pure-C zlib approach
        // Since we only have zlib (no minizip headers), we'll use NSData + the public
        // Archive Utility API: ziparchive is not available, but we CAN use:
        //   -[NSFileWrapper] or the Archive framework (iOS 16+).
        // Most reliable zero-dependency path: pipe through /usr/bin/unzip subprocess.
        // On iOS that binary doesn't exist. So we use the ZipFoundation-compatible
        // pure-Foundation approach using NSInputStream with a known zip local-file header parser.

        // ── Pure-Foundation zip reader (no third-party, no subprocess) ──────────
        NSError *readError = nil;
        NSData *zipData = [NSData dataWithContentsOfFile:sourcePath options:NSDataReadingMappedIfSafe error:&readError];
        if (!zipData) {
            resolve(@{@"success": @NO, @"error": readError.localizedDescription ?: @"Cannot read zip file"});
            return;
        }

        NSMutableArray<NSString *> *extractedFiles = [NSMutableArray new];
        NSError *extractError = nil;
        BOOL ok = [self extractZipData:zipData toDirectory:destDir extractedFiles:extractedFiles error:&extractError];

        if (ok) {
            resolve(@{@"success": @YES, @"destDir": destDir, @"files": extractedFiles});
        } else {
            resolve(@{@"success": @NO, @"error": extractError.localizedDescription ?: @"UNZIP_ERROR"});
        }
    });
}

/**
 * Pure-Foundation ZIP extractor.
 * Parses the ZIP local file headers (signature 0x04034b50) sequentially.
 * Uses zlib inflate (deflate method) and store (method 0) — the two methods
 * used by virtually every ZIP file in the wild.
 * No third-party library required; zlib is a system framework (s.libraries = 'z').
 */
- (BOOL)extractZipData:(NSData *)data
           toDirectory:(NSString *)destDir
        extractedFiles:(NSMutableArray<NSString *> *)extractedFiles
                 error:(NSError **)error
{
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length    = data.length;
    NSUInteger offset    = 0;
    NSFileManager *fm    = [NSFileManager defaultManager];

    while (offset + 30 <= length) {
        // Local file header signature
        uint32_t sig = 0;
        memcpy(&sig, bytes + offset, 4);
        if (sig != 0x04034b50) break; // no more local headers

        uint16_t flags         = 0; memcpy(&flags,         bytes + offset + 6,  2);
        uint16_t method        = 0; memcpy(&method,        bytes + offset + 8,  2);
        uint32_t crc32val      = 0; memcpy(&crc32val,      bytes + offset + 14, 4);
        uint32_t compSize      = 0; memcpy(&compSize,      bytes + offset + 18, 4);
        uint32_t uncompSize    = 0; memcpy(&uncompSize,    bytes + offset + 22, 4);
        uint16_t fileNameLen   = 0; memcpy(&fileNameLen,   bytes + offset + 26, 2);
        uint16_t extraFieldLen = 0; memcpy(&extraFieldLen, bytes + offset + 28, 2);

        // Little-endian on all platforms
        flags         = CFSwapInt16LittleToHost(flags);
        method        = CFSwapInt16LittleToHost(method);
        compSize      = CFSwapInt32LittleToHost(compSize);
        uncompSize    = CFSwapInt32LittleToHost(uncompSize);
        fileNameLen   = CFSwapInt16LittleToHost(fileNameLen);
        extraFieldLen = CFSwapInt16LittleToHost(extraFieldLen);

        BOOL hasDataDescriptor = (flags & (1 << 3)) != 0;

        offset += 30;
        if (offset + fileNameLen > length) break;

        NSString *fileName = [[NSString alloc] initWithBytes:bytes + offset
                                                       length:fileNameLen
                                                     encoding:NSUTF8StringEncoding];
        if (!fileName) fileName = [[NSString alloc] initWithBytes:bytes + offset
                                                            length:fileNameLen
                                                          encoding:NSISOLatin1StringEncoding];
        offset += fileNameLen + extraFieldLen;

        if (!fileName) break; // corrupt ZIP
        if (!hasDataDescriptor && offset + compSize > length) {
            offset += compSize;
            continue;
        }

        NSString *destPath = [destDir stringByAppendingPathComponent:fileName];

        // Protect against zip-slip/path traversal (e.g. ../../outside.txt)
        NSString *standardizedDestDir = [destDir stringByStandardizingPath];
        NSString *standardizedDestPath = [destPath stringByStandardizingPath];
        NSString *safePrefix = [standardizedDestDir stringByAppendingString:@"/"];
        if (![standardizedDestPath isEqualToString:standardizedDestDir] &&
            ![standardizedDestPath hasPrefix:safePrefix]) {
            if (error) {
                *error = [NSError errorWithDomain:@"RNFileToolkit"
                                             code:-100
                                         userInfo:@{NSLocalizedDescriptionKey: @"ZIP entry has invalid path"}];
            }
            return NO;
        }

        // Directory entry
        if ([fileName hasSuffix:@"/"]) {
            [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }

        // Ensure parent directory
        NSString *parentDir = [destPath stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];

        const uint8_t *compData = bytes + offset;

        if (method == 0) {
            if (hasDataDescriptor) {
                if (error) *error = [NSError errorWithDomain:@"RNFileToolkit" code:-5
                    userInfo:@{NSLocalizedDescriptionKey: @"STORE method with Data Descriptor not supported"}];
                return NO;
            }
            // Store (no compression)
            NSData *fileData = [NSData dataWithBytes:compData length:compSize];
            // Verify CRC32 before writing
            uint32_t expectedCRC = CFSwapInt32LittleToHost(crc32val);
            uLong actualCRC = crc32(0L, (const Bytef *)fileData.bytes, (uInt)fileData.length);
            if ((uint32_t)actualCRC != expectedCRC) {
                if (error) *error = [NSError errorWithDomain:@"RNFileToolkit" code:-3
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"CRC32 mismatch for entry: %@", fileName]}];
                return NO;
            }
            if (![fileData writeToFile:destPath options:NSDataWritingAtomic error:error]) {
                return NO;
            }
        } else if (method == 8) {
            // Deflate — use zlib inflate with raw deflate stream
            // Guard against maliciously crafted entries claiming huge uncompressed sizes.
        // Cap at 512 MB — large enough for legitimate files, small enough to be safe.
        const uint32_t kMaxUncompSize = 512u * 1024u * 1024u;
        if (uncompSize > kMaxUncompSize) {
            if (error) {
                *error = [NSError errorWithDomain:@"RNFileToolkit" code:-4
                    userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"ZIP entry uncompressed size (%u bytes) exceeds limit", uncompSize]}];
            }
            return NO;
        }
        NSMutableData *output = [NSMutableData dataWithLength:uncompSize > 0 ? uncompSize : 65536];
            z_stream strm;
            memset(&strm, 0, sizeof(strm));
            strm.next_in  = (Bytef *)compData;
            strm.avail_in = hasDataDescriptor ? (uInt)(length - offset) : (uInt)compSize;

            // inflateInit2 with -15 for raw deflate (no zlib wrapper)
            if (inflateInit2(&strm, -15) != Z_OK) {
                if (error) *error = [NSError errorWithDomain:@"RNFileToolkit" code:-1
                    userInfo:@{NSLocalizedDescriptionKey: @"zlib inflateInit2 failed"}];
                return NO;
            }

            if (uncompSize > 0) {
                [output setLength:uncompSize];
                strm.next_out  = (Bytef *)output.mutableBytes;
                strm.avail_out = (uInt)uncompSize;
                int ret = inflate(&strm, Z_FINISH);
                inflateEnd(&strm);
                if (ret != Z_STREAM_END && ret != Z_OK) {
                    if (error) *error = [NSError errorWithDomain:@"RNFileToolkit" code:-2
                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"inflate error %d", ret]}];
                    return NO;
                }
                [output setLength:strm.total_out];
            } else {
                // Unknown uncompressed size: inflate in chunks
                NSMutableData *chunk = [NSMutableData dataWithLength:65536];
                NSMutableData *result = [NSMutableData new];
                int ret;
                do {
                    strm.next_out  = (Bytef *)chunk.mutableBytes;
                    strm.avail_out = (uInt)chunk.length;
                    ret = inflate(&strm, Z_NO_FLUSH);
                    if (ret == Z_STREAM_ERROR || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR) break;
                    NSUInteger produced = chunk.length - strm.avail_out;
                    [result appendBytes:chunk.mutableBytes length:produced];
                } while (ret != Z_STREAM_END);
                inflateEnd(&strm);
                output = result;
            }

            if (hasDataDescriptor) {
                uint32_t actualCompSize = (uint32_t)strm.total_in;
                uint32_t ddSig = 0;
                if (offset + actualCompSize + 4 <= length) {
                    memcpy(&ddSig, bytes + offset + actualCompSize, 4);
                }
                NSUInteger ddOffset = offset + actualCompSize + (ddSig == 0x08074b50 ? 4 : 0);
                if (ddOffset + 12 <= length) {
                    memcpy(&crc32val, bytes + ddOffset, 4);
                }
                compSize = actualCompSize + (ddSig == 0x08074b50 ? 16 : 12);
            }

            // Verify CRC32 of decompressed data before writing
            uint32_t expectedCRC = CFSwapInt32LittleToHost(crc32val);
            uLong actualCRC = crc32(0L, (const Bytef *)output.bytes, (uInt)output.length);
            if ((uint32_t)actualCRC != expectedCRC) {
                if (error) *error = [NSError errorWithDomain:@"RNFileToolkit" code:-3
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"CRC32 mismatch for entry: %@", fileName]}];
                return NO;
            }
            if (![output writeToFile:destPath options:NSDataWritingAtomic error:error]) {
                return NO;
            }
        } else {
            // Unsupported compression method — skip
            offset += compSize;
            continue;
        }

        [extractedFiles addObject:destPath];
        offset += compSize;
    }

    return YES;
}

// ─── Zip ──────────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(zip:(NSString *)sourcePath
                  destPath:(NSString *)destPath
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:sourcePath isDirectory:&isDir]) {
            resolve(@{@"success": @NO, @"error": @"Source path does not exist"});
            return;
        }

        // Ensure destination parent directory exists
        NSString *destParent = [destPath stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:destParent withIntermediateDirectories:YES attributes:nil error:nil];

        // Delete existing destination file
        [fm removeItemAtPath:destPath error:nil];

        // Create the destination file and open a handle for writing
        [fm createFileAtPath:destPath contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:destPath];
        if (!fh) {
            resolve(@{@"success": @NO, @"error": @"Failed to create destination zip file"});
            return;
        }

        NSMutableArray<NSDictionary *> *centralDirectory = [NSMutableArray new];

        NSArray<NSString *> *filesToZip;
        NSString *baseDir;
        if (isDir) {
            NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:sourcePath];
            NSMutableArray *files = [NSMutableArray new];
            NSString *file;
            while ((file = [enumerator nextObject])) {
                [files addObject:file];
            }
            filesToZip = files;
            baseDir = sourcePath;
        } else {
            filesToZip = @[[sourcePath lastPathComponent]];
            baseDir = [sourcePath stringByDeletingLastPathComponent];
        }

        for (NSString *relativePath in filesToZip) {
            NSString *fullPath = [baseDir stringByAppendingPathComponent:relativePath];
            BOOL entryIsDir = NO;
            [fm fileExistsAtPath:fullPath isDirectory:&entryIsDir];

            NSData *entryNameData = [relativePath dataUsingEncoding:NSUTF8StringEncoding];
            uint16_t nameLen = (uint16_t)entryNameData.length;

            uint32_t localHeaderOffset = (uint32_t)[fh offsetInFile];

            // Write local file header with placeholder CRC/sizes
            uint32_t sig       = CFSwapInt32HostToLittle(0x04034b50);
            uint16_t version   = CFSwapInt16HostToLittle(20);
            uint16_t flags     = 0;
            uint16_t modTime   = 0, modDate = 0;
            uint16_t extraLen  = 0;

            // Placeholders — will be patched after streaming
            uint16_t method    = 0;
            uint32_t crcLE     = 0;
            uint32_t compSz    = 0;
            uint32_t uncompSz  = 0;

            [fh writeData:[NSData dataWithBytes:&sig       length:4]];
            [fh writeData:[NSData dataWithBytes:&version   length:2]];
            [fh writeData:[NSData dataWithBytes:&flags     length:2]];
            [fh writeData:[NSData dataWithBytes:&method    length:2]]; // offset +8
            [fh writeData:[NSData dataWithBytes:&modTime   length:2]];
            [fh writeData:[NSData dataWithBytes:&modDate   length:2]];
            [fh writeData:[NSData dataWithBytes:&crcLE     length:4]]; // offset +14
            [fh writeData:[NSData dataWithBytes:&compSz    length:4]]; // offset +18
            [fh writeData:[NSData dataWithBytes:&uncompSz  length:4]]; // offset +22
            [fh writeData:[NSData dataWithBytes:&nameLen   length:2]];
            [fh writeData:[NSData dataWithBytes:&extraLen  length:2]];
            [fh writeData:entryNameData];

            uint32_t crc = 0;
            uint32_t compressedSize = 0;
            uint32_t uncompressedSize = 0;
            uint16_t compressionMethod = 0;

            if (entryIsDir) {
                // Directory entry — no data to write
            } else {
                NSInputStream *inputStream = [NSInputStream inputStreamWithFileAtPath:fullPath];
                [inputStream open];

                if (!inputStream || inputStream.streamStatus == NSStreamStatusError) {
                    [inputStream close];
                    continue;
                }

                // Stream-compress with zlib deflate
                z_stream strm;
                memset(&strm, 0, sizeof(strm));
                deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY);

                uint8_t inBuf[32768];
                uint8_t outBuf[32768];
                int flush = Z_NO_FLUSH;

                while ([inputStream hasBytesAvailable]) {
                    NSInteger bytesRead = [inputStream read:inBuf maxLength:sizeof(inBuf)];
                    if (bytesRead <= 0) break;

                    crc = (uint32_t)crc32((uLong)crc, inBuf, (uInt)bytesRead);
                    uncompressedSize += (uint32_t)bytesRead;

                    strm.next_in = inBuf;
                    strm.avail_in = (uInt)bytesRead;

                    if (![inputStream hasBytesAvailable]) {
                        flush = Z_FINISH;
                    }

                    do {
                        strm.next_out = outBuf;
                        strm.avail_out = sizeof(outBuf);
                        deflate(&strm, flush);
                        NSUInteger produced = sizeof(outBuf) - strm.avail_out;
                        if (produced > 0) {
                            [fh writeData:[NSData dataWithBytes:outBuf length:produced]];
                            compressedSize += (uint32_t)produced;
                        }
                    } while (strm.avail_out == 0);
                }

                // Finalize deflate if we didn't hit Z_FINISH yet
                if (flush != Z_FINISH) {
                    strm.next_in = NULL;
                    strm.avail_in = 0;
                    do {
                        strm.next_out = outBuf;
                        strm.avail_out = sizeof(outBuf);
                        deflate(&strm, Z_FINISH);
                        NSUInteger produced = sizeof(outBuf) - strm.avail_out;
                        if (produced > 0) {
                            [fh writeData:[NSData dataWithBytes:outBuf length:produced]];
                            compressedSize += (uint32_t)produced;
                        }
                    } while (strm.avail_out == 0);
                }

                deflateEnd(&strm);
                [inputStream close];
                compressionMethod = 8;
            }

            // Patch the local file header with actual CRC, sizes, method
            unsigned long long currentPos = [fh offsetInFile];
            uint16_t methLE   = CFSwapInt16HostToLittle(compressionMethod);
            uint32_t crcPatch = CFSwapInt32HostToLittle(crc);
            uint32_t csPatch  = CFSwapInt32HostToLittle(compressedSize);
            uint32_t usPatch  = CFSwapInt32HostToLittle(uncompressedSize);

            [fh seekToFileOffset:localHeaderOffset + 8];
            [fh writeData:[NSData dataWithBytes:&methLE    length:2]];
            [fh seekToFileOffset:localHeaderOffset + 10]; // skip modTime
            [fh seekToFileOffset:localHeaderOffset + 14];
            [fh writeData:[NSData dataWithBytes:&crcPatch  length:4]];
            [fh writeData:[NSData dataWithBytes:&csPatch   length:4]];
            [fh writeData:[NSData dataWithBytes:&usPatch   length:4]];

            [fh seekToFileOffset:currentPos]; // restore position

            [centralDirectory addObject:@{
                @"name":            entryNameData,
                @"method":          @(compressionMethod),
                @"crc":             @(crc),
                @"compSize":        @(compressedSize),
                @"uncompSize":      @(uncompressedSize),
                @"localOffset":     @(localHeaderOffset),
            }];
        }

        // Central directory
        uint32_t cdOffset = (uint32_t)[fh offsetInFile];
        for (NSDictionary *entry in centralDirectory) {
            NSData *nameData = entry[@"name"];
            uint16_t nameLen = (uint16_t)nameData.length;
            uint32_t cdSig   = CFSwapInt32HostToLittle(0x02014b50);
            uint16_t verMade = CFSwapInt16HostToLittle(20);
            uint16_t verNeeded = CFSwapInt16HostToLittle(20);
            uint16_t flags   = 0;
            uint16_t meth    = CFSwapInt16HostToLittle((uint16_t)[entry[@"method"] unsignedShortValue]);
            uint16_t modTime = 0, modDate = 0;
            uint32_t crcLE   = CFSwapInt32HostToLittle((uint32_t)[entry[@"crc"] unsignedIntValue]);
            uint32_t compSz  = CFSwapInt32HostToLittle((uint32_t)[entry[@"compSize"] unsignedIntValue]);
            uint32_t uncompSz = CFSwapInt32HostToLittle((uint32_t)[entry[@"uncompSize"] unsignedIntValue]);
            uint16_t extraLen = 0, commentLen = 0;
            uint16_t disk    = 0;
            uint16_t intAttr = 0;
            uint32_t extAttr = 0;
            uint32_t localOff = CFSwapInt32HostToLittle((uint32_t)[entry[@"localOffset"] unsignedIntValue]);

            [fh writeData:[NSData dataWithBytes:&cdSig      length:4]];
            [fh writeData:[NSData dataWithBytes:&verMade    length:2]];
            [fh writeData:[NSData dataWithBytes:&verNeeded  length:2]];
            [fh writeData:[NSData dataWithBytes:&flags      length:2]];
            [fh writeData:[NSData dataWithBytes:&meth       length:2]];
            [fh writeData:[NSData dataWithBytes:&modTime    length:2]];
            [fh writeData:[NSData dataWithBytes:&modDate    length:2]];
            [fh writeData:[NSData dataWithBytes:&crcLE      length:4]];
            [fh writeData:[NSData dataWithBytes:&compSz     length:4]];
            [fh writeData:[NSData dataWithBytes:&uncompSz   length:4]];
            [fh writeData:[NSData dataWithBytes:&nameLen    length:2]];
            [fh writeData:[NSData dataWithBytes:&extraLen   length:2]];
            [fh writeData:[NSData dataWithBytes:&commentLen length:2]];
            [fh writeData:[NSData dataWithBytes:&disk       length:2]];
            [fh writeData:[NSData dataWithBytes:&intAttr    length:2]];
            [fh writeData:[NSData dataWithBytes:&extAttr    length:4]];
            [fh writeData:[NSData dataWithBytes:&localOff   length:4]];
            [fh writeData:nameData];
        }

        uint32_t cdSize   = CFSwapInt32HostToLittle((uint32_t)([fh offsetInFile] - cdOffset));
        uint32_t cdOffLE  = CFSwapInt32HostToLittle(cdOffset);
        uint16_t numEntries = CFSwapInt16HostToLittle((uint16_t)centralDirectory.count);
        uint16_t commentLen = 0;

        // End of central directory record
        uint32_t eocdSig = CFSwapInt32HostToLittle(0x06054b50);
        uint16_t disk = 0;
        [fh writeData:[NSData dataWithBytes:&eocdSig    length:4]];
        [fh writeData:[NSData dataWithBytes:&disk       length:2]];
        [fh writeData:[NSData dataWithBytes:&disk       length:2]];
        [fh writeData:[NSData dataWithBytes:&numEntries length:2]];
        [fh writeData:[NSData dataWithBytes:&numEntries length:2]];
        [fh writeData:[NSData dataWithBytes:&cdSize     length:4]];
        [fh writeData:[NSData dataWithBytes:&cdOffLE    length:4]];
        [fh writeData:[NSData dataWithBytes:&commentLen length:2]];

        [fh closeFile];
        resolve(@{@"success": @YES, @"zipPath": destPath});
    });
}

// ─── df (disk space) ──────────────────────────────────────────────────────

- (void)df:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSError *error = nil;
        NSDictionary *attrs = [fm attributesOfFileSystemForPath:docPath error:&error];
        if (error || !attrs) {
            resolve(@{@"success": @NO, @"error": error.localizedDescription ?: @"DF_ERROR"});
            return;
        }

        NSNumber *freeBytes = attrs[NSFileSystemFreeSize];
        NSNumber *totalBytes = attrs[NSFileSystemSize];

        resolve(@{
            @"success": @YES,
            @"freeBytes": freeBytes ?: @0,
            @"totalBytes": totalBytes ?: @0
        });
    } @catch (NSException *exception) {
        resolve(@{@"success": @NO, @"error": exception.reason ?: @"DF_ERROR"});
    }
}

// ─── appendFile ───────────────────────────────────────────────────────────

- (void)appendFile:(NSString *)filePath data:(NSString *)data encoding:(NSString *)encoding resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];

        // Create parent dirs if needed
        NSString *parent = [filePath stringByDeletingLastPathComponent];
        if (parent.length > 0) {
            [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        }

        // Create the file if it doesn't exist
        if (![fm fileExistsAtPath:filePath]) {
            [fm createFileAtPath:filePath contents:nil attributes:nil];
        }

        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
        if (!fileHandle) {
            resolve(@{@"success": @NO, @"error": @"Cannot open file for appending"});
            return;
        }

        [fileHandle seekToEndOfFile];

        NSData *dataToWrite = nil;
        if ([[encoding lowercaseString] isEqualToString:@"base64"]) {
            dataToWrite = [[NSData alloc] initWithBase64EncodedString:data options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (!dataToWrite) {
                [fileHandle closeFile];
                resolve(@{@"success": @NO, @"error": @"Invalid base64 string"});
                return;
            }
        } else {
            dataToWrite = [data dataUsingEncoding:NSUTF8StringEncoding];
        }

        [fileHandle writeData:dataToWrite];
        [fileHandle closeFile];

        resolve(@{@"success": @YES});
    } @catch (NSException *exception) {
        resolve(@{@"success": @NO, @"error": exception.reason ?: @"APPEND_FILE_ERROR"});
    }
}

// ─── hash ─────────────────────────────────────────────────────────────────

- (void)hash:(NSString *)filePath algorithm:(NSString *)algorithm resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:filePath isDirectory:&isDir] || isDir) {
            resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"File not found: %@", filePath]});
            return;
        }

        NSString *hashValue = [self calculateChecksumForPath:filePath algorithm:[algorithm uppercaseString]];
        if (!hashValue) {
            resolve(@{@"success": @NO, @"error": @"Failed to compute hash"});
            return;
        }

        resolve(@{
            @"success": @YES,
            @"hash": hashValue
        });
    } @catch (NSException *exception) {
        resolve(@{@"success": @NO, @"error": exception.reason ?: @"HASH_ERROR"});
    }
}

// ─── getCookies ───────────────────────────────────────────────────────────

- (void)getCookies:(NSString *)domain resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSArray<NSHTTPCookie *> *allCookies = [storage cookies];
        NSMutableArray *result = [NSMutableArray new];

        for (NSHTTPCookie *cookie in allCookies) {
            // Match cookies whose domain ends with the requested domain
            if (domain.length == 0 || [cookie.domain hasSuffix:domain] || [domain hasSuffix:cookie.domain]) {
                NSMutableDictionary *cookieDict = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"name": cookie.name ?: @"",
                    @"value": cookie.value ?: @"",
                    @"domain": cookie.domain ?: @"",
                    @"path": cookie.path ?: @"/"
                }];

                if (cookie.expiresDate) {
                    cookieDict[@"expiresDate"] = @([cookie.expiresDate timeIntervalSince1970] * 1000);
                }
                cookieDict[@"isSecure"] = @(cookie.isSecure);
                cookieDict[@"isHTTPOnly"] = @(cookie.isHTTPOnly);

                [result addObject:cookieDict];
            }
        }

        resolve(@{@"success": @YES, @"cookies": result});
    } @catch (NSException *exception) {
        resolve(@{@"success": @NO, @"error": exception.reason ?: @"GET_COOKIES_ERROR"});
    }
}

// ─── clearCookies ─────────────────────────────────────────────────────────

- (void)clearCookies:(NSString *)domain resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];

        if (domain.length == 0) {
            // Clear ALL cookies
            NSArray<NSHTTPCookie *> *allCookies = [storage cookies];
            for (NSHTTPCookie *cookie in allCookies) {
                [storage deleteCookie:cookie];
            }
        } else {
            // Clear cookies matching the domain
            NSArray<NSHTTPCookie *> *allCookies = [storage cookies];
            for (NSHTTPCookie *cookie in allCookies) {
                if ([cookie.domain hasSuffix:domain] || [domain hasSuffix:cookie.domain]) {
                    [storage deleteCookie:cookie];
                }
            }
        }

        resolve(@{@"success": @YES});
    } @catch (NSException *exception) {
        resolve(@{@"success": @NO, @"error": exception.reason ?: @"CLEAR_COOKIES_ERROR"});
    }
}

// ─── saveToMediaStore ─────────────────────────────────────────────────────

RCT_EXPORT_METHOD(saveToMediaStore:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    NSString *filePath = options[@"filePath"];
    if (!filePath || filePath.length == 0) {
        resolve(@{@"success": @NO, @"error": @"filePath is required"});
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"File not found: %@", filePath]});
        return;
    }

    NSString *mediaType = options[@"mediaType"] ?: @"download";

    if ([mediaType isEqualToString:@"image"] || [mediaType isEqualToString:@"video"]) {
        // Use Photos framework for images and videos
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                resolve(@{@"success": @NO, @"error": @"Photo library access denied"});
                return;
            }
            
            PHPhotoLibrary *photoLibrary = [PHPhotoLibrary sharedPhotoLibrary];
            [photoLibrary performChanges:^{
                NSURL *fileURL = [NSURL fileURLWithPath:filePath];
                if ([mediaType isEqualToString:@"image"]) {
                    [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:fileURL];
                } else {
                    [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
                }
            } completionHandler:^(BOOL success, NSError *error) {
                if (success) {
                    resolve(@{@"success": @YES, @"uri": filePath});
                } else {
                    resolve(@{@"success": @NO, @"error": error.localizedDescription ?: @"Failed to save to Photos"});
                }
            }];
        }];
    } else {
        // For audio/download types, copy to Documents directory (iOS has no shared media store for these)
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *fileName = [filePath lastPathComponent];
            NSURL *docsDir = [[NSFileManager defaultManager]
                URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *destURL = [docsDir URLByAppendingPathComponent:fileName];

            NSError *copyError = nil;
            [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];
            BOOL ok = [[NSFileManager defaultManager] copyItemAtPath:filePath toPath:destURL.path error:&copyError];

            if (ok) {
                resolve(@{@"success": @YES, @"uri": destURL.path});
            } else {
                resolve(@{@"success": @NO, @"error": copyError.localizedDescription ?: @"MEDIA_STORE_ERROR"});
            }
        });
    }
}

@end
