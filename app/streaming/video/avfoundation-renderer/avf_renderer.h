
#pragma once
#include "decoder.h"
extern "C" {
    #include <libavcodec/avcodec.h>
}
#ifdef __OBJC__
#import "VideoDecoderRenderer.h"

@interface AVFView : NSView
- (NSView *)hitTest:(NSPoint)point;
@end

@implementation AVFView

- (NSView *)hitTest:(NSPoint)point {
    Q_UNUSED(point);
    return nil;
}
@end

class AVFoundationVideoRenderer : public IVideoDecoder {
public:
    AVFoundationVideoRenderer();
    virtual ~AVFoundationVideoRenderer() override;
    virtual bool initialize(PDECODER_PARAMETERS params) override;
    virtual bool isHardwareAccelerated() override;
    virtual bool isAlwaysFullScreen() override;
    virtual bool isHdrSupported() override;
    virtual int getDecoderCapabilities() override;
    virtual int getDecoderColorspace() override;
    virtual int getDecoderColorRange() override;
    virtual QSize getDecoderMaxResolution() override;
    virtual int submitDecodeUnit(PDECODE_UNIT du) override;
    virtual void renderFrameOnMainThread() override;
    virtual void setHdrMode(bool enabled) override;
    virtual bool notifyWindowChanged(PWINDOW_STATE_CHANGE_INFO info) override;
    
private:
    VideoDecoderRenderer* m_Renderer;
    AVFView* m_StreamView;
};
#endif
class AVFRendererFactory {
public:
    static IVideoDecoder* createDecoder();
};
