#import <Foundation/Foundation.h>
#import <React/RCTLog.h>
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import "FileToolkit.h"
#import "FileToolkitZip.h"

// Posted by the host app from -application:handleEventsForBackgroundURLSession:completionHandler:
// with userInfo @{@"identifier": NSString, @"completionHandler": block}. A notification
// (rather than a header) keeps it usable from a Swift AppDelegate with no imports.
static NSString *const FTKBackgroundEventsNotification = @"RNFileToolkitBackgroundSessionEvents";
// NSUserDefaults key: downloadId → the options needed to finish a background
// download after the process was killed and relaunched by the system.
static NSString *const FTKBackgroundMetaKey = @"RNFileToolkitBackgroundDownloads";
// Terminal events kept while JS has no listeners (e.g. a relaunch into the background).
static const NSUInteger kFTKMaxBufferedEvents = 100;
// Same ceiling as Android's urlToBase64.
static const long long kFTKBase64MaxBytes = 50LL * 1024 * 1024;
// Grace period before inherited downloads without a task are declared lost.
static const int64_t kFTKReconcileDelaySeconds = 10;
// Minimum spacing of progress events when the server sent no Content-Length.
static const CFAbsoluteTime kFTKUnknownSizeProgressInterval = 0.25;

// pendingRetries values: a failed download waiting out its backoff.
typedef NS_ENUM(NSInteger, FTKRetryState) {
    FTKRetryWaiting = 0, // timer pending; starts when it fires
    FTKRetryPaused  = 1, // paused before the timer fired
    FTKRetryHeld    = 2, // timer fired while paused; starts on resumeDownload
};

static NSString *FTKBackgroundSessionIdentifier(void) {
    return [NSString stringWithFormat:@"%@.filetoolkit.background", NSBundle.mainBundle.bundleIdentifier];
}

// Task identifiers are only unique within one session, so qualify them.
static NSString *FTKTaskKey(NSURLSession *session, NSURLSessionTask *task) {
    return [NSString stringWithFormat:@"%@:%lu",
            session.configuration.identifier ? @"bg" : @"fg", (unsigned long)task.taskIdentifier];
}

/**
 * Redirect policy for every session whose delegate is asked about redirects:
 * once the origin (scheme, host, port) differs from the original request,
 * caller-supplied credentials are not forwarded — this includes an https→http
 * downgrade. Background sessions follow redirects inside the OS without asking.
 */
static NSURLRequest *FTKRedirectRequest(NSURLSessionTask *task, NSURLRequest *request) {
    NSURL *from = task.originalRequest.URL, *to = request.URL;
    NSInteger (^port)(NSURL *) = ^NSInteger(NSURL *u) {
        if (u.port) return u.port.integerValue;
        return [u.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame ? 443 : 80;
    };
    BOOL sameOrigin = [(from.scheme ?: @"") caseInsensitiveCompare:(to.scheme ?: @"")] == NSOrderedSame
                   && [(from.host ?: @"") caseInsensitiveCompare:(to.host ?: @"")] == NSOrderedSame
                   && port(from) == port(to);
    if (sameOrigin) return request;
    NSMutableURLRequest *stripped = [request mutableCopy];
    for (NSString *header in @[@"Authorization", @"Cookie", @"Proxy-Authorization"]) {
        [stripped setValue:nil forHTTPHeaderField:header];
    }
    return stripped;
}

// ─── Buffered events (process-wide) ───────────────────────────────────────────

static NSObject *FTKEventLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

/** Must be called with FTKEventLock() held. Each element is @[name, body]. */
static NSMutableArray<NSArray *> *FTKBufferedEvents(void) {
    static NSMutableArray<NSArray *> *events;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ events = [NSMutableArray new]; });
    return events;
}

/** Must be called with FTKEventLock() held. */
static void FTKBufferEventLocked(NSString *name, NSDictionary *body) {
    NSMutableArray<NSArray *> *events = FTKBufferedEvents();
    [events addObject:@[name, body]];
    if (events.count > kFTKMaxBufferedEvents) [events removeObjectAtIndex:0];
}

// ─── Persisted background-download metadata ───────────────────────────────────

// Tags metadata with the process that wrote it, so reconciliation only ever
// judges entries inherited from an earlier launch, never one being created now.
static NSString *FTKLaunchId(void) {
    static NSString *launchId;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ launchId = [[NSUUID UUID] UUIDString]; });
    return launchId;
}

static NSObject *FTKMetaLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

/**
 * Persists what is needed to finish a background download in a later process:
 * where the file goes and how to verify it. Headers are deliberately left out
 * (they often carry credentials), so a relaunched process does not retry.
 */
static void FTKSaveMeta(NSString *downloadId, NSDictionary *options) {
    NSMutableDictionary *meta = [NSMutableDictionary new];
    for (NSString *key in @[@"url", @"destination", @"fileName"]) {
        id value = options[key];
        if ([value isKindOfClass:[NSString class]]) meta[key] = value;
    }
    NSDictionary *checksum = options[@"checksum"];
    if ([checksum isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *sum = [NSMutableDictionary new];
        for (NSString *key in @[@"hash", @"algorithm"]) {
            id value = checksum[key];
            if ([value isKindOfClass:[NSString class]]) sum[key] = value;
        }
        meta[@"checksum"] = sum;
    }
    meta[@"downloadId"] = downloadId;
    meta[@"background"] = @YES;
    meta[@"launch"] = FTKLaunchId();

    @synchronized (FTKMetaLock()) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *all = [[defaults dictionaryForKey:FTKBackgroundMetaKey] mutableCopy] ?: [NSMutableDictionary new];
        all[downloadId] = meta;
        [defaults setObject:all forKey:FTKBackgroundMetaKey];
    }
}

static NSDictionary *FTKLoadMeta(NSString *downloadId) {
    @synchronized (FTKMetaLock()) {
        NSDictionary *meta = [[NSUserDefaults standardUserDefaults] dictionaryForKey:FTKBackgroundMetaKey][downloadId];
        return [meta isKindOfClass:[NSDictionary class]] ? meta : nil;
    }
}

static void FTKRemoveMeta(NSString *downloadId) {
    @synchronized (FTKMetaLock()) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDictionary *all = [defaults dictionaryForKey:FTKBackgroundMetaKey];
        if (!all[downloadId]) return;
        NSMutableDictionary *updated = [all mutableCopy];
        [updated removeObjectForKey:downloadId];
        [defaults setObject:updated forKey:FTKBackgroundMetaKey];
    }
}

/**
 * downloadIds cancelled in this process. A finish callback already in flight
 * when cancelDownload ran finds neither options nor metadata — exactly like a
 * download inherited from an earlier launch whose metadata predates this
 * version — so this is what tells "cancelled, discard" apart from "recover".
 */
// ponytail: never pruned (a few bytes per cancel, reset per process).
static NSMutableSet<NSString *> *FTKCancelledIds(void) {
    static NSMutableSet<NSString *> *ids;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ids = [NSMutableSet new]; });
    return ids;
}

static void FTKSetCancelled(NSString *downloadId, BOOL cancelled) {
    @synchronized (FTKMetaLock()) {
        if (cancelled) [FTKCancelledIds() addObject:downloadId];
        else [FTKCancelledIds() removeObject:downloadId];
    }
}

static BOOL FTKWasCancelled(NSString *downloadId) {
    @synchronized (FTKMetaLock()) {
        return [FTKCancelledIds() containsObject:downloadId];
    }
}

// ─── Background session proxy ─────────────────────────────────────────────────

/**
 * Owns the one process-wide background NSURLSession.
 *
 * A background session must exist exactly once per identifier for the life of
 * the process: re-creating it per module instance (every reload) is undefined
 * behaviour and routed completions to dead modules. The session's delegate is
 * this proxy, which forwards to whichever FileToolkit instance is live and,
 * when none is, still moves finished files into place using persisted metadata.
 */
@interface FTKBackgroundSessionProxy : NSObject <NSURLSessionDownloadDelegate>
@property (atomic, weak) FileToolkit *module;
@property (nonatomic, strong, readonly) NSURLSession *session;
+ (instancetype)shared;
- (void)attachModule:(FileToolkit *)module;
- (void)detachModule:(FileToolkit *)module;
@end

// ─── Foreground session delegate ──────────────────────────────────────────────
@interface FileToolkit () <NSURLSessionDownloadDelegate, NSURLSessionDataDelegate, UIDocumentInteractionControllerDelegate>
// Atomic: read from global/delegate queues while -invalidate clears them.
@property (atomic, strong) NSURLSession *fgSession;          // foreground
@property (atomic, strong) NSURLSession *bgSession;          // shared background session; nil once invalidated
// downloadId → resolve/reject blocks
@property (nonatomic, strong) NSMutableDictionary *activePromises;
// downloadId → original options dict
@property (nonatomic, strong) NSMutableDictionary *downloadOptions;
// downloadId → NSURLSessionDownloadTask
@property (nonatomic, strong) NSMutableDictionary *activeTasks;
// downloadId → NSData (resume data for paused tasks)
@property (nonatomic, strong) NSMutableDictionary *resumeDataStore;
// FTKTaskKey(session, task) → downloadId (string)
@property (nonatomic, strong) NSMutableDictionary *taskIdMap;
// downloadId → current retry attempt count (NSNumber)
@property (nonatomic, strong) NSMutableDictionary *retryAttempts;
// downloadId → FTKRetryState for downloads waiting out a retry backoff (no task exists)
@property (nonatomic, strong) NSMutableDictionary *pendingRetries;
// downloadId → CFAbsoluteTime of the last unknown-size progress event
@property (nonatomic, strong) NSMutableDictionary *lastProgressAt;
// Upload tracking
@property (nonatomic, strong) NSMutableDictionary *uploadPromises;     // uploadId → {resolve, reject}
@property (nonatomic, strong) NSMutableDictionary *uploadUrls;         // uploadId → URL string
@property (nonatomic, strong) NSMutableDictionary *uploadResponseData; // uploadId → NSMutableData
@property (nonatomic, strong) NSMutableDictionary *uploadTaskIdMap;    // FTKTaskKey → uploadId
// Strong ref to prevent ARC deallocation during preview
@property (nonatomic, strong) UIDocumentInteractionController *documentController;
// Serial queue for thread-safe dictionary access
@property (nonatomic, strong) dispatch_queue_t syncQueue;
// Set (on syncQueue) at the start of -invalidate; no retry task is created after it.
@property (nonatomic, assign) BOOL invalidated;
// Guarded by FTKEventLock() so buffering and flushing cannot interleave.
@property (nonatomic, assign) BOOL hasListeners;
// Event names JS has subscribed to since listeners were last all removed. Guarded by FTKEventLock().
@property (nonatomic, strong) NSMutableSet<NSString *> *heardEvents;
- (void)emitEvent:(NSString *)name body:(NSDictionary *)body bufferIfUnheard:(BOOL)buffer;
@end

/** Fetches a URL into memory for urlToBase64, enforcing kFTKBase64MaxBytes while receiving. */
@interface FTKBase64Fetch : NSObject <NSURLSessionDataDelegate>
- (instancetype)initWithResolve:(RCTPromiseResolveBlock)resolve;
@end

@implementation FileToolkit

// Names the module explicitly. RCT_EXPORT_MODULE() already synthesises
// +moduleName, so the class must not define it a second time.
RCT_EXPORT_MODULE(FileToolkit)

- (instancetype)init {
    if (self = [super init]) {
        self.syncQueue = dispatch_queue_create("com.filetoolkit.syncQueue", DISPATCH_QUEUE_SERIAL);
        self.activePromises  = [NSMutableDictionary new];
        self.downloadOptions = [NSMutableDictionary new];
        self.activeTasks     = [NSMutableDictionary new];
        self.resumeDataStore = [NSMutableDictionary new];
        self.taskIdMap       = [NSMutableDictionary new];
        self.retryAttempts   = [NSMutableDictionary new];
        self.pendingRetries  = [NSMutableDictionary new];
        self.lastProgressAt  = [NSMutableDictionary new];
        self.heardEvents     = [NSMutableSet new];
        self.uploadPromises  = [NSMutableDictionary new];
        self.uploadUrls      = [NSMutableDictionary new];
        self.uploadResponseData = [NSMutableDictionary new];
        self.uploadTaskIdMap = [NSMutableDictionary new];

        // Foreground session
        NSURLSessionConfiguration *fgConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
        self.fgSession = [NSURLSession sessionWithConfiguration:fgConfig delegate:self delegateQueue:nil];

        // Background session (survives app suspension) — shared across module instances
        FTKBackgroundSessionProxy *proxy = [FTKBackgroundSessionProxy shared];
        self.bgSession = proxy.session;
        [proxy attachModule:self];
    }
    return self;
}

/**
 * Torn down when the React instance goes away (dev reload, bridge restart).
 *
 * The foreground session retains this object as its delegate, so without an
 * explicit invalidation the old module lives forever and keeps pushing events
 * at a dead bridge. The background session is process-wide and is deliberately
 * left running: its proxy simply stops forwarding to this instance.
 */
- (void)invalidate {
    // Retry timers hold this instance weakly and die with it, so a background
    // download waiting out a backoff would never finish. Tell the next JS
    // context through the process-wide buffer instead of leaving it hanging.
    __block NSArray<NSString *> *lostIds = nil;
    dispatch_sync(self.syncQueue, ^{
        self.invalidated = YES; // see -startRetryForDownload:
        NSMutableArray<NSString *> *ids = [NSMutableArray new];
        for (NSString *downloadId in self.pendingRetries) {
            if ([self.downloadOptions[downloadId][@"background"] boolValue]) {
                [ids addObject:downloadId];
                // Belt and braces: anything for this id that still surfaces is discarded.
                FTKSetCancelled(downloadId, YES);
            }
        }
        [self.pendingRetries removeAllObjects]; // pending timers now bail
        lostIds = ids;
    });
    for (NSString *downloadId in lostIds) {
        FTKRemoveMeta(downloadId);
        @synchronized (FTKEventLock()) {
            FTKBufferEventLocked(@"onDownloadError", @{@"success": @NO, @"downloadId": downloadId, @"error": @"DOWNLOAD_LOST"});
        }
    }

    [self.fgSession invalidateAndCancel];
    self.fgSession = nil;
    self.bgSession = nil;
    [[FTKBackgroundSessionProxy shared] detachModule:self];
    [super invalidate];
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"onDownloadProgress", @"onDownloadComplete", @"onDownloadError", @"onUploadProgress", @"onDownloadRetry"];
}

- (void)startObserving {
    @synchronized (FTKEventLock()) {
        self.hasListeners = YES;
    }
}

- (void)stopObserving {
    @synchronized (FTKEventLock()) {
        self.hasListeners = NO;
        [self.heardEvents removeAllObjects]; // no listener of any name is left
    }
}

/**
 * Tracks which event names JS subscribes to and delivers the terminal events
 * buffered for that name while it had no listener (or no module existed, e.g.
 * a download that finished while the app was not running). JS registers the
 * listener in the same tick as this call, so it receives the flush.
 *
 * removeListeners: only reports a count, so a name stays "heard" until every
 * listener is gone (stopObserving); a terminal event for a name that was heard
 * and then dropped while others remain is sent rather than buffered.
 */
- (void)addListener:(NSString *)eventName {
    [super addListener:eventName];
    @synchronized (FTKEventLock()) {
        if (!self.hasListeners) return;
        [self.heardEvents addObject:eventName];
        NSMutableArray<NSArray *> *events = FTKBufferedEvents();
        NSMutableArray<NSArray *> *remaining = [NSMutableArray new];
        for (NSArray *event in events) {
            if ([event[0] isEqualToString:eventName]) {
                [self sendEventWithName:event[0] body:event[1]];
            } else {
                [remaining addObject:event];
            }
        }
        [events setArray:remaining];
    }
}

/** Sends an event if JS is listening; otherwise drops it. */
- (void)emitEvent:(NSString *)name body:(NSDictionary *)body {
    [self emitEvent:name body:body bufferIfUnheard:NO];
}

/**
 * With `buffer`, an event whose name has no JS listener yet is kept and
 * delivered by -addListener: — used for background-download results, whose
 * only channel is the event (foreground results already went to the promise).
 * Keyed per name: after a relaunch JS may subscribe to progress long before
 * completion, and a completion sent then would be dropped by JS.
 */
- (void)emitEvent:(NSString *)name body:(NSDictionary *)body bufferIfUnheard:(BOOL)buffer {
    @synchronized (FTKEventLock()) {
        if (buffer && !(self.hasListeners && [self.heardEvents containsObject:name])) {
            FTKBufferEventLocked(name, body);
        } else if (self.hasListeners) {
            [self sendEventWithName:name body:body];
        }
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

- (NSString *)generateDownloadId {
    return [[NSUUID UUID] UUIDString];
}

/**
 * Reduces an arbitrary name to a single, safe path segment.
 *
 * File names can come from a server (URL path, redirect target) or from caller
 * input, so `../` sequences must never be able to escape the destination.
 */
static NSString *FTKSanitizeFileName(NSString *name) {
    NSString *base = [name lastPathComponent];
    base = [base stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    if (base.length == 0 || [base isEqualToString:@"."] || [base isEqualToString:@".."]) {
        return @"downloaded_file";
    }
    if (base.length > 200) {
        base = [base substringFromIndex:base.length - 200];
    }
    return base;
}

/**
 * Resolves the directory for a logical destination, creating it if needed.
 *
 * `NSDownloadsDirectory` resolves inside the app container on iOS but is *not*
 * created by the system, and `URLsForDirectory:inDomains:` never creates it
 * either. Returning that URL unchecked made every default-destination download
 * fail at the final move with "No such file or directory", so the directory is
 * always materialised here.
 */
static NSURL *FTKDirectoryForDestination(NSString *destType) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *dirURL = nil;

    if ([destType isEqualToString:@"cache"]) {
        dirURL = [[fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
                  URLByAppendingPathComponent:@"RNFileToolkit"];
    } else if ([destType isEqualToString:@"documents"]) {
        dirURL = [[fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject
                  URLByAppendingPathComponent:@"RNFileToolkit"];
    } else {
        dirURL = [fm URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
        if (!dirURL) {
            NSURL *docsDir = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            dirURL = [docsDir URLByAppendingPathComponent:@"Downloads"];
        }
    }

    if (dirURL) {
        [fm createDirectoryAtURL:dirURL withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return dirURL;
}

static NSURL *FTKDestURL(NSString *fileName, NSString *destType) {
    NSURL *dirURL = FTKDirectoryForDestination(destType);
    return [dirURL URLByAppendingPathComponent:FTKSanitizeFileName(fileName)];
}

// MD5 and SHA-1 are deliberately offered: they are still what most download
// manifests publish. They are used for integrity checks only, never for security.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSString *FTKChecksum(NSString *path, NSString *algo) {
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

#pragma clang diagnostic pop

static NSString *FTKFileNameFromOptions(NSDictionary *options, NSURLSessionDownloadTask *task) {
    NSString *name = options[@"fileName"];
    if (![name isKindOfClass:[NSString class]] || [name isEqualToString:@""]) {
        // Prefer the *final* URL so that a redirect to the real asset still yields
        // a sensible name rather than the name of the redirecting endpoint.
        name = task.response.URL.lastPathComponent ?: task.originalRequest.URL.lastPathComponent;
    }
    if (!name || [name isEqualToString:@""]) {
        name = @"downloaded_file";
    }
    return FTKSanitizeFileName(name);
}

/**
 * Moves a finished download into place and verifies its checksum, returning the
 * result payload. Must run synchronously inside didFinishDownloadingToURL: —
 * the system deletes `location` as soon as that call returns. Needs no module
 * instance, so the background proxy can finish downloads with no live bridge.
 */
static NSDictionary *FTKFinalizeDownload(NSURLSessionDownloadTask *downloadTask, NSURL *location,
                                         NSString *downloadId, NSDictionary *options, BOOL *isError) {
    // NSURLSessionDownloadTask reports 4xx/5xx as a *successful* download whose body
    // is the error page. Without this check `download()` resolves with success:YES
    // and an HTML error document saved under the expected file name.
    NSHTTPURLResponse *httpResponse = [downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)downloadTask.response : nil;
    if (httpResponse && (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300)) {
        [[NSFileManager defaultManager] removeItemAtURL:location error:nil];
        *isError = YES;
        return @{
            @"success": @NO,
            @"downloadId": downloadId,
            @"error": [NSString stringWithFormat:@"SERVER_ERROR: %ld", (long)httpResponse.statusCode]
        };
    }

    NSString *fileName = FTKFileNameFromOptions(options, downloadTask);
    NSString *destType = [options[@"destination"] isKindOfClass:[NSString class]] ? options[@"destination"] : @"downloads";
    NSURL *destURL = FTKDestURL(fileName, destType);

    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];
    if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:destURL error:&error]) {
        *isError = YES;
        return @{@"success": @NO, @"downloadId": downloadId, @"error": error.localizedDescription ?: @"Failed to move downloaded file"};
    }

    // Checksum verification
    NSDictionary *checksum = options[@"checksum"];
    if ([checksum isKindOfClass:[NSDictionary class]]) {
        NSString *expectedHash = checksum[@"hash"];
        NSString *algo = checksum[@"algorithm"] ?: @"MD5";
        NSString *actualHash = FTKChecksum(destURL.path, algo.uppercaseString);
        if (![actualHash.lowercaseString isEqualToString:expectedHash.lowercaseString]) {
            [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];
            *isError = YES;
            return @{
                @"success": @NO,
                @"downloadId": downloadId,
                @"error": [NSString stringWithFormat:@"CHECKSUM_MISMATCH: expected %@, got %@", expectedHash, actualHash]
            };
        }
    }
    *isError = NO;
    return @{@"success": @YES, @"downloadId": downloadId, @"filePath": destURL.path};
}

- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(FTKRedirectRequest(task, request));
}

// ─── download ─────────────────────────────────────────────────────────────────

- (void)download:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSString *urlString = options[@"url"];
    if (![urlString isKindOfClass:[NSString class]]) {
        resolve(@{@"success": @NO, @"error": @"URL is missing"});
        return;
    }

    BOOL isBackground = [options[@"background"] boolValue];
    // Used as a dictionary/NSUserDefaults key, so it must be a non-empty string.
    NSString *downloadId = options[@"downloadId"];
    if (![downloadId isKindOfClass:[NSString class]] || downloadId.length == 0) {
        downloadId = [self generateDownloadId];
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        resolve(@{@"success": @NO, @"error": @"Invalid URL"});
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    
    // Add custom headers
    NSDictionary *headers = options[@"headers"];
    if ([headers isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in headers) {
            [request setValue:headers[key] forHTTPHeaderField:key];
        }
    }

    NSURLSession *session = isBackground ? self.bgSession : self.fgSession;
    if (!session) {
        resolve(@{@"success": @NO, @"error": @"Module was invalidated"});
        return;
    }

    // A downloadId is a handle for pause/resume/cancel and events, so it must be
    // unique among running downloads (matches Android). Spec methods run on this
    // module's serial method queue, so no other download: call can interleave.
    __block BOOL idInUse = NO;
    dispatch_sync(self.syncQueue, ^{
        idInUse = self.activeTasks[downloadId] != nil
               || self.pendingRetries[downloadId] != nil
               || self.resumeDataStore[downloadId] != nil;
    });
    if (idInUse) {
        resolve(@{@"success": @NO, @"downloadId": downloadId, @"error": @"DOWNLOAD_ID_IN_USE"});
        return;
    }

    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request];
    NSString *taskKey = FTKTaskKey(session, task);
    task.taskDescription = downloadId;

    dispatch_sync(self.syncQueue, ^{
        FTKSetCancelled(downloadId, NO); // the id may be reused after a cancel
        self.taskIdMap[taskKey]       = downloadId;
        self.activeTasks[downloadId]  = task;
        self.downloadOptions[downloadId] = options;
        if (!isBackground) {
            self.activePromises[downloadId] = @{@"resolve": resolve, @"reject": reject};
        }
    });

    if (isBackground) {
        // Written before the task starts: the process may be gone by the time it ends.
        FTKSaveMeta(downloadId, options);
        // Resolve immediately with the downloadId — result comes via event
        resolve(@{@"success": @YES, @"downloadId": downloadId});
    }

    [task resume];
}

// ─── pauseDownload ────────────────────────────────────────────────────────────

- (void)pauseDownload:(NSString *)downloadId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    __block NSURLSessionDownloadTask *task = nil;
    __block BOOL retryHeld = NO;
    dispatch_sync(self.syncQueue, ^{
        task = self.activeTasks[downloadId];
        NSNumber *retryState = self.pendingRetries[downloadId];
        if (!task && retryState) {
            // Waiting out a retry backoff: there is no task to pause, so keep the
            // retry from starting until resumeDownload is called.
            if (retryState.integerValue == FTKRetryWaiting) {
                self.pendingRetries[downloadId] = @(FTKRetryPaused);
            }
            retryHeld = YES;
        }
    });
    if (retryHeld) {
        resolve(@{@"success": @YES});
        return;
    }
    if (!task) {
        resolve(@{@"success": @NO, @"error": @"Download not found"});
        return;
    }

    [task cancelByProducingResumeData:^(NSData *resumeData) {
        __block BOOL stillActive = NO;
        __block BOOL wasBackground = NO;
        __block NSDictionary *failedFuncs = nil;
        dispatch_sync(self.syncQueue, ^{
            // Settled meanwhile (cancelled, or completed and claimed by
            // -finishDownload:): storing resume data would let a resume revive it.
            stillActive = self.downloadOptions[downloadId] != nil;
            wasBackground = [self.downloadOptions[downloadId][@"background"] boolValue];
            if (stillActive && resumeData) {
                self.resumeDataStore[downloadId] = resumeData;
            } else if (stillActive) {
                // The task is gone and cannot be resumed. Take the download and
                // mark it in this one step, so a completion racing in can no
                // longer claim it (and discards its file) — one result only.
                failedFuncs = [self takeDownloadLocked:downloadId];
                FTKSetCancelled(downloadId, YES);
            }
            // Only forget the task we paused; a racing retry may have replaced it.
            if (self.activeTasks[downloadId] == task) {
                [self.activeTasks removeObjectForKey:downloadId];
            }
        });
        if (!stillActive) {
            // Cancelled, or finished, while pausing: already settled elsewhere.
            resolve(@{@"success": @NO, @"error": @"Download is no longer active"});
            return;
        }
        if (!resumeData) {
            // Settle like any other failure. For a background download the event
            // is the only channel JS has, so it must not be skipped.
            NSString *message = wasBackground
                ? @"PAUSE_FAILED_NO_RESUME_DATA"
                : @"Download could not be paused and was cancelled";
            [self settleDownload:downloadId
                           funcs:failedFuncs
                          result:@{@"success": @NO, @"downloadId": downloadId, @"error": message}
                         isError:YES
                    isBackground:wasBackground];
        }
        resolve(@{@"success": resumeData ? @YES : @NO});
    }];
}

// ─── resumeDownload ───────────────────────────────────────────────────────────

- (void)resumeDownload:(NSString *)downloadId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    __block NSData *resumeData = nil;
    __block NSDictionary *options = nil;
    __block BOOL retryPending = NO;
    __block BOOL startRetryNow = NO;
    dispatch_sync(self.syncQueue, ^{
        options = self.downloadOptions[downloadId];
        NSNumber *retryState = self.pendingRetries[downloadId];
        if (retryState) {
            retryPending = YES;
            if (retryState.integerValue == FTKRetryHeld) {
                // Timer already fired while paused: start it now.
                self.pendingRetries[downloadId] = @(FTKRetryWaiting);
                startRetryNow = YES;
            } else if (retryState.integerValue == FTKRetryPaused) {
                // Backoff still running: the timer will start it.
                self.pendingRetries[downloadId] = @(FTKRetryWaiting);
            }
            return;
        }
        resumeData = self.resumeDataStore[downloadId];
    });
    if (retryPending) {
        if (startRetryNow) {
            [self startRetryForDownload:downloadId isBackground:[options[@"background"] boolValue]];
        }
        resolve(@{@"success": @YES});
        return;
    }
    if (!resumeData) {
        resolve(@{@"success": @NO, @"error": @"No resume data — download was not paused or was cancelled"});
        return;
    }

    BOOL isBackground = [options[@"background"] boolValue];
    NSURLSession *session = isBackground ? self.bgSession : self.fgSession;
    if (!session) {
        resolve(@{@"success": @NO, @"error": @"Module was invalidated"});
        return;
    }

    NSURLSessionDownloadTask *task = [session downloadTaskWithResumeData:resumeData];
    if (!task) {
        resolve(@{@"success": @NO, @"error": @"Could not resume download"});
        return;
    }
    // Tasks created from resume data do not inherit the description, and it is
    // how a relaunched process recovers the downloadId.
    task.taskDescription = downloadId;
    NSString *taskKey = FTKTaskKey(session, task);

    __block BOOL cancelled = NO;
    dispatch_sync(self.syncQueue, ^{
        if (!self.resumeDataStore[downloadId]) {
            cancelled = YES; // cancelDownload ran in between
            return;
        }
        self.taskIdMap[taskKey]      = downloadId;
        self.activeTasks[downloadId] = task;
        [self.resumeDataStore removeObjectForKey:downloadId];
    });
    if (cancelled) {
        [task cancel];
        resolve(@{@"success": @NO, @"error": @"No resume data — download was not paused or was cancelled"});
        return;
    }

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
        // A download waiting out a retry backoff has no task; dropping this makes
        // the pending dispatch_after bail instead of starting a new attempt.
        [self.pendingRetries  removeObjectForKey:downloadId];
        [self.lastProgressAt  removeObjectForKey:downloadId];
        FTKSetCancelled(downloadId, YES); // same step as the take, see -finishDownload:
    });
    FTKRemoveMeta(downloadId);
    if (funcs) {
        RCTPromiseResolveBlock dlResolve = funcs[@"resolve"];
        if (dlResolve) dlResolve(@{@"success": @NO, @"error": @"Cancelled"});
    }
    if (task) {
        [task cancel];
    } else {
        // A background download started by an earlier process (or module
        // instance) has no entry in activeTasks; find it by its description.
        [self.bgSession getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
            for (NSURLSessionTask *bgTask in downloadTasks) {
                if ([bgTask.taskDescription isEqualToString:downloadId]) [bgTask cancel];
            }
        }];
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

/**
 * Copies or moves `fromPath` to `toPath`, returning nil on success or an error
 * message. The item is staged next to the destination and rename(2)'d over it,
 * so an existing destination survives any failure. Copying a file onto itself
 * is a no-op rather than deleting it, and an existing directory is never
 * replaced (that used to wipe it recursively).
 */
static NSString *FTKTransferItem(NSString *fromPath, NSString *toPath, BOOL move) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL destIsDir = NO;
    if ([fm fileExistsAtPath:toPath isDirectory:&destIsDir]) {
        // Compare inodes, not strings: /private/var vs /var, symlinks, hard links.
        NSDictionary *src = [fm attributesOfItemAtPath:fromPath error:nil];
        NSDictionary *dst = [fm attributesOfItemAtPath:toPath error:nil];
        if (src && dst && [src[NSFileSystemNumber] isEqual:dst[NSFileSystemNumber]]
                       && [src[NSFileSystemFileNumber] isEqual:dst[NSFileSystemFileNumber]]) {
            return nil;
        }
        if (destIsDir) return [NSString stringWithFormat:@"Destination is a directory: %@", toPath];
    }

    NSString *parent = [toPath stringByDeletingLastPathComponent];
    if (parent.length > 0) {
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *tmp = [parent stringByAppendingPathComponent:
                     [NSString stringWithFormat:@".%@.ftk-tmp", [NSUUID UUID].UUIDString]];
    NSError *error = nil;
    BOOL staged = move ? [fm moveItemAtPath:fromPath toPath:tmp error:&error]
                       : [fm copyItemAtPath:fromPath toPath:tmp error:&error];
    if (!staged) {
        [fm removeItemAtPath:tmp error:nil];
        return error.localizedDescription ?: (move ? @"MOVE_FILE_ERROR" : @"COPY_FILE_ERROR");
    }
    if (rename(tmp.fileSystemRepresentation, toPath.fileSystemRepresentation) != 0) {
        NSString *reason = @(strerror(errno));
        if (move) [fm moveItemAtPath:tmp toPath:fromPath error:nil]; // put the source back
        else [fm removeItemAtPath:tmp error:nil];
        return reason;
    }
    return nil;
}

- (void)copyFile:(NSString *)fromPath toPath:(NSString *)toPath resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:fromPath isDirectory:&isDir] || isDir) {
        resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"Source file not found: %@", fromPath]});
        return;
    }

    NSString *error = FTKTransferItem(fromPath, toPath, NO);
    resolve(error ? @{@"success": @NO, @"error": error} : @{@"success": @YES});
}

// ─── moveFile ────────────────────────────────────────────────────────────────

- (void)moveFile:(NSString *)fromPath toPath:(NSString *)toPath resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:fromPath]) {
        resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"Source path not found: %@", fromPath]});
        return;
    }

    NSString *error = FTKTransferItem(fromPath, toPath, YES);
    resolve(error ? @{@"success": @NO, @"error": error} : @{@"success": @YES});
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
    NSURLSession *session = self.bgSession;
    if (!session) {
        resolve(@{@"success": @NO, @"error": @"Module was invalidated", @"downloads": @[]});
        return;
    }
    [session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
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
// Foreground callbacks arrive directly; background ones via FTKBackgroundSessionProxy.

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    // Without a Content-Length the total is unknown: report bytes only, with
    // progress/totalBytes = -1, and throttle since every chunk lands here.
    BOOL sizeKnown = totalBytesExpectedToWrite > 0;
    int progress = sizeKnown ? (int)((totalBytesWritten * 100) / totalBytesExpectedToWrite) : -1;
    int64_t totalBytes = sizeKnown ? totalBytesExpectedToWrite : -1;
    NSString *taskKey = FTKTaskKey(session, downloadTask);
    NSString *taskDownloadId = downloadTask.taskDescription;
    NSString *url = downloadTask.originalRequest.URL.absoluteString ?: @"";
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    __weak __typeof__(self) weakSelf = self;
    dispatch_async(self.syncQueue, ^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *downloadId = strongSelf.taskIdMap[taskKey] ?: taskDownloadId;
        if (!downloadId) return;

        if (!sizeKnown) {
            NSNumber *last = strongSelf.lastProgressAt[downloadId];
            if (last && now - last.doubleValue < kFTKUnknownSizeProgressInterval) return;
            strongSelf.lastProgressAt[downloadId] = @(now);
        }

        [strongSelf emitEvent:@"onDownloadProgress"
                         body:@{
                             @"url": url,
                             @"downloadId": downloadId,
                             @"progress": @(progress),
                             @"bytesDownloaded": @(totalBytesWritten),
                             @"totalBytes": @(totalBytes)
                         }];
    });
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    BOOL isBackground = session.configuration.identifier != nil;
    NSString *taskKey = FTKTaskKey(session, downloadTask);
    __block NSString *downloadId = nil;
    __block NSDictionary *options = nil;
    dispatch_sync(self.syncQueue, ^{
        downloadId = self.taskIdMap[taskKey];
        if (downloadId) {
            options = self.downloadOptions[downloadId];
        }
    });
    // A background download can finish after the app was terminated and relaunched,
    // in which case the in-memory maps are empty. The task itself still carries the
    // id, and its options were persisted, so recover both instead of dropping the
    // finished file on the floor (or saving it to the wrong place unverified).
    if (!downloadId) downloadId = downloadTask.taskDescription;
    if (!downloadId) return;
    if (!options && isBackground) options = FTKLoadMeta(downloadId);
    if (!options && (!isBackground || FTKWasCancelled(downloadId))) {
        // Cancelled while it was finishing: nobody wants the file, and JS was
        // already told "Cancelled".
        [[NSFileManager defaultManager] removeItemAtURL:location error:nil];
        dispatch_sync(self.syncQueue, ^{
            [self.taskIdMap removeObjectForKey:taskKey];
        });
        return;
    }

    BOOL isError = NO;
    NSDictionary *resultDict = FTKFinalizeDownload(downloadTask, location, downloadId, options, &isError);
    [self finishDownload:downloadId taskKey:taskKey result:resultDict isError:isError isBackground:isBackground];
}

/**
 * Settles a finished download: resolves the promise or emits the event, then cleans up.
 *
 * The promise is taken and removed in the same syncQueue block, so a racing
 * cancelDownload (or a second completion path) can never settle it twice.
 */
- (void)finishDownload:(NSString *)downloadId
               taskKey:(NSString *)taskKey
                result:(NSDictionary *)resultDict
               isError:(BOOL)isError
          isBackground:(BOOL)isBackground {
    __block NSDictionary *funcs = nil;
    __block BOOL claimed = NO;
    dispatch_sync(self.syncQueue, ^{
        // cancelDownload and a failed pause mark the id inside this same queue
        // when they settle it, so exactly one of them or this path reports it.
        claimed = !FTKWasCancelled(downloadId);
        if (claimed) {
            funcs = [self takeDownloadLocked:downloadId];
        }
        if (taskKey) [self.taskIdMap removeObjectForKey:taskKey];
    });
    if (!claimed) {
        // Already settled as cancelled: drop a file this completion moved into place.
        NSString *filePath = resultDict[@"filePath"];
        if (filePath) [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        return;
    }
    [self settleDownload:downloadId funcs:funcs result:resultDict isError:isError isBackground:isBackground];
}

/** Removes every trace of a download and returns its promise blocks. Call on syncQueue. */
- (NSDictionary *)takeDownloadLocked:(NSString *)downloadId {
    NSDictionary *funcs = self.activePromises[downloadId];
    [self.activePromises  removeObjectForKey:downloadId];
    [self.downloadOptions removeObjectForKey:downloadId];
    [self.activeTasks     removeObjectForKey:downloadId];
    [self.retryAttempts   removeObjectForKey:downloadId];
    [self.pendingRetries  removeObjectForKey:downloadId];
    [self.lastProgressAt  removeObjectForKey:downloadId];
    return funcs;
}

/** Reports a download already taken with -takeDownloadLocked:. */
- (void)settleDownload:(NSString *)downloadId
                 funcs:(NSDictionary *)funcs
                result:(NSDictionary *)resultDict
               isError:(BOOL)isError
          isBackground:(BOOL)isBackground {
    if (isBackground) FTKRemoveMeta(downloadId);

    if (funcs && !isBackground) {
        // Foreground: resolve the promise
        RCTPromiseResolveBlock resolve = funcs[@"resolve"];
        resolve(resultDict);
        // Also emit the error event for foreground failures so global listeners fire
        // consistently across platforms (mirrors Android behaviour).
        if (isError) {
            [self emitEvent:@"onDownloadError" body:resultDict];
        }
    } else {
        // Background: fire the correct event based on isError flag
        [self emitEvent:isError ? @"onDownloadError" : @"onDownloadComplete"
                   body:resultDict
        bufferIfUnheard:isBackground];
    }
}

/**
 * Our own cancel/pause. A background task the *system* cancelled (force quit,
 * Background App Refresh off, …) carries a reason key and is a real failure.
 */
static BOOL FTKIsOwnCancellation(NSError *error) {
    return [error.domain isEqualToString:NSURLErrorDomain] &&
           error.code == NSURLErrorCancelled &&
           error.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] == nil;
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    NSString *taskKey = FTKTaskKey(session, task);

    // ── Upload task completion ─────────────────────────────────────────────────
    __block NSString *uploadId = nil;
    __block NSDictionary *uploadFuncs = nil;
    __block NSData *uploadRespData = nil;
    dispatch_sync(self.syncQueue, ^{
        uploadId = self.uploadTaskIdMap[taskKey];
        if (uploadId) {
            // Taken and removed together so the promise can only settle once.
            uploadFuncs = self.uploadPromises[uploadId];
            uploadRespData = self.uploadResponseData[uploadId];
            [self.uploadPromises removeObjectForKey:uploadId];
            [self.uploadUrls removeObjectForKey:uploadId];
            [self.uploadResponseData removeObjectForKey:uploadId];
            [self.uploadTaskIdMap removeObjectForKey:taskKey];
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
        return;
    }

    // ── Download task error handling ───────────────────────────────────────
    if (!error) return;
    // Ignore cancellation — but still clean up taskIdMap to prevent memory leak
    if (FTKIsOwnCancellation(error)) {
        dispatch_sync(self.syncQueue, ^{
            [self.taskIdMap removeObjectForKey:taskKey];
        });
        return;
    }

    BOOL isBackground = session.configuration.identifier != nil;
    __block NSString *downloadId = nil;
    __block NSDictionary *options = nil;
    __block NSInteger currentAttempt = 0;
    dispatch_sync(self.syncQueue, ^{
        downloadId = self.taskIdMap[taskKey];
        if (downloadId) {
            options = self.downloadOptions[downloadId];
            currentAttempt = [self.retryAttempts[downloadId] integerValue];
        }
        // Remove old task mapping — will be replaced on retry
        [self.taskIdMap removeObjectForKey:taskKey];
        if (downloadId) [self.activeTasks removeObjectForKey:downloadId];
    });
    if (!downloadId) downloadId = task.taskDescription;
    if (!downloadId) return;
    if (!options && isBackground) options = FTKLoadMeta(downloadId);
    if (!options && (!isBackground || FTKWasCancelled(downloadId))) return; // cancelled while failing; already settled

    // ── Retry logic ────────────────────────────────────────────────────
    NSDictionary *retryConfig = [options[@"retry"] isKindOfClass:[NSDictionary class]] ? options[@"retry"] : nil;
    id attemptsValue = retryConfig[@"attempts"];
    NSInteger maxAttempts = [attemptsValue isKindOfClass:[NSNumber class]] ? [attemptsValue integerValue] : 0;
    // Only a missing delay defaults to 1000 ms; an explicit 0 means "retry at once".
    id delayValue = retryConfig[@"delay"];
    double delay = [delayValue isKindOfClass:[NSNumber class]] ? [delayValue doubleValue] : 1000;
    NSInteger baseDelay = delay > 0 ? (NSInteger)MIN(delay, 30000.0) : 0;

    if (currentAttempt < maxAttempts) {
        // Schedule a retry. Until it starts there is no task, so pendingRetries is
        // what lets cancel/pause/resume act on the download in the meantime.
        NSInteger nextAttempt = currentAttempt + 1;
        dispatch_sync(self.syncQueue, ^{
            self.retryAttempts[downloadId] = @(nextAttempt);
            self.pendingRetries[downloadId] = @(FTKRetryWaiting);
        });

        NSInteger shiftBits = currentAttempt < 15 ? currentAttempt : 15;
        NSInteger delayMs = MIN(baseDelay * (1 << shiftBits), (NSInteger)30000);

        // Emit retry event so JS onRetry callback is called
        [self emitEvent:@"onDownloadRetry" body:@{
            @"downloadId": downloadId,
            @"url": options[@"url"] ?: @"",
            @"attempt": @(nextAttempt),
            @"error": error.localizedDescription ?: @""
        }];

        __weak __typeof__(self) weakSelf = self;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
            ^{
                __strong __typeof__(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;

                // Re-checks cancel/pause/invalidate atomically before starting.
                [strongSelf startRetryForDownload:downloadId isBackground:isBackground];
            }
        );
        return; // Don't resolve promise yet — retry is in flight
    }

    // ── No more retries — normal error path ──────────────────────────────
    // finishDownload always emits onDownloadError, so global listeners fire on both platforms.
    NSDictionary *errDict = @{@"success": @NO, @"downloadId": downloadId, @"error": error.localizedDescription ?: @""};
    [self finishDownload:downloadId taskKey:nil result:errDict isError:YES isBackground:isBackground];
}

/** Starts the next attempt of a download whose retry backoff has elapsed. */
- (void)startRetryForDownload:(NSString *)downloadId isBackground:(BOOL)isBackground {
    __block NSDictionary *options = nil;
    dispatch_sync(self.syncQueue, ^{
        options = self.downloadOptions[downloadId];
    });
    if (!options) return; // cancelled in the meantime

    NSString *urlString = options[@"url"];
    NSURL *url = [urlString isKindOfClass:[NSString class]] ? [NSURL URLWithString:urlString] : nil;
    if (!url) {
        NSDictionary *errDict = @{@"success": @NO, @"downloadId": downloadId, @"error": @"Invalid URL"};
        [self finishDownload:downloadId taskKey:nil result:errDict isError:YES isBackground:isBackground];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    NSDictionary *headers = options[@"headers"];
    if ([headers isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in headers) {
            [request setValue:headers[key] forHTTPHeaderField:key];
        }
    }

    // Checking the retry state and creating the task are one step on syncQueue,
    // ordered against cancelDownload, pauseDownload and -invalidate (which sets
    // `invalidated` here before tearing the sessions down). So either the retry
    // starts and nobody reports it lost, or it is reported lost / cancelled /
    // paused and no task is ever created — and no task is created on a session
    // that is being invalidated.
    __block NSURLSessionDownloadTask *newTask = nil;
    dispatch_sync(self.syncQueue, ^{
        NSNumber *state = self.pendingRetries[downloadId];
        if (self.invalidated || !state || !self.downloadOptions[downloadId]) return;
        if (state.integerValue != FTKRetryWaiting) {
            // Paused during the backoff: hold until resumeDownload.
            self.pendingRetries[downloadId] = @(FTKRetryHeld);
            return;
        }
        NSURLSession *sess = isBackground ? self.bgSession : self.fgSession;
        if (!sess) return;
        [self.pendingRetries removeObjectForKey:downloadId];
        newTask = [sess downloadTaskWithRequest:request];
        newTask.taskDescription = downloadId;
        self.taskIdMap[FTKTaskKey(sess, newTask)] = downloadId;
        self.activeTasks[downloadId] = newTask;
    });
    [newTask resume];
}

// ─── Upload progress delegate ────────────────────────────────────────────────

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    if (totalBytesExpectedToSend > 0) {
        NSString *taskKey = FTKTaskKey(session, task);
        int progress = (int)((totalBytesSent * 100) / totalBytesExpectedToSend);
        
        __weak __typeof__(self) weakSelf = self;
        dispatch_async(self.syncQueue, ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            NSString *uploadId = strongSelf.uploadTaskIdMap[taskKey];
            if (uploadId) {
                NSString *url = strongSelf.uploadUrls[uploadId] ?: @"";
                [strongSelf emitEvent:@"onUploadProgress"
                                 body:@{@"url": url, @"uploadId": uploadId, @"progress": @(progress)}];
            }
        });
    }
}

// ─── Upload response data accumulation ───────────────────────────────────────

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    NSString *taskKey = FTKTaskKey(session, dataTask);
    dispatch_sync(self.syncQueue, ^{
        NSString *uploadId = self.uploadTaskIdMap[taskKey];
        if (!uploadId) return;
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
    
    NSURL *requestURL = [NSURL URLWithString:urlString];
    if (!requestURL) {
        resolve(@{@"success": @NO, @"error": @"Invalid URL"});
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"File not found: %@", filePath]});
        return;
    }

    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
    [request setHTTPMethod:@"POST"];
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    
    if (headers) {
        for (NSString *key in headers) {
            [request setValue:headers[key] forHTTPHeaderField:key];
        }
    }

    // Assembling the multipart body copies the whole source file, so keep it off
    // the caller's thread — otherwise a large upload blocks the native module
    // queue (and with it every other call into this module) until the copy ends.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    // Create a temporary file to avoid OutOfMemory crash for large uploads
    NSString *tempFileName = [NSString stringWithFormat:@"upload_%@.tmp", [[NSUUID UUID] UUIDString]];
    NSString *tempFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempFileName];

    [[NSFileManager defaultManager] createFileAtPath:tempFilePath contents:nil attributes:nil];
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:tempFilePath];
    if (!fileHandle) {
        [[NSFileManager defaultManager] removeItemAtPath:tempFilePath error:nil];
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
    
    // -writeData: raises an Objective-C exception on failure (e.g. disk full),
    // which would crash the app from this background queue; use the NSError API.
    NSError *bodyError = nil;
    BOOL bodyOK = [fileHandle writeData:preamble error:&bodyError];

    // Stream the actual file content to the temp file
    NSInputStream *inputStream = [NSInputStream inputStreamWithFileAtPath:filePath];
    [inputStream open];
    if (bodyOK && (!inputStream || inputStream.streamStatus == NSStreamStatusError)) {
        bodyOK = NO;
        bodyError = inputStream.streamError;
    }
    uint8_t buffer[32768]; // 32KB chunks
    while (bodyOK && [inputStream hasBytesAvailable]) {
        NSInteger bytesRead = [inputStream read:buffer maxLength:sizeof(buffer)];
        if (bytesRead > 0) {
            bodyOK = [fileHandle writeData:[NSData dataWithBytes:buffer length:bytesRead] error:&bodyError];
        } else if (bytesRead < 0) {
            // A read error must fail the upload, not send a truncated file.
            bodyOK = NO;
            bodyError = inputStream.streamError;
        } else {
            break;
        }
    }
    [inputStream close];

    if (bodyOK) {
        NSMutableData *postamble = [NSMutableData data];
        [postamble appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [postamble appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        bodyOK = [fileHandle writeData:postamble error:&bodyError];
    }
    NSError *closeError = nil;
    if (![fileHandle closeAndReturnError:&closeError] && bodyOK) {
        bodyOK = NO;
        bodyError = closeError;
    }
    if (!bodyOK) {
        [[NSFileManager defaultManager] removeItemAtPath:tempFilePath error:nil];
        resolve(@{@"success": @NO, @"error": bodyError.localizedDescription ?: @"Failed to write upload body"});
        return;
    }

    NSURL *tempFileURL = [NSURL fileURLWithPath:tempFilePath];

    NSURLSession *session = self.fgSession;
    if (!session) {
        [[NSFileManager defaultManager] removeItemAtPath:tempFilePath error:nil];
        resolve(@{@"success": @NO, @"error": @"Module was invalidated"});
        return;
    }

    // Use delegate-based session for upload progress support with fromFile: instead of fromData:
    NSURLSessionUploadTask *task = [session uploadTaskWithRequest:request fromFile:tempFileURL];
    NSString *taskKey = FTKTaskKey(session, task);

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
    });
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
    
    NSURL *destURL = FTKDestURL(fileName, destination);
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
    
    // Ephemeral session with a delegate, so the 50 MB cap is enforced while the
    // body arrives instead of after the whole response was buffered.
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    FTKBase64Fetch *fetch = [[FTKBase64Fetch alloc] initWithResolve:resolve];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:fetch delegateQueue:nil];
    [[session dataTaskWithRequest:request] resume];
    // Releases the session (and its strong delegate reference) once the task ends.
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

// Pure-Foundation zip reader/writer — zlib is a system library (s.libraries = "z"),
// so no third-party archive dependency is needed. See FileToolkitZip.mm.
RCT_EXPORT_METHOD(unzip:(NSString *)sourcePath
                  destDir:(NSString *)destDir
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray<NSString *> *extractedFiles = [NSMutableArray new];
        NSError *extractError = nil;
        if (FTKUnzipFile(sourcePath, destDir, extractedFiles, &extractError)) {
            resolve(@{@"success": @YES, @"destDir": destDir, @"files": extractedFiles});
        } else {
            resolve(@{@"success": @NO, @"error": extractError.localizedDescription ?: @"UNZIP_ERROR"});
        }
    });
}

// ─── Zip ──────────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(zip:(NSString *)sourcePath
                  destPath:(NSString *)destPath
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *zipError = nil;
        if (FTKZipPath(sourcePath, destPath, &zipError)) {
            resolve(@{@"success": @YES, @"zipPath": destPath});
        } else {
            resolve(@{@"success": @NO, @"error": zipError.localizedDescription ?: @"ZIP_ERROR"});
        }
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

        NSString *hashValue = FTKChecksum(filePath, [algorithm uppercaseString]);
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
        // Use Photos framework for images and videos.
        // Saving alone needs only add-only access (NSPhotoLibraryAddUsageDescription);
        // finding or creating an album needs read-write (NSPhotoLibraryUsageDescription).
        // Requesting an access level whose Info.plist key is missing kills the app,
        // so check first and report it instead.
        NSString *album = options[@"album"];
        if (![album isKindOfClass:[NSString class]] || album.length == 0) album = nil;
        NSString *usageKey = album ? @"NSPhotoLibraryUsageDescription" : @"NSPhotoLibraryAddUsageDescription";
        id usage = [[NSBundle mainBundle] objectForInfoDictionaryKey:usageKey];
        if (![usage isKindOfClass:[NSString class]] || [usage length] == 0) {
            resolve(@{@"success": @NO, @"error": [NSString stringWithFormat:@"Missing %@ in Info.plist", usageKey]});
            return;
        }

        BOOL isImage = [mediaType isEqualToString:@"image"];
        PHAccessLevel accessLevel = album ? PHAccessLevelReadWrite : PHAccessLevelAddOnly;
        [PHPhotoLibrary requestAuthorizationForAccessLevel:accessLevel handler:^(PHAuthorizationStatus status) {
            if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                resolve(@{@"success": @NO, @"error": @"Photo library access denied"});
                return;
            }

            PHAssetCollection *existingAlbum = nil;
            if (album) {
                PHFetchResult<PHAssetCollection *> *albums =
                    [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                             subtype:PHAssetCollectionSubtypeAlbumRegular
                                                             options:nil];
                for (PHAssetCollection *collection in albums) {
                    if ([collection.localizedTitle isEqualToString:album]) {
                        existingAlbum = collection;
                        break;
                    }
                }
            }

            PHPhotoLibrary *photoLibrary = [PHPhotoLibrary sharedPhotoLibrary];
            [photoLibrary performChanges:^{
                NSURL *fileURL = [NSURL fileURLWithPath:filePath];
                PHAssetChangeRequest *assetRequest = isImage
                    ? [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:fileURL]
                    : [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
                if (album) {
                    // Same change block, so the asset and its album membership land together.
                    PHAssetCollectionChangeRequest *albumRequest = existingAlbum
                        ? [PHAssetCollectionChangeRequest changeRequestForAssetCollection:existingAlbum]
                        : [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:album];
                    PHObjectPlaceholder *placeholder = assetRequest.placeholderForCreatedAsset;
                    if (placeholder) [albumRequest addAssets:@[placeholder]];
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

// ─── FTKBackgroundSessionProxy ────────────────────────────────────────────────

@implementation FTKBackgroundSessionProxy {
    NSMutableArray *_completionHandlers;       // guarded by @synchronized(self)
    BOOL _eventsFinishedWithoutHandler;        // guarded by @synchronized(self)
}

/**
 * Registered at image load — before UIApplicationMain — so the app delegate's
 * handleEventsForBackgroundURLSession notification is never missed, even when
 * the system relaunches the app in the background before React starts.
 */
+ (void)load {
    static id observer;
    observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:FTKBackgroundEventsNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        NSString *identifier = note.userInfo[@"identifier"];
        id handler = note.userInfo[@"completionHandler"];
        if (![identifier isKindOfClass:[NSString class]] ||
            ![identifier isEqualToString:FTKBackgroundSessionIdentifier()]) return; // another library's session
        if (![handler isKindOfClass:NSClassFromString(@"NSBlock")]) return;
        [[FTKBackgroundSessionProxy shared] addCompletionHandler:handler];
    }];
}

+ (instancetype)shared {
    static FTKBackgroundSessionProxy *proxy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        proxy = [FTKBackgroundSessionProxy new];
        proxy->_completionHandlers = [NSMutableArray new];
        NSURLSessionConfiguration *config =
            [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:FTKBackgroundSessionIdentifier()];
        config.discretionary = NO;
        config.sessionSendsLaunchEvents = YES;
        // Never invalidated: it must live as long as the process.
        proxy->_session = [NSURLSession sessionWithConfiguration:config delegate:proxy delegateQueue:nil];
        [proxy reconcileInheritedDownloads];
    });
    return proxy;
}

/**
 * Drops persisted entries from earlier launches whose task no longer exists
 * (paused when the app was killed — resume data is memory-only — or discarded
 * by the system) and tells JS with onDownloadError "DOWNLOAD_LOST".
 *
 * Entries written by this launch are skipped, so a download being started right
 * now can never be mistaken for a lost one. The decision runs on the session's
 * serial delegate queue, the same queue that delivers completions, so it cannot
 * interleave with a finishing download; the grace period gives tasks whose
 * results are still queued from the relaunch time to be reported first.
 */
- (void)reconcileInheritedDownloads {
    NSURLSession *session = _session;
    __weak FTKBackgroundSessionProxy *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kFTKReconcileDelaySeconds * (int64_t)NSEC_PER_SEC),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
            NSMutableSet<NSString *> *liveIds = [NSMutableSet new];
            for (NSURLSessionTask *task in tasks) {
                if (task.taskDescription) [liveIds addObject:task.taskDescription];
            }
            [session.delegateQueue addOperationWithBlock:^{
                NSDictionary *all = nil;
                @synchronized (FTKMetaLock()) {
                    all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:FTKBackgroundMetaKey];
                }
                for (NSString *downloadId in all) {
                    NSDictionary *meta = all[downloadId];
                    if (![meta isKindOfClass:[NSDictionary class]]) continue;
                    if ([meta[@"launch"] isEqual:FTKLaunchId()] || [liveIds containsObject:downloadId]) continue;
                    if (!FTKLoadMeta(downloadId)) continue; // finished meanwhile
                    FTKRemoveMeta(downloadId);
                    NSDictionary *body = @{@"success": @NO, @"downloadId": downloadId, @"error": @"DOWNLOAD_LOST"};
                    FileToolkit *module = weakSelf.module;
                    if (module) {
                        [module emitEvent:@"onDownloadError" body:body bufferIfUnheard:YES];
                    } else {
                        @synchronized (FTKEventLock()) {
                            FTKBufferEventLocked(@"onDownloadError", body);
                        }
                    }
                }
            }];
        }];
    });
}

- (void)attachModule:(FileToolkit *)module {
    @synchronized (self) {
        self.module = module;
    }
}

- (void)detachModule:(FileToolkit *)module {
    // A reload may create the new instance before the old one is invalidated.
    @synchronized (self) {
        if (self.module == module) self.module = nil;
    }
}

- (void)addCompletionHandler:(id)handler {
    // +shared has created the session by now, which is what makes the system
    // deliver the pending events in the first place.
    void (^block)(void) = [handler copy];
    BOOL callNow = NO;
    @synchronized (self) {
        if (_eventsFinishedWithoutHandler) {
            // The session (created early by the module) already drained its events.
            _eventsFinishedWithoutHandler = NO;
            callNow = YES;
        } else {
            [_completionHandlers addObject:block];
        }
    }
    if (callNow) dispatch_async(dispatch_get_main_queue(), block);
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    NSArray *handlers;
    @synchronized (self) {
        handlers = [_completionHandlers copy];
        [_completionHandlers removeAllObjects];
        if (handlers.count == 0) _eventsFinishedWithoutHandler = YES;
    }
    if (handlers.count == 0) return;
    // UIKit requires the handler on the main thread. Finished files were already
    // moved synchronously in didFinishDownloadingToURL:, so it is safe to suspend.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^handler)(void) in handlers) handler();
    });
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    [self.module URLSession:session
               downloadTask:downloadTask
               didWriteData:bytesWritten
          totalBytesWritten:totalBytesWritten
  totalBytesExpectedToWrite:totalBytesExpectedToWrite];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    FileToolkit *module = self.module;
    if (module) {
        [module URLSession:session downloadTask:downloadTask didFinishDownloadingToURL:location];
        return;
    }
    // No React instance (relaunched in the background, or between reloads): the
    // file must still be moved before this returns. The event waits for JS.
    NSString *downloadId = downloadTask.taskDescription;
    if (downloadId.length == 0) return;
    if (FTKWasCancelled(downloadId)) {
        [[NSFileManager defaultManager] removeItemAtURL:location error:nil];
        return;
    }
    BOOL isError = NO;
    NSDictionary *result = FTKFinalizeDownload(downloadTask, location, downloadId, FTKLoadMeta(downloadId), &isError);
    FTKRemoveMeta(downloadId);
    @synchronized (FTKEventLock()) {
        FTKBufferEventLocked(isError ? @"onDownloadError" : @"onDownloadComplete", result);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    FileToolkit *module = self.module;
    if (module) {
        [module URLSession:session task:task didCompleteWithError:error];
        return;
    }
    // Success was handled in didFinishDownloadingToURL:. Without a module there
    // is no retry state, so any real failure is final.
    if (!error || FTKIsOwnCancellation(error)) return;
    NSString *downloadId = task.taskDescription;
    if (downloadId.length == 0 || FTKWasCancelled(downloadId)) return;
    FTKRemoveMeta(downloadId);
    @synchronized (FTKEventLock()) {
        FTKBufferEventLocked(@"onDownloadError", @{
            @"success": @NO,
            @"downloadId": downloadId,
            @"error": error.localizedDescription ?: @""
        });
    }
}

@end

// ─── FTKBase64Fetch ───────────────────────────────────────────────────────────

// All callbacks arrive on the session's serial delegate queue, so no locking.
@implementation FTKBase64Fetch {
    RCTPromiseResolveBlock _resolve;
    NSMutableData *_data;
    NSString *_mimeType;
    BOOL _settled;
}

- (instancetype)initWithResolve:(RCTPromiseResolveBlock)resolve {
    if (self = [super init]) {
        _resolve = [resolve copy];
    }
    return self;
}

- (void)settle:(NSDictionary *)result {
    if (_settled) return;
    _settled = YES;
    _data = nil;
    _resolve(result);
}

- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(FTKRedirectRequest(task, request));
}

- (void)settleTooLarge {
    [self settle:@{@"success": @NO, @"error": @"Response exceeds 50 MB limit for urlToBase64"}];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)response : nil;
    if (httpResponse && (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300)) {
        [self settle:@{@"success": @NO, @"error": [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]}];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    // Reject up front when the server announces the size.
    if (response.expectedContentLength > kFTKBase64MaxBytes) {
        [self settleTooLarge];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    _mimeType = response.MIMEType;
    _data = [NSMutableData dataWithCapacity:response.expectedContentLength > 0
                                            ? (NSUInteger)response.expectedContentLength : 0];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (_settled) return;
    if (!_data) _data = [NSMutableData new];
    // …and while receiving, for chunked responses or a lying Content-Length.
    if ((long long)_data.length + (long long)data.length > kFTKBase64MaxBytes) {
        [self settleTooLarge];
        [dataTask cancel];
        return;
    }
    [_data appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (_settled) return;
    if (error) {
        [self settle:@{@"success": @NO, @"error": error.localizedDescription ?: @"URL_TO_BASE64_ERROR"}];
        return;
    }
    NSData *body = _data;
    _data = nil;
    if (body.length == 0) {
        [self settle:@{@"success": @NO, @"error": @"No data received"}];
        return;
    }

    // Get MIME type from response
    NSString *mimeType = _mimeType ?: @"application/octet-stream";
    NSString *base64String = [body base64EncodedStringWithOptions:0];
    body = nil; // drop the raw bytes before building the data URI copy
    NSString *dataUri = [NSString stringWithFormat:@"data:%@;base64,%@", mimeType, base64String];

    [self settle:@{
        @"success": @YES,
        @"base64": base64String,
        @"mimeType": mimeType,
        @"dataUri": dataUri
    }];
}

@end
