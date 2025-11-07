//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//
#ifdef __OBJC__
#include "Limelight.h"
#import <AppKit/AppKit.h>

@interface VideoDecoderRenderer : NSObject

- (id)initWithView:(NSView*)view streamAspectRatio:(float)aspectRatio useFramePacing:(BOOL)useFramePacing;

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)start;
- (void)stop;
- (void)setHdrMode:(BOOL)enabled;
- (int) DrSubmitDecodeUnit: (PDECODE_UNIT)decodeUnit;
- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du;
- (void)decodeThreadMain;

@end
#endif
