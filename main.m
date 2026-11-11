#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kAppTitle = @"ncmdump · NCM 转换";
static NSString *const kDefaultsDeleteSource = @"deleteSource";
static NSString *const kDefaultsOutputDir = @"outputDir";
static NSString *const kDefaultsRetries = @"maxRetries";

#pragma mark - Helpers

static NSString *StripANSI(NSString *s) {
    if (s.length == 0) return @"";
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\x1B\\[[0-9;]*[A-Za-z]"
                                                                      options:0 error:nil];
    if (re) s = [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *FindProducedFile(NSString *dir, NSString *stem, NSDate *since) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *f in items) {
        if ([[f pathExtension].lowercaseString isEqualToString:@"ncm"]) continue;
        if (![[f stringByDeletingPathExtension] isEqualToString:stem]) continue;
        NSString *full = [dir stringByAppendingPathComponent:f];
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        NSDate *mtime = attrs[NSFileModificationDate];
        if (!mtime || [mtime compare:since] != NSOrderedAscending) return full;
    }
    return nil;
}

#pragma mark - Job

@interface Job : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *baseDir;   // 拖入目录时的根，用于保留子目录结构
@property (nonatomic, assign) NSInteger attempts;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL failed;
@end

@implementation Job
@end

#pragma mark - DropView

@protocol DropViewDelegate <NSObject>
- (void)dropViewDidReceiveURLs:(NSArray<NSURL *> *)urls;
- (void)dropViewWasClicked;
@end

@interface DropView : NSView
@property (nonatomic, weak) id<DropViewDelegate> delegate;
@property (nonatomic, assign) BOOL highlighted;
@property (nonatomic, copy) NSString *note;
@end

@implementation DropView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setHighlighted:(BOOL)highlighted {
    if (_highlighted == highlighted) return;
    _highlighted = highlighted;
    [self setNeedsDisplay:YES];
}

- (void)setNote:(NSString *)note {
    _note = [note copy];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = NSInsetRect(self.bounds, 1.5, 1.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:12 yRadius:12];

    NSColor *fill = self.highlighted
        ? [[NSColor controlAccentColor] colorWithAlphaComponent:0.10]
        : [NSColor textBackgroundColor];
    [fill setFill];
    [path fill];

    CGFloat dash[2] = { 6.0, 4.0 };
    [path setLineDash:dash count:2 phase:0];
    path.lineWidth = 1.5;
    NSColor *stroke = self.highlighted
        ? [NSColor controlAccentColor]
        : [[NSColor secondaryLabelColor] colorWithAlphaComponent:0.55];
    [stroke setStroke];
    [path stroke];

    NSString *symbol = self.highlighted ? @"⬇︎" : @"♫";
    NSDictionary *symbolAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:28 weight:NSFontWeightLight],
        NSForegroundColorAttributeName: self.highlighted ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor]
    };
    NSSize symbolSize = [symbol sizeWithAttributes:symbolAttrs];
    [symbol drawAtPoint:NSMakePoint(NSMidX(self.bounds) - symbolSize.width / 2, 18) withAttributes:symbolAttrs];

    NSString *title = @"把 .ncm 文件或文件夹拖到这里";
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };
    NSSize titleSize = [title sizeWithAttributes:titleAttrs];
    [title drawAtPoint:NSMakePoint(NSMidX(self.bounds) - titleSize.width / 2, 60) withAttributes:titleAttrs];

    NSString *sub = self.note.length ? self.note : @"点这里选择文件 · 转换在后台顺序进行";
    NSDictionary *subAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
    };
    NSSize subSize = [sub sizeWithAttributes:subAttrs];
    [sub drawAtPoint:NSMakePoint(NSMidX(self.bounds) - subSize.width / 2, 82) withAttributes:subAttrs];
}

- (void)mouseDown:(NSEvent *)event {
    [self.delegate dropViewWasClicked];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    self.highlighted = YES;
    return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    self.highlighted = NO;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.highlighted = NO;
    NSPasteboard *pb = sender.draggingPasteboard;
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[ [NSURL class] ]
                                              options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    if (urls.count == 0) return NO;
    [self.delegate dropViewDidReceiveURLs:urls];
    return YES;
}

@end

#pragma mark - Controller

@interface Controller : NSObject <DropViewDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) DropView *dropView;
@property (nonatomic, strong) NSTextView *logView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *pathLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSButton *deleteCheck;
@property (nonatomic, strong) NSButton *outputCheck;
@property (nonatomic, strong) NSButton *retryButton;
@property (nonatomic, strong) NSButton *clearButton;
@property (nonatomic, copy) NSString *currentName;
@property (nonatomic, assign) BOOL notified;
@property (nonatomic, strong) NSStepper *retryStepper;
@property (nonatomic, strong) NSTextField *retryLabel;

@property (nonatomic, strong) NSMutableArray<Job *> *pending;
@property (nonatomic, strong) NSMutableArray<Job *> *failedJobs;
@property (nonatomic, strong) NSMutableSet<NSString *> *known;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) NSInteger totalCount;
@property (nonatomic, assign) NSInteger finishedCount;
@end

@implementation Controller

- (instancetype)init {
    self = [super init];
    if (self) {
        _pending = [NSMutableArray array];
        _failedJobs = [NSMutableArray array];
        _known = [NSMutableSet set];
        [self buildUI];
        [self restoreSettings];
    }
    return self;
}

#pragma mark Settings

- (BOOL)deleteSource {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultsDeleteSource];
}

- (NSString *)outputDir {
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:kDefaultsOutputDir];
    return p.length ? p : nil;
}

- (NSInteger)maxRetries {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultsRetries];
}

- (void)restoreSettings {
    self.deleteCheck.state = [self deleteSource] ? NSControlStateValueOn : NSControlStateValueOff;
    self.outputCheck.state = [self outputDir] ? NSControlStateValueOn : NSControlStateValueOff;
    self.retryStepper.integerValue = [self maxRetries];
    [self refreshSettingsUI];
}

- (void)refreshSettingsUI {
    self.deleteCheck.state = [self deleteSource] ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *dir = [self outputDir];
    self.outputCheck.state = dir ? NSControlStateValueOn : NSControlStateValueOff;
    self.pathLabel.stringValue = dir ? [dir stringByAbbreviatingWithTildeInPath] : @"输出到源文件所在文件夹";
    self.pathLabel.textColor = dir ? [NSColor labelColor] : [NSColor secondaryLabelColor];
    self.retryLabel.stringValue = [NSString stringWithFormat:@"失败自动重试 %ld 次", (long)[self maxRetries]];
    self.retryButton.enabled = self.failedJobs.count > 0;
    [self.retryButton setTitle:self.failedJobs.count > 0
        ? [NSString stringWithFormat:@"重试失败 (%lu)", (unsigned long)self.failedJobs.count]
        : @"重试失败"];
}

#pragma mark UI

- (void)buildUI {
    CGFloat H = 620;
    NSRect frame = NSMakeRect(0, 0, 620, H);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:style
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.title = kAppTitle;
    self.window.minSize = NSMakeSize(620, H);
    [self.window center];
    [self.window setFrameAutosaveName:@"NCMWindowFrame"];

    NSView *content = self.window.contentView;

    // Drop area (top)
    self.dropView = [[DropView alloc] initWithFrame:NSMakeRect(16, H - 16 - 104, 588, 104)];
    self.dropView.delegate = self;
    self.dropView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.dropView];

    // Log
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 108, 588, H - 140 - 108)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.logView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.drawsBackground = YES;
    self.logView.backgroundColor = [NSColor textBackgroundColor];
    self.logView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.logView.textContainerInset = NSMakeSize(8, 8);
    self.logView.verticallyResizable = YES;
    self.logView.autoresizingMask = NSViewWidthSizable;
    self.logView.textContainer.widthTracksTextView = YES;
    scroll.documentView = self.logView;
    [content addSubview:scroll];

    // Options row
    self.deleteCheck = [NSButton checkboxWithTitle:@"转换后删除源文件" target:self action:@selector(deleteToggled:)];
    self.deleteCheck.frame = NSMakeRect(16, 74, 170, 20);
    self.deleteCheck.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:self.deleteCheck];

    self.outputCheck = [NSButton checkboxWithTitle:@"输出到" target:self action:@selector(outputToggled:)];
    self.outputCheck.frame = NSMakeRect(196, 74, 76, 20);
    self.outputCheck.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:self.outputCheck];

    NSButton *chooseOut = [NSButton buttonWithTitle:@"选择…" target:self action:@selector(chooseOutputDir:)];
    chooseOut.frame = NSMakeRect(272, 70, 70, 26);
    chooseOut.bezelStyle = NSBezelStyleRounded;
    chooseOut.controlSize = NSControlSizeSmall;
    chooseOut.font = [NSFont systemFontOfSize:11];
    chooseOut.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:chooseOut];

    self.pathLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(348, 74, 256, 18)];
    self.pathLabel.editable = NO;
    self.pathLabel.bordered = NO;
    self.pathLabel.drawsBackground = NO;
    self.pathLabel.font = [NSFont systemFontOfSize:11];
    self.pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.pathLabel.autoresizingMask = NSViewMinXMargin | NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:self.pathLabel];

    // Actions row
    NSButton *pick = [NSButton buttonWithTitle:@"选择文件…" target:self action:@selector(pickFiles:)];
    pick.frame = NSMakeRect(16, 32, 100, 26);
    pick.bezelStyle = NSBezelStyleRounded;
    pick.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:pick];

    self.retryButton = [NSButton buttonWithTitle:@"重试失败" target:self action:@selector(retryFailed:)];
    self.retryButton.frame = NSMakeRect(122, 32, 108, 26);
    self.retryButton.bezelStyle = NSBezelStyleRounded;
    self.retryButton.enabled = NO;
    self.retryButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:self.retryButton];

    self.clearButton = [NSButton buttonWithTitle:@"清空" target:self action:@selector(clearLog:)];
    self.clearButton.frame = NSMakeRect(236, 32, 60, 26);
    self.clearButton.bezelStyle = NSBezelStyleRounded;
    self.clearButton.enabled = NO;
    self.clearButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:self.clearButton];

    self.retryLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(306, 36, 130, 18)];
    self.retryLabel.editable = NO;
    self.retryLabel.bordered = NO;
    self.retryLabel.drawsBackground = NO;
    self.retryLabel.font = [NSFont systemFontOfSize:11];
    self.retryLabel.textColor = [NSColor secondaryLabelColor];
    self.retryLabel.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:self.retryLabel];

    self.retryStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(440, 32, 16, 26)];
    self.retryStepper.minValue = 0;
    self.retryStepper.maxValue = 5;
    self.retryStepper.increment = 1;
    self.retryStepper.valueWraps = NO;
    self.retryStepper.target = self;
    self.retryStepper.action = @selector(retriesChanged:);
    self.retryStepper.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:self.retryStepper];

    // Progress bar
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(466, 38, 138, 12)];
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0;
    self.progressBar.maxValue = 1;
    self.progressBar.doubleValue = 0;
    self.progressBar.autoresizingMask = NSViewMinXMargin | NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:self.progressBar];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(590, 36, 14, 14)];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    self.spinner.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:self.spinner];

    // Status row
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 10, 588, 16)];
    self.statusLabel.editable = NO;
    self.statusLabel.bordered = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.alignment = NSTextAlignmentLeft;
    self.statusLabel.font = [NSFont systemFontOfSize:10];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.stringValue = @"就绪";
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:self.statusLabel];

    [self appendLog:@"提示：把 .ncm 拖到上面的虚线框，或在 Finder 里右键 →「打开方式」→ ncmdump\n"
               color:[NSColor secondaryLabelColor]];
}

- (void)writeToLogFile:(NSString *)text {
    static NSString *path = nil;
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        path = [dir stringByAppendingPathComponent:@"ncmdump-gui.log"];
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });

    NSString *clean = [text stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    if (clean.length == 0) return;
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], clean];

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attrs fileSize] > 4 * 1024 * 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

- (void)appendLog:(NSString *)text color:(NSColor *)color {
    NSAttributedString *s = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: color ?: [NSColor labelColor]
    }];
    [[self.logView textStorage] appendAttributedString:s];
    [self.logView scrollToEndOfDocument:nil];
    [self writeToLogFile:text];
}

#pragma mark Actions

- (void)deleteToggled:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn)
                                           forKey:kDefaultsDeleteSource];
    [self refreshSettingsUI];
}

- (void)outputToggled:(NSButton *)sender {
    if (sender.state == NSControlStateValueOn) {
        [self chooseOutputDir:nil];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kDefaultsOutputDir];
        [self refreshSettingsUI];
    }
}

- (void)chooseOutputDir:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.message = @"选择转换后文件的输出文件夹";
    panel.prompt = @"使用此文件夹";
    if ([panel runModal] == NSModalResponseOK && panel.URL.path) {
        [[NSUserDefaults standardUserDefaults] setObject:panel.URL.path forKey:kDefaultsOutputDir];
        [self refreshSettingsUI];
        return;
    }
    // cancelled: fall back to whatever is stored
    [self refreshSettingsUI];
}

- (void)retriesChanged:(NSStepper *)sender {
    [[NSUserDefaults standardUserDefaults] setInteger:sender.integerValue forKey:kDefaultsRetries];
    [self refreshSettingsUI];
}

- (void)retryFailed:(id)sender {
    if (self.failedJobs.count == 0) return;
    NSArray<Job *> *retry = [self.failedJobs copy];
    [self.failedJobs removeAllObjects];
    for (Job *j in retry) {
        j.attempts = 0;
        j.finished = NO;
        j.failed = NO;
        self.finishedCount--;
        [self.pending insertObject:j atIndex:0];
    }
    [self appendLog:[NSString stringWithFormat:@"重新排队 %lu 个失败任务\n", (unsigned long)retry.count]
               color:[NSColor systemOrangeColor]];
    [self refreshSettingsUI];
    [self updateStatus];
    [self pump];
}

- (void)pickFiles:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = YES;
    panel.message = @"选择 .ncm 文件或包含 ncm 的文件夹";
    panel.prompt = @"加入队列";
    UTType *ncmType = [UTType typeWithFilenameExtension:@"ncm"];
    if (ncmType) {
        panel.allowedContentTypes = @[ ncmType ];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        panel.allowedFileTypes = @[ @"ncm" ];
#pragma clang diagnostic pop
    }
    if ([panel runModal] == NSModalResponseOK) {
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSURL *u in panel.URLs) {
            if (u.path) [paths addObject:u.path];
        }
        [self addPaths:paths];
    }
}

- (void)clearLog:(id)sender {
    if (self.busy) { NSBeep(); return; }
    [[self.logView textStorage] setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
    [self.known removeAllObjects];
    [self.failedJobs removeAllObjects];
    self.totalCount = 0;
    self.finishedCount = 0;
    self.progressBar.doubleValue = 0;
    [self refreshSettingsUI];
    [self updateStatus];
}

#pragma mark Queue

- (void)addPaths:(NSArray<NSString *> *)paths {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *newItems = [NSMutableArray array];

    NSMutableDictionary<NSString *, NSString *> *baseOf = [NSMutableDictionary dictionary];
    NSInteger skipped = 0;

    for (NSString *p in paths) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir]) continue;

        if (isDir) {
            NSDirectoryEnumerator *e = [fm enumeratorAtPath:p];
            for (NSString *rel in e) {
                if ([[rel pathExtension].lowercaseString isEqualToString:@"ncm"]) {
                    NSString *full = [p stringByAppendingPathComponent:rel];
                    [newItems addObject:full];
                    baseOf[full] = p;          // 记住所属根目录
                } else {
                    BOOL isSub = NO;
                    NSString *full = [p stringByAppendingPathComponent:rel];
                    if ([fm fileExistsAtPath:full isDirectory:&isSub] && !isSub) skipped++;
                }
            }
        } else if ([[p pathExtension].lowercaseString isEqualToString:@"ncm"]) {
            [newItems addObject:p];
        } else {
            skipped++;
        }
    }

    NSInteger added = 0;
    for (NSString *p in [newItems sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if ([self.known containsObject:p]) continue;
        [self.known addObject:p];
        Job *job = [Job new];
        job.path = p;
        job.baseDir = baseOf[p];
        [self.pending addObject:job];
        added++;
    }

    if (added == 0) {
        if (newItems.count == 0) {
            NSBeep();
            if (skipped > 0) {
                [self appendLog:[NSString stringWithFormat:@"没有找到 .ncm 文件（已跳过 %ld 个其它文件）\n", (long)skipped]
                          color:[NSColor systemOrangeColor]];
            } else {
                [self appendLog:@"没有找到 .ncm 文件（只支持网易云下载的 .ncm）\n" color:[NSColor systemRedColor]];
            }
        }
        return;
    }

    self.totalCount += added;
    self.notified = NO;
    [self appendLog:[NSString stringWithFormat:@"加入 %ld 个任务\n", (long)added] color:[NSColor secondaryLabelColor]];
    [self updateStatus];
    [self pump];
}

- (void)pump {
    if (self.busy || self.pending.count == 0) {
        [self updateStatus];
        return;
    }

    self.busy = YES;
    [self.spinner startAnimation:nil];

    Job *job = self.pending.firstObject;
    [self.pending removeObjectAtIndex:0];
    job.attempts += 1;

    NSString *path = job.path;
    NSString *name = path.lastPathComponent;
    NSString *sourceDir = [path stringByDeletingLastPathComponent];
    NSString *outDir = [self outputDir];
    self.currentName = name;

    // 指定输出目录时，按拖入时的根目录保留子目录结构，避免同名文件互相覆盖
    NSString *targetDir = outDir ? outDir : sourceDir;
    if (outDir && job.baseDir.length > 0 && path.length > job.baseDir.length) {
        NSString *rel = [path substringFromIndex:job.baseDir.length];
        while ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
        NSString *sub = [rel stringByDeletingLastPathComponent];
        if (sub.length > 0) {
            targetDir = [outDir stringByAppendingPathComponent:sub];
        }
    }

    if (job.attempts > 1) {
        [self appendLog:[NSString stringWithFormat:@"↻ 重试 %ld/%ld %@\n", (long)(job.attempts - 1),
                                                   (long)[self maxRetries], name]
                   color:[NSColor systemOrangeColor]];
    } else {
        [self appendLog:[NSString stringWithFormat:@"→ %@\n", name] color:[NSColor labelColor]];
    }

    if (outDir) {
        [[NSFileManager defaultManager] createDirectoryAtPath:targetDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }

    NSURL *bin = [[NSBundle mainBundle] URLForResource:@"ncmdump" withExtension:nil];
    BOOL removeSource = [self deleteSource];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;

        NSString *output = @"";
        int status = -1;
        NSString *produced = nil;
        NSDate *startedAt = [NSDate dateWithTimeIntervalSinceNow:-2.0];

        NSString *stem = [path.lastPathComponent stringByDeletingPathExtension];

        if (!bin) {
            output = @"应用包内缺少 ncmdump 可执行文件";
        } else {
            task.executableURL = bin;
            NSMutableArray *args = [NSMutableArray arrayWithObject:path];
            if (outDir) {
                [args addObjectsFromArray:@[ @"-o", targetDir ]];
            }
            task.arguments = args;

            NSError *err = nil;
            if ([task launchAndReturnError:&err]) {
                NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
                [task waitUntilExit];
                status = task.terminationStatus;
                output = StripANSI([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                if (status == 0) {
                    produced = FindProducedFile(targetDir, stem, startedAt);
                }
            } else {
                output = [NSString stringWithFormat:@"无法启动: %@", err.localizedDescription];
            }
        }

        BOOL ok = (status == 0 && produced.length > 0);

        BOOL deleted = NO;
        if (ok && removeSource) {
            deleted = [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            Controller *me = weakSelf;
            if (!me) return;

            if (ok) {
                NSString *shown = [NSString stringWithFormat:@"输出 %@", produced.lastPathComponent];
                if (deleted) {
                    shown = [shown stringByAppendingString:@"（已删除源文件）"];
                } else if (removeSource) {
                    shown = [shown stringByAppendingString:@"（源文件删除失败）"];
                }
                [me appendLog:[NSString stringWithFormat:@"  ✓ %@\n", shown] color:[NSColor systemGreenColor]];
                job.finished = YES;
                me.finishedCount++;
            } else {
                NSInteger maxRetries = [me maxRetries];
                NSString *shown = output.length ? output : [NSString stringWithFormat:@"退出码 %d", status];
                if (status == 0 && produced.length == 0) {
                    shown = output.length ? [NSString stringWithFormat:@"转换失败：%@", output]
                                          : @"转换失败：未生成输出文件";
                }
                if (shown.length > 160) shown = [NSString stringWithFormat:@"%@…", [shown substringToIndex:160]];
                if ([shown containsString:@"Not netease protected file"]) {
                    shown = @"不是有效的 ncm 文件（可能已损坏，或不是网易云下载的）";
                } else if ([shown containsString:@"missing album"]) {
                    shown = @"转换成功，但缺少专辑信息，封面图未写入";
                }

                if (job.attempts - 1 < maxRetries) {
                    [me appendLog:[NSString stringWithFormat:@"  ! 失败，将自动重试：%@\n", shown]
                           color:[NSColor systemOrangeColor]];
                    [me.pending insertObject:job atIndex:0];
                } else {
                    [me appendLog:[NSString stringWithFormat:@"  ✗ %@\n", shown] color:[NSColor systemRedColor]];
                    job.finished = YES;
                    job.failed = YES;
                    me.finishedCount++;
                    [me.failedJobs addObject:job];
                    [me refreshSettingsUI];
                }
            }

            me.busy = NO;
            [me.spinner stopAnimation:nil];
            [me updateStatus];
            [me pump];
        });
    });
}

- (void)updateStatus {
    NSInteger queued = self.pending.count + (self.busy ? 1 : 0);

    if (self.totalCount > 0) {
        self.progressBar.doubleValue = (double)self.finishedCount / (double)self.totalCount;
    } else {
        self.progressBar.doubleValue = 0;
    }

    if (self.totalCount == 0) {
        self.statusLabel.stringValue = @"就绪";
        self.dropView.note = nil;
        self.clearButton.enabled = NO;
        self.currentName = nil;
        return;
    }

    NSInteger failed = (NSInteger)self.failedJobs.count;
    NSInteger ok = self.finishedCount - failed;

    NSMutableArray *bits = [NSMutableArray array];
    if (self.busy && self.currentName.length > 0) {
        [bits addObject:[NSString stringWithFormat:@"转换中 %@", self.currentName]];
    }
    [bits addObject:[NSString stringWithFormat:@"%ld/%ld", (long)self.finishedCount, (long)self.totalCount]];
    if (ok > 0) [bits addObject:[NSString stringWithFormat:@"成功 %ld", (long)ok]];
    if (failed > 0) [bits addObject:[NSString stringWithFormat:@"失败 %ld", (long)failed]];
    if (queued > 0) [bits addObject:[NSString stringWithFormat:@"队列 %ld", (long)queued]];

    self.statusLabel.stringValue = [bits componentsJoinedByString:@" · "];
    self.dropView.note = queued > 0
        ? [NSString stringWithFormat:@"正在处理，队列还有 %ld 个", (long)queued]
        : @"点这里选择文件 · 转换在后台顺序进行";

    self.clearButton.enabled = !self.busy;

    // 整批完成时提醒一下（窗口在后台时弹 Dock）
    if (!self.busy && queued == 0 && self.totalCount > 0 &&
        self.finishedCount >= self.totalCount && !self.notified) {
        self.notified = YES;
        self.currentName = nil;
        if (self.totalCount > 1) {
            if (![NSApp isActive]) {
                [NSApp requestUserAttention:NSInformationalRequest];
            }
            [[NSSound soundNamed:@"Glass"] play];
        }
    }
}

#pragma mark DropViewDelegate

- (void)dropViewDidReceiveURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *u in urls) {
        if (u.path) [paths addObject:u.path];
    }
    [self addPaths:paths];
}

- (void)dropViewWasClicked {
    [self pickFiles:nil];
}

@end

#pragma mark - App Delegate

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) Controller *controller;
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingPaths;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.controller = [Controller new];
    [self.controller.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (self.pendingPaths.count > 0) {
        NSArray<NSString *> *paths = [self.pendingPaths copy];
        [self.pendingPaths removeAllObjects];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.controller addPaths:paths];
        });
    }
}

- (NSMutableArray<NSString *> *)pendingPaths {
    if (!_pendingPaths) _pendingPaths = [NSMutableArray array];
    return _pendingPaths;
}

- (void)application:(NSApplication *)application openFiles:(NSArray<NSString *> *)filenames {
    if (self.controller) {
        [self.controller addPaths:filenames];
    } else {
        [self.pendingPaths addObjectsFromArray:filenames];
    }
    [application replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
