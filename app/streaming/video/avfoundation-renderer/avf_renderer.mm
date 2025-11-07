#include "avf_renderer.h"

#import <Cocoa/Cocoa.h>
#include <SDL_syswm.h>
#include "settings/streamingpreferences.h"


AVFoundationVideoRenderer::AVFoundationVideoRenderer(): m_Renderer(nil), m_StreamView(nil)
{
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
}
AVFoundationVideoRenderer::~AVFoundationVideoRenderer() {
    if(m_Renderer){
        [m_Renderer stop];
        [m_Renderer release];
    }
}
bool AVFoundationVideoRenderer::initialize(PDECODER_PARAMETERS params) {
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
    m_StreamView = info.info.cocoa.window.contentView;
    m_Renderer = [[VideoDecoderRenderer alloc] initWithView:m_StreamView streamAspectRatio:(float)params->width / params->height useFramePacing:params->enableVsync];
    if(m_Renderer){
        [m_Renderer setupWithVideoFormat:params->videoFormat width:params->width height:params->height frameRate:params->frameRate];
        [m_Renderer start];
    }
    
    return true;
}
bool AVFoundationVideoRenderer::isHardwareAccelerated() {
    return true;
}
bool AVFoundationVideoRenderer::isAlwaysFullScreen() {
    return false;
}
bool AVFoundationVideoRenderer::isHdrSupported() {
    return true;
}
int AVFoundationVideoRenderer::getDecoderCapabilities() {
    int capabilities =CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC | CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC;
    capabilities |= CAPABILITY_PULL_RENDERER;
    return capabilities;
}
int AVFoundationVideoRenderer::getDecoderColorspace() {
    return COLORSPACE_REC_709;
}
int AVFoundationVideoRenderer::getDecoderColorRange() {
    return COLOR_RANGE_FULL;
}
QSize AVFoundationVideoRenderer::getDecoderMaxResolution() {
    return QSize(0,0);
}
int AVFoundationVideoRenderer::submitDecodeUnit(PDECODE_UNIT du) {
    return [m_Renderer DrSubmitDecodeUnit:du];
}
void AVFoundationVideoRenderer::renderFrameOnMainThread() {
    [m_Renderer decodeThreadMain];
}
void AVFoundationVideoRenderer::setHdrMode(bool enabled) {
    [m_Renderer setHdrMode:enabled];
}
bool AVFoundationVideoRenderer::notifyWindowChanged(PWINDOW_STATE_CHANGE_INFO info) {
    auto unhandledStateFlags = info->stateChangeFlags;

    // We can always handle size changes
    unhandledStateFlags &= ~WINDOW_STATE_CHANGE_SIZE;

    // We can handle monitor changes
    unhandledStateFlags &= ~WINDOW_STATE_CHANGE_DISPLAY;

    // If nothing is left, we handled everything
    return unhandledStateFlags == 0;
}

IVideoDecoder* AVFRendererFactory::createDecoder() {
    return new AVFoundationVideoRenderer();
}
