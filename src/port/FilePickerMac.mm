#include "port/FilePicker.h"

#import <AppKit/AppKit.h>

// In-process NSOpenPanel/NSSavePanel backend for macOS. The portable-file-dialogs backend drives an
// external osascript process, so its dialog belongs to another app: over a fullscreen game window it
// can land behind the fullscreen Space (an apparently endless beachball), and the main thread blocks
// without pumping events while it waits. A panel owned by this app presents above our own fullscreen
// Space, and it is shown ASYNCHRONOUSLY (beginWithCompletionHandler) so the game loop keeps rendering
// and pumping events while the panel service starts up — no beachball even on the service's slow
// first launch. The completion handler fires on the main thread from the normal event pump; callers
// already treat PickFile as callback-based, and the extraction flow polls for the result each frame.

namespace fs = std::filesystem;

namespace Lighthouse {

void PickFileMac(Ship::FileBrowserRequest request, std::function<void(std::optional<fs::path>)> onResult) {
    @autoreleasepool {
        // "*.z64"-style patterns -> bare extensions for the panel; a lone "*" means no filtering.
        NSMutableArray<NSString*>* extensions = [NSMutableArray array];
        bool allowAll = false;
        for (const auto& filter : request.Filters) {
            for (const auto& pattern : filter.Patterns) {
                if (pattern == "*" || pattern == "*.*") {
                    allowAll = true;
                } else if (pattern.rfind("*.", 0) == 0 && pattern.size() > 2) {
                    [extensions addObject:[NSString stringWithUTF8String:pattern.substr(2).c_str()]];
                }
            }
        }

        NSSavePanel* panel;
        if (request.Save) {
            panel = [NSSavePanel savePanel];
            if (!request.DefaultName.empty()) {
                panel.nameFieldStringValue = [NSString stringWithUTF8String:request.DefaultName.c_str()];
            }
        } else {
            NSOpenPanel* openPanel = [NSOpenPanel openPanel];
            openPanel.canChooseFiles = YES;
            openPanel.canChooseDirectories = NO;
            openPanel.allowsMultipleSelection = NO;
            panel = openPanel;
        }
        panel.message = [NSString stringWithUTF8String:request.Title.c_str()];
        if (!allowAll && extensions.count > 0) {
            // Deprecated in favor of allowedContentTypes (UTType needs macOS 11+; deployment
            // target is 10.15), still fully functional.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            panel.allowedFileTypes = extensions;
#pragma clang diagnostic pop
            panel.allowsOtherFileTypes = YES;
        }
        if (!request.StartDir.empty()) {
            panel.directoryURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:request.StartDir.string().c_str()]
                                            isDirectory:YES];
        }


        // The completion handler owns the C++ callback via a heap copy (ObjC blocks capture C++
        // objects by const copy, which std::function's move-only payloads may not survive). The
        // copied block retains `panel`, keeping it alive until the handler runs.
        auto* callback = new std::function<void(std::optional<fs::path>)>(std::move(onResult));
        NSSavePanel* shownPanel = panel;
        [NSApp activateIgnoringOtherApps:YES];
        [panel beginWithCompletionHandler:^(NSModalResponse response) {
            std::optional<fs::path> result;
            if (response == NSModalResponseOK && shownPanel.URL != nil) {
                result = fs::path(shownPanel.URL.fileSystemRepresentation);
            }
            if (*callback) {
                (*callback)(result);
            }
            delete callback;
        }];
    }
}

} // namespace Lighthouse
