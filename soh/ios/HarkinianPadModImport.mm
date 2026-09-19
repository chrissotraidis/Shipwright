#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "HarkinianPadModImport.h"
#include "../soh/Enhancements/ModPackImport.h"
#include <atomic>
#include <mutex>
#include <spdlog/spdlog.h>

static std::atomic_bool busy(false), completed(false);
static std::mutex statusMutex;
static std::string status = "Import .o2r, .otr, or ZIP packs. Extract .7z downloads first.";
static void SetStatus(std::string message) {
    std::lock_guard<std::mutex> lock(statusMutex);
    status = std::move(message);
}
@interface HarkinianPadModPicker : NSObject <UIDocumentPickerDelegate>
@end
static HarkinianPadModPicker* delegate;
@implementation HarkinianPadModPicker
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
    SetStatus("Import cancelled. Existing packs are unchanged.");
    busy = false;
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    SetStatus("Importing packs. Large downloads may take a while...");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        size_t imported = 0, failed = 0;
        std::string lastError;
        for (NSURL* url in urls) {
            BOOL scoped = [url startAccessingSecurityScopedResource];
            NSError* coordinationError = nil;
            NSFileCoordinator* coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            __block size_t count = 0;
            __block std::string failure;
            [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL* readable) {
                namespace fs = std::filesystem;
                fs::path stage;
                bool ownsStage = false;
                try {
                    auto docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                    auto cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
                    const std::string batch = std::string("Import-") + NSUUID.UUID.UUIDString.UTF8String;
                    fs::path mods = fs::path(docs.UTF8String) / "mods";
                    fs::create_directories(mods);
                    stage = fs::path(cache.UTF8String) / batch;
                    count = ModPackImport::Import(fs::path(readable.fileSystemRepresentation), stage);
                    ownsStage = true;
                    // Atomic directory publication: the scanner never sees a partial pack.
                    fs::rename(stage, mods / batch);
                } catch (const std::exception& error) {
                    failure = error.what();
                    // Filesystem errors contain sandbox paths; present a generic storage message instead.
                    if (dynamic_cast<const fs::filesystem_error*>(&error))
                        failure = "Cannot save pack. Check Files access and available storage.";
                    count = 0;
                    std::error_code ignored;
                    if (ownsStage) fs::remove_all(stage, ignored);
                }
            }];
            if (scoped) [url stopAccessingSecurityScopedResource];
            if (coordinationError || !failure.empty()) {
                ++failed;
                lastError = coordinationError ? "Cannot read the selected file. Download it in Files and retry." : failure;
            } else imported += count;
        }
        SetStatus("Imported " + std::to_string(imported) + " pack(s). " +
                  (failed ? std::to_string(failed) + " file(s) failed: " + lastError : "Enable them in Edit, then save and restart."));
        SPDLOG_INFO("HarkinianPad mod import: imported={}, failed={}", imported, failed);
        completed = imported != 0;
        busy = false;
    });
}
@end
void HarkinianPad_ImportMods() {
    if (busy.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController* presenter = nil;
        for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow* window in ((UIWindowScene*)scene).windows)
                if (window.isKeyWindow) presenter = window.rootViewController;
        }
        // SDL's existing application delegate also supports the pre-scene lifecycle.
        if (!presenter) {
            for (UIWindow* window in UIApplication.sharedApplication.windows)
                if (window.isKeyWindow) presenter = window.rootViewController;
        }
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        if (!presenter || presenter.isBeingDismissed) {
            SetStatus("Files is unavailable right now. Close other dialogs and retry.");
            busy = false;
            return;
        }
        if (!delegate) delegate = [HarkinianPadModPicker new];
        UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[UTTypeItem] asCopy:NO];
        picker.allowsMultipleSelection = YES;
        picker.delegate = delegate;
        [presenter presentViewController:picker animated:YES completion:nil];
    });
}
bool HarkinianPad_ModImportBusy() { return busy.load(); }
bool HarkinianPad_ModImportCompleted() { return completed.exchange(false); }
std::string HarkinianPad_ModImportStatus() { std::lock_guard<std::mutex> lock(statusMutex); return status; }
