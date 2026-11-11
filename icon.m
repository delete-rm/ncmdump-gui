#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) { @autoreleasepool {
    int S = 1024;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:S pixelsHigh:S bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];

    NSRect full = NSMakeRect(0, 0, S, S);
    [[NSColor clearColor] setFill];
    NSRectFill(full);

    // rounded square with vertical gradient
    NSRect body = NSInsetRect(full, S * 0.06, S * 0.06);
    NSBezierPath *rounded = [NSBezierPath bezierPathWithRoundedRect:body xRadius:S * 0.22 yRadius:S * 0.22];
    [rounded addClip];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.36 green:0.36 blue:0.92 alpha:1.0]
                                                  endingColor:[NSColor colorWithCalibratedRed:0.69 green:0.29 blue:0.87 alpha:1.0]];
    [g drawInRect:body angle:-70];

    NSImage *sym = [NSImage imageWithSystemSymbolName:@"music.note.list" accessibilityDescription:nil];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:S * 0.5 weight:NSFontWeightSemibold];
    sym = [sym imageWithSymbolConfiguration:cfg];
    NSSize sz = sym.size;
    CGFloat scale = (S * 0.52) / MAX(sz.width, sz.height);
    NSRect target = NSMakeRect((S - sz.width * scale) / 2, (S - sz.height * scale) / 2,
                               sz.width * scale, sz.height * scale);

    NSImage *white = [NSImage imageWithSize:target.size flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSColor whiteColor] set];
        NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
        [sym drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationDestinationIn fraction:1.0];
        return YES;
    }];
    [white drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];

    [NSGraphicsContext restoreGraphicsState];

    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *out = (argc > 1) ? [NSString stringWithUTF8String:argv[1]] : @"icon_1024.png";
    [png writeToFile:out atomically:YES];
    NSLog(@"wrote %lu bytes", (unsigned long)png.length);
    return 0;
}}
