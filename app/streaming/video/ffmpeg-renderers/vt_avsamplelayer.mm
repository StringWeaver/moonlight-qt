// Nasty hack to avoid conflict between AVFoundation and
// libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "vt.h"
#include "pacer/pacer.h"
#undef AVMediaType

#include <SDL_syswm.h>
#include <Limelight.h>
#include <streaming/session.h>
#include <ScopedSignpost.h>

#include <mach/mach_time.h>
#import <Cocoa/Cocoa.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
#import <Metal/Metal.h>
#import <AppKit/AppKit.h>

class VTRenderer;

@interface CADisplayLinkCreator : NSObject
- (instancetype)initWithRenderer:(VTRenderer*)renderer;
- (CADisplayLink*) getDisplayLink: (NSView*) view;
@end

@interface VTView : NSView
- (NSView *)hitTest:(NSPoint)point;
@end

@implementation VTView

- (NSView *)hitTest:(NSPoint)point {
    Q_UNUSED(point);
    return nil;
}

@end

class VTRenderer : public VTBaseRenderer
{
public:
    VTRenderer()
        : VTBaseRenderer(RendererType::VTSampleLayer),
          m_HwContext(nullptr),
          m_DisplayLayer(nullptr),
          m_FormatDesc(nullptr),
          m_StreamView(nullptr),
          m_DisplayLink(nullptr),
          m_DisplayLinkCreator(nullptr),
          m_LastColorSpace(-1),
          m_ColorSpace(nullptr),
          m_VsyncMutex(nullptr),
          m_VsyncPassed(nullptr),
          m_EnableFramePacing(false)
    {
        SDL_zero(m_OverlayTextFields);
        for (int i = 0; i < Overlay::OverlayMax; i++) {
            m_OverlayUpdateBlocks[i] = dispatch_block_create(DISPATCH_BLOCK_DETACHED, ^{
                updateOverlayOnMainThread((Overlay::OverlayType)i);
            });
        }
        m_EnableRasterization = StreamingPreferences::get()->enableVTRasterization;
    }

    virtual ~VTRenderer() override
    { @autoreleasepool {
        // We may have overlay update blocks enqueued for execution.
        // We must cancel those to avoid a UAF.
        for (int i = 0; i < Overlay::OverlayMax; i++) {
            dispatch_block_cancel(m_OverlayUpdateBlocks[i]);
            Block_release(m_OverlayUpdateBlocks[i]);
        }
        
        if (m_DisplayLink) {
            SDL_assert(m_DisplayLinkCreator != nullptr);
            [m_DisplayLink invalidate];
            //[m_DisplayLink release];
        }
        if(m_DisplayLinkCreator != nullptr){
            [m_DisplayLinkCreator release];
        }
        if (m_VsyncPassed != nullptr) {
            SDL_DestroyCond(m_VsyncPassed);
        }

        if (m_VsyncMutex != nullptr) {
            SDL_DestroyMutex(m_VsyncMutex);
        }

        if (m_HwContext != nullptr) {
            av_buffer_unref(&m_HwContext);
        }

        if (m_FormatDesc != nullptr) {
            CFRelease(m_FormatDesc);
        }

        if (m_ColorSpace != nullptr) {
            CGColorSpaceRelease(m_ColorSpace);
        }

        for (int i = 0; i < Overlay::OverlayMax; i++) {
            if (m_OverlayTextFields[i] != nullptr) {
                [m_OverlayTextFields[i] removeFromSuperview];
                [m_OverlayTextFields[i] release];
            }
        }

        if (m_StreamView != nullptr) {
            [m_StreamView removeFromSuperview];
            [m_StreamView release];
        }

        if (m_DisplayLayer != nullptr) {
            [m_DisplayLayer release];
        }

        // It appears to be necessary to run the event loop after destroying
        // the AVSampleBufferDisplayLayer to avoid issue #973.
        SDL_PumpEvents();
    }}

    static
    void
    displayLinkOutputCallback(CADisplayLink* sender, VTRenderer* me)
    {
        SDL_assert(sender == me->m_DisplayLink);
        if(me->m_EnableFramePacing){
            SDL_LockMutex(me->m_VsyncMutex);
            SDL_CondSignal(me->m_VsyncPassed);
            SDL_UnlockMutex(me->m_VsyncMutex);
        }
    }

    bool initializeVsyncCallback(int framerate)
    {
        
        if(m_DisplayLinkCreator == nullptr) {
            m_DisplayLinkCreator = [[CADisplayLinkCreator alloc] initWithRenderer: this];
        }
        m_DisplayLink = [m_DisplayLinkCreator getDisplayLink: m_StreamView];
        
        if (m_DisplayLink == nil) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "Failed to create CVDisplayLink");
            return false;
        }
        [m_DisplayLink setPreferredFrameRateRange:CAFrameRateRangeMake(framerate, framerate, framerate)];
        // The CVDisplayLink callback uses these, so we must initialize them before
        // starting the callbacks.
        m_VsyncMutex = SDL_CreateMutex();
        m_VsyncPassed = SDL_CreateCond();

        [m_DisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];

        return true;
    }

    virtual void waitToRender() override
    {
        SCOPED_SIGNPOST("waitToRender");
        if (m_EnableFramePacing) {
            // Vsync is enabled, so wait for a swap before returning
            SDL_LockMutex(m_VsyncMutex);
            if (SDL_CondWaitTimeout(m_VsyncPassed, m_VsyncMutex, 100) == SDL_MUTEX_TIMEDOUT) {
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                            "V-sync wait timed out after 100 ms");
            }
            SDL_UnlockMutex(m_VsyncMutex);
        }
    }

    // Caller frees frame after we return
    virtual void renderFrame(AVFrame* frame) override
    { @autoreleasepool {
        SCOPED_SIGNPOST("RenderFrame, PTS:%d", frame->pts % 5000);
        OSStatus status;
        CVPixelBufferRef pixBuf = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);

        if (m_DisplayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "Resetting failed AVSampleBufferDisplay layer");

            // Trigger the main thread to recreate the decoder
            SDL_Event event;
            event.type = SDL_RENDER_TARGETS_RESET;
            SDL_PushEvent(&event);
            return;
        }

        // FFmpeg 5.0+ sets the CVPixelBuffer attachments properly now, so we don't have to
        // fix them up ourselves (except CGColorSpace and PAR attachments).

        // The VideoToolbox decoder attaches pixel aspect ratio information to the CVPixelBuffer
        // which will rescale the video stream in accordance with the host display resolution
        // to preserve the original aspect ratio of the host desktop. This behavior currently
        // differs from the behavior of all other Moonlight Qt renderers, so we will strip
        // these attachments for consistent behavior.
        CVBufferRemoveAttachment(pixBuf, kCVImageBufferPixelAspectRatioKey);

        // Reset m_ColorSpace if the colorspace changes. This can happen when
        // a game enters HDR mode (Rec 601 -> Rec 2020).
        int colorspace = getFrameColorspace(frame);
        if (colorspace != m_LastColorSpace) {
            if (m_ColorSpace != nullptr) {
                CGColorSpaceRelease(m_ColorSpace);
                m_ColorSpace = nullptr;
            }

            switch (colorspace) {
            case COLORSPACE_REC_709:
                m_ColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceCoreMedia709);
                break;
            case COLORSPACE_REC_2020:
                // This is necessary to ensure HDR works properly with external displays on macOS Sonoma.
                if (frame->color_trc == AVCOL_TRC_SMPTE2084) {
                    m_ColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
                }
                else {
                    m_ColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
                }
                break;
            case COLORSPACE_REC_601:
                m_ColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                break;
            }

            m_LastColorSpace = colorspace;
        }

        if (m_ColorSpace != nullptr) {
            CVBufferSetAttachment(pixBuf, kCVImageBufferCGColorSpaceKey, m_ColorSpace, kCVAttachmentMode_ShouldPropagate);
        }

        // Attach HDR metadata if it has been provided by the host
        if (m_MasteringDisplayColorVolume != nullptr) {
            CVBufferSetAttachment(pixBuf, kCVImageBufferMasteringDisplayColorVolumeKey, m_MasteringDisplayColorVolume, kCVAttachmentMode_ShouldPropagate);
        }
        if (m_ContentLightLevelInfo != nullptr) {
            CVBufferSetAttachment(pixBuf, kCVImageBufferContentLightLevelInfoKey, m_ContentLightLevelInfo, kCVAttachmentMode_ShouldPropagate);
        }

        // If the format has changed or doesn't exist yet, construct it with the
        // pixel buffer data
        if (!m_FormatDesc || !CMVideoFormatDescriptionMatchesImageBuffer(m_FormatDesc, pixBuf)) {
            if (m_FormatDesc != nullptr) {
                CFRelease(m_FormatDesc);
            }
            status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                  pixBuf, &m_FormatDesc);
            if (status != noErr) {
                SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                             "CMVideoFormatDescriptionCreateForImageBuffer() failed: %d",
                             status);
                return;
            }
        }

        // Queue this sample for the next v-sync
        CMSampleTimingInfo timingInfo = {
            .duration = kCMTimeInvalid,
            .presentationTimeStamp = CMTimeMake(frame->pts, 1000),
            .decodeTimeStamp = kCMTimeInvalid,
        };

        CMSampleBufferRef sampleBuffer;
        status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                          pixBuf,
                                                          m_FormatDesc,
                                                          &timingInfo,
                                                          &sampleBuffer);
        if (status != noErr) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "CMSampleBufferCreateReadyWithImageBuffer() failed: %d",
                         status);
            return;
        }

        [m_DisplayLayer enqueueSampleBuffer:sampleBuffer];

        CFRelease(sampleBuffer);
    }}
    
    virtual bool initialize(PDECODER_PARAMETERS params) override
    {
        //The AppKit and UIKit frameworks process each event-loop iteration (such as a mouse down event or a tap) within an autorelease pool block. Therefore you typically do not have to create an autorelease pool block yourself, or even see the code that is used to create one. from: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html
        int err;

        if (!checkDecoderCapabilities([MTLCreateSystemDefaultDevice() autorelease], params)) {
            return false;
        }

        err = av_hwdevice_ctx_create(&m_HwContext,
                                     AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                     nullptr,
                                     nullptr,
                                     0);
        if (err < 0) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "av_hwdevice_ctx_create() failed for VT decoder: %d",
                        err);
            m_InitFailureReason = InitFailureReason::NoSoftwareSupport;
            return false;
        }

        if (qgetenv("VT_FORCE_INDIRECT") == "1") {
            SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                        "Using indirect rendering due to environment variable");
            m_DirectRendering = false;
        }
        else {
            m_DirectRendering = true;
        }

        // If we're using direct rendering, set up the AVSampleBufferDisplayLayer
        if (m_DirectRendering) {
            SDL_SysWMinfo info;

            SDL_VERSION(&info.version);

            if (!SDL_GetWindowWMInfo(params->window, &info)) {
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                            "SDL_GetWindowWMInfo() failed: %s",
                            SDL_GetError());
                return false;
            }

            SDL_assert(info.subsystem == SDL_SYSWM_COCOA);

            // SDL adds its own content view to listen for events.
            // We need to add a subview for our display layer.
            NSView* contentView = info.info.cocoa.window.contentView;
            m_StreamView = [[VTView alloc] initWithFrame:contentView.bounds];

            m_DisplayLayer = [[AVSampleBufferDisplayLayer alloc] init];
            m_DisplayLayer.bounds = m_StreamView.bounds;
            m_DisplayLayer.position = CGPointMake(CGRectGetMidX(m_StreamView.bounds), CGRectGetMidY(m_StreamView.bounds));
            m_DisplayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
            m_DisplayLayer.opaque = YES;

            // This workaround prevents the image from going through processing that causes some
            // color artifacts in some cases. HDR seems to be okay without this, so we'll exclude
            // it out of caution. The artifacts seem to be far more significant on M1 Macs and
            // the workaround can cause performance regressions on Intel Macs, so only use this
            // on Apple silicon.
            //
            // https://github.com/moonlight-stream/moonlight-qt/issues/493
            // https://github.com/moonlight-stream/moonlight-qt/issues/722
            if (m_EnableRasterization) {
                SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                            "Using layer rasterization workaround");
                if (info.info.cocoa.window.screen != nullptr) {
                    m_DisplayLayer.shouldRasterize = YES;
                    m_DisplayLayer.rasterizationScale = info.info.cocoa.window.screen.backingScaleFactor;
                }
                else {
                    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                                "Unable to rasterize layer due to missing NSScreen");
                    SDL_assert(false);
                }
            }

            // Create a layer-hosted view by setting the layer before wantsLayer
            // This avoids us having to add our AVSampleBufferDisplayLayer as a
            // sublayer of a layer-backed view which leaves a useless layer in
            // the middle.
            m_StreamView.layer = m_DisplayLayer;
            m_StreamView.wantsLayer = YES;

            [contentView addSubview: m_StreamView];
            m_EnableFramePacing = params->enableFramePacing;
            if (!initializeVsyncCallback(params->frameRate)) {
                return false;
            }

        }
        return true;
    }

    void updateOverlayOnMainThread(Overlay::OverlayType type)
    { @autoreleasepool {
        // Lazy initialization for the overlay
        if (m_OverlayTextFields[type] == nullptr) {
            m_OverlayTextFields[type] = [[NSTextField alloc] initWithFrame:m_StreamView.bounds];
            [m_OverlayTextFields[type] setBezeled:NO];
            [m_OverlayTextFields[type] setDrawsBackground:NO];
            [m_OverlayTextFields[type] setEditable:NO];
            [m_OverlayTextFields[type] setSelectable:NO];

            switch (type) {
            case Overlay::OverlayDebug:
                [m_OverlayTextFields[type] setAlignment:NSTextAlignmentLeft];
                break;
            case Overlay::OverlayStatusUpdate:
                [m_OverlayTextFields[type] setAlignment:NSTextAlignmentRight];
                break;
            default:
                break;
            }

            SDL_Color color = Session::get()->getOverlayManager().getOverlayColor(type);
            [m_OverlayTextFields[type] setTextColor:[NSColor colorWithSRGBRed:color.r / 255.0 green:color.g / 255.0 blue:color.b / 255.0 alpha:color.a / 255.0]];
            [m_OverlayTextFields[type] setFont:[NSFont messageFontOfSize:Session::get()->getOverlayManager().getOverlayFontSize(type)]];

            [m_StreamView addSubview: m_OverlayTextFields[type]];
        }

        // Update text contents
        [m_OverlayTextFields[type] setStringValue: [NSString stringWithUTF8String:Session::get()->getOverlayManager().getOverlayText(type)]];

        // Unhide if it's enabled
        [m_OverlayTextFields[type] setHidden: !Session::get()->getOverlayManager().isOverlayEnabled(type)];
    }}

    virtual void notifyOverlayUpdated(Overlay::OverlayType type) override
    {
        // We must do the actual UI updates on the main thread, so queue an
        // async callback on the main thread via GCD to do the UI update.
        dispatch_async(dispatch_get_main_queue(), m_OverlayUpdateBlocks[type]);
    }

    virtual bool prepareDecoderContext(AVCodecContext* context, AVDictionary**) override
    {
        context->hw_device_ctx = av_buffer_ref(m_HwContext);

        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                    "Using VideoToolbox AVSampleBufferDisplayLayer renderer");

        return true;
    }

    virtual bool needsTestFrame() override
    {
        // We used to trust VT to tell us whether decode will work, but
        // there are cases where it can lie because the hardware technically
        // can decode the format but VT is unserviceable for some other reason.
        // Decoding the test frame will tell us for sure whether it will work.
        return true;
    }

    int getDecoderColorspace() override
    {
        // REC_601 has a litte bit of red tint on grey area
        return COLORSPACE_REC_709;
    }
    
    int getDecoderColorRange() override
    {
        return COLOR_RANGE_FULL;
    }


    int getDecoderCapabilities() override
    {
        return CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
               CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;
    }

    int getRendererAttributes() override
    {
        // AVSampleBufferDisplayLayer supports HDR output
        return RENDERER_ATTRIBUTE_HDR_SUPPORT;
    }

    bool isDirectRenderingSupported() override
    {
        return m_DirectRendering;
    }

private:
    AVBufferRef* m_HwContext;
    AVSampleBufferDisplayLayer* m_DisplayLayer;
    CMVideoFormatDescriptionRef m_FormatDesc;
    NSView* m_StreamView;
    dispatch_block_t m_OverlayUpdateBlocks[Overlay::OverlayMax];
    NSTextField* m_OverlayTextFields[Overlay::OverlayMax];
    CADisplayLink* m_DisplayLink;
    CADisplayLinkCreator* m_DisplayLinkCreator;
    int m_LastColorSpace;
    CGColorSpaceRef m_ColorSpace;
    SDL_mutex* m_VsyncMutex;
    SDL_cond* m_VsyncPassed;
    bool m_DirectRendering;
    bool m_EnableRasterization;
    bool m_EnableFramePacing;
};

IFFmpegRenderer* VTRendererFactory::createRenderer() {
    return new VTRenderer();
}

@implementation CADisplayLinkCreator{
    VTRenderer*  _renderer;
}

- (instancetype)initWithRenderer: (VTRenderer*)renderer  {
    self = [super init];
    if (self) {
        _renderer = renderer;
    }
    return self;
}

- (void)callback:(CADisplayLink *)sender {
    VTRenderer::displayLinkOutputCallback(sender, _renderer);
}

- (CADisplayLink*) getDisplayLink: (NSView*) view{
    return [view displayLinkWithTarget:self selector:@selector(callback:)];
}

@end
