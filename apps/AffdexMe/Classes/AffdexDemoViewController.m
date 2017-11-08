//
//  AffdexDemoViewController.m
//
//  Created by Affectiva on 2/22/13.
//  Copyright (c) 2016 Affectiva Inc.
//
//  See the file license.txt for copying permission.

// If this feature is turned on, then emotions and expressions will be sent via UDP
#undef BROADCAST_VIA_UDP
#ifdef BROADCAST_VIA_UDP
#define MULTICAST_GROUP @"224.0.1.1"
#define MULTICAST_PORT 12345
#endif

// Please note: Affectiva licensing strings are no longer required to use the SDK.

// If this is being compiled for the iOS simulator, a demo mode is used since the camera isn't supported.
#if TARGET_IPHONE_SIMULATOR
#define DEMO_MODE
#endif

#import "UIDeviceHardware.h"
#import "AffdexDemoViewController.h"
#ifdef BROADCAST_VIA_UDP
#import "GCDAsyncUdpSocket.h"
#endif
#import <CoreMotion/CoreMotion.h>
#import "EmotionPickerViewController.h"

@interface UIImage (test)

+ (UIImage *)imageFromText:(NSString *)text size:(CGFloat)size;
+ (UIImage *)imageFromView:(UIView *)view;

@end

@implementation UIImage (test)

+ (UIImage *)imageFromText:(NSString *)text size:(CGFloat)size;
{
    // set the font type and size
    UIFont *font = [UIFont systemFontOfSize:size];
    CGSize imageSize  = [text sizeWithAttributes:@{ NSFontAttributeName : font }];

    // check if UIGraphicsBeginImageContextWithOptions is available (iOS is 4.0+)
    UIGraphicsBeginImageContextWithOptions(imageSize, NO, 0.0);

    // optional: add a shadow, to avoid clipping the shadow you should make the context size bigger
    //
    // CGContextRef ctx = UIGraphicsGetCurrentContext();
    // CGContextSetShadowWithColor(ctx, CGSizeMake(1.0, 1.0), 5.0, [[UIColor grayColor] CGColor]);

    // draw in context, you can use also drawInRect:withFont:
    [text drawAtPoint:CGPointMake(0.0, 0.0) withAttributes:@{ NSFontAttributeName : font }];

    // transfer image
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return image;
}

+ (UIImage *)imageFromView:(UIView *)view withSize:(CGSize)size;
{
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
    UIImage *snapshotImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshotImage;
}

+ (UIImage *)imageFromView:(UIView *)view
{
    return [UIImage imageFromView:view withSize:view.bounds.size];
}

- (UIImage *)drawImages:(NSArray *)inputImages inRects:(NSArray *)frames;
{
    UIGraphicsBeginImageContextWithOptions(self.size, NO, 0.0);
    [self drawInRect:CGRectMake(0.0, 0.0, self.size.width, self.size.height)];
    NSUInteger inputImagesCount = [inputImages count];
    NSUInteger framesCount = [frames count];
    if (inputImagesCount == framesCount) {
        for (int i = 0; i < inputImagesCount; i++) {
            UIImage *inputImage = [inputImages objectAtIndex:i];
            CGRect frame = [[frames objectAtIndex:i] CGRectValue];
            [inputImage drawInRect:frame];
        }
    }
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

@end

@interface AffdexDemoViewController ()

@property (strong) NSDate *dateOfLastFrame;
@property (strong) NSDate *dateOfLastProcessedFrame;
@property (strong) NSDictionary *entries;
@property (strong) NSEnumerator *entryEnumerator;
@property (strong) NSDictionary *jsonEntry;
@property (strong) NSDictionary *videoEntry;
@property (strong) NSString *jsonFilename;
@property (strong) NSString *mediaFilename;

@property (strong) NSMutableArray *facePointsToDraw;
@property (strong) NSMutableArray *faceRectsToDraw;

@property (strong) NSMutableArray *expressionViewControllers_compact;
@property (strong) NSMutableArray *expressionViewControllers_regular;
@property (strong) NSMutableArray *classifierViews_compact;
@property (strong) NSMutableArray *classifierViews_regular;

#ifdef BROADCAST_VIA_UDP
@property (strong) GCDAsyncUdpSocket *udpSocket;
#endif

@property (strong) NSArray *availableClassifiers; // the array of dictionaries which contain all available classifiers
@property (strong) NSArray *emotions;   // the array of dictionaries of all emotion classifiers
@property (strong) NSArray *expressions; // the array of dictionaries of all expression classifiers
@property (strong) NSArray *emojis; // the array of dictionaries of all emoji classifiers

@property (strong) CMMotionManager *motionManager;

@property (strong) UIImage *maleImage;
@property (strong) UIImage *femaleImage;
@property (strong) UIImage *unknownImage;
@property (strong) UIImage *maleImageWithGlasses;
@property (strong) UIImage *femaleImageWithGlasses;
@property (strong) UIImage *unknownImageWithGlasses;
@property (assign) CGRect genderRect;
@property (assign) AFDXCameraType cameraToUse;

@property (strong) NSArray *faces;

@property (assign) BOOL multifaceMode;
@property (strong) ExpressionViewController *dominantEmotionOrExpression;

@end

@implementation AffdexDemoViewController

#pragma mark -
#pragma mark AFDXDetectorDelegate Methods

#ifdef DEMO_MODE
- (void)detectorDidFinishProcessing:(AFDXDetector *)detector;
{
    [self stopDetector];
}
#endif

// In single face mode, we turn on only the selected classifiers
- (void)enterSingleFaceMode;
{
    self.multifaceMode = FALSE;

    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:0.5];
    self.classifierHeaderView_compact.alpha = 1.0;
    self.classifierHeaderView_regular.alpha = 1.0;
    [UIView commitAnimations];
}

- (void)enterMultiFaceMode;
{
    self.multifaceMode = TRUE;

    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:0.5];
    self.classifierHeaderView_compact.alpha = 0.0;
    self.classifierHeaderView_regular.alpha = 0.0;
    [UIView commitAnimations];
}

- (void)processedImageReady:(AFDXDetector *)detector image:(UIImage *)image faces:(NSDictionary *)faces atTime:(NSTimeInterval)time;
{
    self.faces = [faces allValues];
    // determine single or multi face mode
    if (self.faces.count > 1 && self.multifaceMode == FALSE) {
        // multi face mode
        [self enterMultiFaceMode];
    } else if (self.faces.count == 1 && self.multifaceMode == TRUE) {
        // single face mode
        [self enterSingleFaceMode];
    }

    NSDate *now = [NSDate date];

    if (nil != self.dateOfLastProcessedFrame)
    {
        NSTimeInterval interval = [now timeIntervalSinceDate:self.dateOfLastProcessedFrame];

        if (interval > 0)
        {
            float fps = 1.0 / interval;
            self.fpsProcessed.text = [NSString stringWithFormat:@"FPS(P): %.1f", fps];
        }
    }

    self.dateOfLastProcessedFrame = now;

    // set up arrays of points and rects
    self.facePointsToDraw = [NSMutableArray new];
    self.faceRectsToDraw = [NSMutableArray new];

    // Handle each metric in the array
    for (AFDXFace *face in [faces allValues])
    {
        NSDictionary *faceData = face.userInfo;
        NSArray *compactExpressionViewControllers = [faceData objectForKey:@"compactExpressionViewControllers"];
        NSArray *regularExpressionViewControllers = [faceData objectForKey:@"regularExpressionViewControllers"];

        [self.facePointsToDraw addObjectsFromArray:face.facePoints];
        [self.faceRectsToDraw addObject:[NSValue valueWithCGRect:face.faceBounds]];

        // get dominant emoji
        [face.userInfo setObject:[NSNumber numberWithInt:face.emojis.dominantEmoji] forKey:@"dominantEmoji"];

        for (NSArray *classifierArray in self.availableClassifiers)  // e.g. [ emotions, expressions ]
        {
            for (NSDictionary *classifierDict in classifierArray)    // array of selected classifier.
            {
                for (NSInteger classifierIndex = 0; classifierIndex<[self.selectedClassifiers count]; classifierIndex++)
                {
                    NSString *classifierName = [self.selectedClassifiers objectAtIndex:classifierIndex];
                    if ([[classifierDict objectForKey:@"name"] isEqualToString:classifierName])
                    {
                        NSString *scoreName = [classifierDict objectForKey:@"score"];
                        __block float classifierScore = [[face valueForKeyPath:scoreName] floatValue];

                        for (ExpressionViewController *v in compactExpressionViewControllers)
                        {
                            if ([v.name isEqualToString:classifierName])
                            {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    v.metric = classifierScore;
                                });
                            }
                        }

                        for (ExpressionViewController *v in regularExpressionViewControllers)
                        {
                            if ([v.name isEqualToString:classifierName])
                            {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    v.metric = classifierScore;
                                });
                            }
                        }
                    }
                }
            }

#ifdef BROADCAST_VIA_UDP
            char buffer[7];
            for (NSUInteger i = 0; i < [self.availableClassifiers count]; i++)
            {
                NSDictionary *entry = [self.availableClassifiers objectAtIndex:i];
                NSString *scoreName = [entry objectForKey:@"score"];
                CGFloat score = [[face valueForKey:scoreName] floatValue];
                buffer[i] = (char)(isnan(score) ? 0 : score);
            }
            NSData *d = [NSData dataWithBytes:buffer length:sizeof(buffer)];
            [self.udpSocket sendData:d toHost:MULTICAST_GROUP port:MULTICAST_PORT withTimeout:-1 tag:0];
#endif
        }
    }
}

- (void)unprocessedImageReady:(AFDXDetector *)detector image:(UIImage *)image atTime:(NSTimeInterval)time;
{
    __block AffdexDemoViewController *weakSelf = self;
    __block UIImage *newImage = image;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (AFDXFace *face in self.faces) {
            UIImage *genderImage = nil;
            switch (face.appearance.gender) {
                case AFDX_GENDER_MALE:
                    genderImage = self.maleImage;
                    if (face.appearance.glasses == AFDX_GLASSES_YES) {
                        genderImage = self.maleImageWithGlasses;
                    }
                    break;
                case AFDX_GENDER_FEMALE:
                    genderImage = self.femaleImage;
                    if (face.appearance.glasses == AFDX_GLASSES_YES) {
                        genderImage = self.femaleImageWithGlasses;
                    }
                    break;
                case AFDX_GENDER_UNKNOWN:
                    genderImage = self.unknownImage;
                    if (face.appearance.glasses == AFDX_GLASSES_YES) {
                        genderImage = self.unknownImageWithGlasses;
                    }
                    break;
            }

            // create array of images and rects to do all drawing at once
            NSMutableArray *imagesArray = [NSMutableArray array];
            NSMutableArray *rectsArray = [NSMutableArray array];

            CGRect faceBounds = face.faceBounds;

            // add dominant emoji
            if (weakSelf.drawEmojis) {
                Emoji dominantEmoji = [[face.userInfo objectForKey:@"dominantEmoji"] intValue];
                if (dominantEmoji != AFDX_EMOJI_NONE) {
                    for (NSDictionary *emojiDictionary in self.emojis) {
                        NSNumber *code = [emojiDictionary objectForKey:@"code"];
                        if (dominantEmoji == [code intValue]) {
                            // match!
                            UIImage *emojiImage = [emojiDictionary objectForKey:@"image"];
                            if (nil != emojiImage) {
                                // resize bounds to be relative in size to bounding box
                                CGSize size = emojiImage.size;
                                CGFloat aspectRatio = size.height / size.width;
                                size.width = faceBounds.size.height * .25;
                                size.height = size.width * aspectRatio;

                                CGRect rect = CGRectMake(faceBounds.origin.x - (size.width/2),
                                                         faceBounds.origin.y,
                                                         size.width,
                                                         size.height);
                                [imagesArray addObject:emojiImage];
                                [rectsArray addObject:[NSValue valueWithCGRect:rect]];
                                break;
                            }
                        }
                    }
                }
            }

            if (weakSelf.drawAppearanceIcons) {
                // add gender image
                if (genderImage != nil) {
                    // resize bounds to be relative in size to bounding box
                    CGSize size = genderImage.size;
                    CGFloat aspectRatio = size.height / size.width;
                    size.width = faceBounds.size.height * .25;
                    size.height = size.width * aspectRatio;

                    CGRect rect = CGRectMake(faceBounds.origin.x - (size.width/2), faceBounds.origin.y + (faceBounds.size.height) - size.height, size.width, size.height);
                    [imagesArray addObject:genderImage];
                    [rectsArray addObject:[NSValue valueWithCGRect:rect]];
                }

                // add dominant emotion/expression
                if (self.multifaceMode == TRUE) {
                    CGFloat dominantScore = -9999;
                    NSString *dominantName = @"NONAME";

                    for (NSDictionary *d in self.emotions) {
                        NSString *name = [d objectForKey:@"name"];
                        CGFloat score = [[face valueForKeyPath:[d objectForKey:@"score"]] floatValue];
                        // don't allow valence as per Steve H's suggestion
                        if ([name isEqualToString:@"Valence"]) {
                            continue;
                        }
                        if (score > dominantScore) {
                            dominantScore = score;
                            dominantName = name;
                        }
                    }

#if FIND_MAX_EXPRESSION
                    // pass through expressions to find the dominant one
                    for (NSDictionary *d in self.expressions) {
                        CGFloat score = [[face valueForKeyPath:[d objectForKey:@"score"]] floatValue];
                        if (score > dominantScore) {
                            dominantScore = score;
                            dominantName = [d objectForKey:@"name"];
                        }
                    }
#endif

                    if (self.dominantEmotionOrExpression == nil) {
                        self.dominantEmotionOrExpression = [[ExpressionViewController alloc] initWithName:dominantName horizontalSizeClass:UIUserInterfaceSizeClassCompact];
                    }

                    if (dominantScore >= 50.0) {
                        self.dominantEmotionOrExpression.view.hidden = FALSE;
                        [self.dominantEmotionOrExpression setMetric:dominantScore];
                        self.dominantEmotionOrExpression.expressionLabel.text = dominantName;
                        // resize bounds to be relative in size to bounding box

                        CGSize size = self.dominantEmotionOrExpression.view.bounds.size;
                        CGFloat aspectRatio = size.height / size.width;
                        size.width = faceBounds.size.width * 1.0;
                        size.height = size.width * aspectRatio;
                        UIImage *image = [UIImage imageFromView:self.dominantEmotionOrExpression.view];
                        if (self.cameraToUse == AFDX_CAMERA_FRONT) {
                            image = [UIImage imageWithCGImage:image.CGImage
                                                        scale:image.scale
                                                  orientation:UIImageOrientationUpMirrored];
                        }
                        CGRect rect = CGRectMake(faceBounds.origin.x + (faceBounds.size.width / 2) - size.width / 2,
                                                 faceBounds.origin.y + faceBounds.size.height,
                                                 size.width,
                                                 size.height);
                        [imagesArray addObject:image];
                        [rectsArray addObject:[NSValue valueWithCGRect:rect]];
                    } else {
                        self.dominantEmotionOrExpression.view.hidden = TRUE;
                    }
                }
            }

            // do drawing here
            newImage = [AFDXDetector imageByDrawingPoints:weakSelf.drawFacePoints ? weakSelf.facePointsToDraw : nil
                                            andRectangles:weakSelf.drawFaceRect ? weakSelf.faceRectsToDraw : nil
                                                andImages:imagesArray
                                               withRadius:1.4
                                          usingPointColor:[UIColor whiteColor]
                                      usingRectangleColor:[UIColor whiteColor]
                                          usingImageRects:rectsArray
                                                  onImage:newImage];
        }

        // flip image if the front camera is being used so that the perspective is mirrored.
        if (self.cameraToUse == AFDX_CAMERA_FRONT)
        {
            UIImage *flippedImage = [UIImage imageWithCGImage:newImage.CGImage
                                                        scale:image.scale
                                                  orientation:UIImageOrientationUpMirrored];
            [weakSelf.imageView setImage:flippedImage];
        }
        else
        {
            [weakSelf.imageView setImage:newImage];
        }

    });

#ifdef DEMO_MODE
    static NSTimeInterval last = 0;
    const CGFloat timeConstant = 0.0000001;
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:(time - last) * timeConstant]];
    last = time;
#endif

    // compute frames per second and show
    NSDate *now = [NSDate date];

    if (nil != weakSelf.dateOfLastFrame)
    {
        NSTimeInterval interval = [now timeIntervalSinceDate:weakSelf.dateOfLastFrame];

        if (interval > 0)
        {
            float fps = 1.0 / interval;
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.fps.text = [NSString stringWithFormat:@"FPS(C): %.1f", fps];
            });
        }
    }

    weakSelf.dateOfLastFrame = now;
}

- (void)detector:(AFDXDetector *)detector hasResults:(NSMutableDictionary *)faces forImage:(UIImage *)image atTime:(NSTimeInterval)time;
{
    if (nil == faces)
    {
        [self unprocessedImageReady:detector image:image atTime:time];
    }
    else
    {
        [self processedImageReady:detector image:image faces:faces atTime:time];
    }
}

- (void)detector:(AFDXDetector *)detector didStartDetectingFace:(AFDXFace *)face;
{
    __block AffdexDemoViewController *weakSelf = self;

    dispatch_async(dispatch_get_main_queue(), ^{
        /*
         BOOL iPhone = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone);

         [UIView beginAnimations:nil context:NULL];
         [UIView setAnimationDuration:0.5];

         if (iPhone == TRUE)
         {
         weakSelf.classifier1View_compact.alpha = 1.0;
         weakSelf.classifier2View_compact.alpha = 1.0;
         weakSelf.classifier3View_compact.alpha = 1.0;
         weakSelf.classifier4View_compact.alpha = 1.0;
         weakSelf.classifier5View_compact.alpha = 1.0;
         weakSelf.classifier6View_compact.alpha = 1.0;
         }
         else
         {
         weakSelf.classifier1View_regular.alpha = 1.0;
         weakSelf.classifier2View_regular.alpha = 1.0;
         weakSelf.classifier3View_regular.alpha = 1.0;
         weakSelf.classifier4View_regular.alpha = 1.0;
         weakSelf.classifier5View_regular.alpha = 1.0;
         weakSelf.classifier6View_regular.alpha = 1.0;
         }

         [UIView commitAnimations];
         */
        if ((weakSelf.expressionViewControllers_compact != nil) && (weakSelf.expressionViewControllers_regular != nil))
        {
            face.userInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                             weakSelf.expressionViewControllers_compact, @"compactExpressionViewControllers",
                             weakSelf.expressionViewControllers_regular, @"regularExpressionViewControllers",
                             [NSNumber numberWithInt:AFDX_EMOJI_NONE], @"dominantEmoji",
                             nil];

#ifdef BROADCAST_VIA_UDP
            char buffer[2];
            buffer[0] = (char)face.faceId;
            buffer[1] = 1;
            NSData *d = [NSData dataWithBytes:buffer length:sizeof(buffer)];
            [weakSelf.udpSocket sendData:d toHost:MULTICAST_GROUP port:MULTICAST_PORT withTimeout:-1 tag:0];
#endif
        }
    });
}

- (void)detector:(AFDXDetector *)detector didStopDetectingFace:(AFDXFace *)face;
{
    //    __block AffdexDemoViewController *weakSelf = self;

    dispatch_async(dispatch_get_main_queue(), ^{
        for (ExpressionViewController *vc in self.expressionViewControllers_compact)
        {
            vc.metric = 0.0;
        }
        for (ExpressionViewController *vc in self.expressionViewControllers_regular)
        {
            vc.metric = 0.0;
        }

#if 0
        BOOL iPhone = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone);

        [UIView beginAnimations:nil context:NULL];
        [UIView setAnimationDuration:0.5];

        if (iPhone == TRUE)
        {
            weakSelf.classifier1View_compact.alpha = 0.0;
            weakSelf.classifier2View_compact.alpha = 0.0;
            weakSelf.classifier3View_compact.alpha = 0.0;
            weakSelf.classifier4View_compact.alpha = 0.0;
            weakSelf.classifier5View_compact.alpha = 0.0;
            weakSelf.classifier6View_compact.alpha = 0.0;
        }
        else
        {
            weakSelf.classifier1View_regular.alpha = 0.0;
            weakSelf.classifier2View_regular.alpha = 0.0;
            weakSelf.classifier3View_regular.alpha = 0.0;
            weakSelf.classifier4View_regular.alpha = 0.0;
            weakSelf.classifier5View_regular.alpha = 0.0;
            weakSelf.classifier6View_regular.alpha = 0.0;
        }

        [UIView commitAnimations];
#endif
        face.userInfo = nil;
#ifdef BROADCAST_VIA_UDP
        char buffer[2];
        buffer[0] = (char)face.faceId;
        buffer[1] = 0;
        NSData *d = [NSData dataWithBytes:buffer length:sizeof(buffer)];
        [weakSelf.udpSocket sendData:d toHost:MULTICAST_GROUP port:MULTICAST_PORT withTimeout:-1 tag:0];
#endif
    });
}

- (UIImage *)captureSnapshot;
{
    UIImage *result;

    UIGraphicsBeginImageContext(self.view.frame.size);
    [self.view drawViewHierarchyInRect:self.view.frame afterScreenUpdates:YES];
    result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return result;
}

- (IBAction)cameraButtonTouched:(id)sender;
{
    self.settingsView_compact.hidden = TRUE;
    self.settingsView_regular.hidden = TRUE;
    UIImage *snap = [self captureSnapshot];
    self.sound = [[SoundEffect alloc] initWithSoundNamed:@"camera-shutter.mp3"];
    [self.sound play];
    self.settingsView_compact.hidden = FALSE;
    self.settingsView_regular.hidden = FALSE;
    if (nil != snap)
    {
        UIImageWriteToSavedPhotosAlbum(snap, nil, nil, nil);
    }
}

- (IBAction)cameraSwapButtonTouched:(id)sender;
{
    if (self.cameraToUse == AFDX_CAMERA_FRONT)
    {
        self.cameraToUse = AFDX_CAMERA_BACK;
    }
    else
    {
        self.cameraToUse = AFDX_CAMERA_FRONT;
    }

    // set the expression bars for the visible expressions to 0
    for (ExpressionViewController *vc in self.expressionViewControllers_compact)
    {
        vc.metric = 0.0;
    }
    for (ExpressionViewController *vc in self.expressionViewControllers_regular)
    {
        vc.metric = 0.0;
    }

    // restart the detector so that the other camera comes into view
    [self startDetector];
}

#pragma mark -
#pragma mark ViewController Delegate Methods

+ (void)initialize;
{
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"drawFacePoints" : [NSNumber numberWithBool:YES]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"drawFaceRect" : [NSNumber numberWithBool:YES]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"drawAppearanceIcons" : [NSNumber numberWithBool:YES]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"drawEmojis" : [NSNumber numberWithBool:YES]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"allowMultiface" : [NSNumber numberWithBool:NO]}];
}

-(BOOL)canBecomeFirstResponder;
{
    return YES;
}

- (void)dealloc;
{
    self.detector = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)prepareForBackground:(id)sender;
{
#ifdef BROADCAST_VIA_UDP
    self.udpSocket = nil;
#endif
    [self stopDetector];
}

- (void)prepareForForeground:(id)sender;
{
    [self startDetector];
#ifdef BROADCAST_VIA_UDP
    dispatch_queue_t q = dispatch_queue_create("udp", 0);
    self.udpSocket = [[GCDAsyncUdpSocket alloc] initWithSocketQueue:q];
#endif
}

- (id)initWithCoder:(NSCoder *)aDecoder;
{
    if (self = [super initWithCoder:aDecoder])
    {
        self.emotions = @[@{@"name" : @"Anger",
                            @"propertyName" : @"anger",
                            @"score": @"emotions.anger",
                            @"image": [UIImage imageNamed:@"Anger.jpg"]
                            },
                          @{@"name" : @"Contempt",
                            @"propertyName" : @"contempt",
                            @"score": @"emotions.contempt",
                            @"image": [UIImage imageNamed:@"Contempt.jpg"]
                            },
                          @{@"name" : @"Disgust",
                            @"propertyName" : @"disgust",
                            @"score": @"emotions.disgust",
                            @"image": [UIImage imageNamed:@"Disgust.jpg"]
                            },
                          @{@"name" : @"Engagement",
                            @"propertyName" : @"engagement",
                            @"score": @"emotions.engagement",
                            @"image": [UIImage imageNamed:@"Engagement.jpg"]
                            },
                          @{@"name" : @"Fear",
                            @"propertyName" : @"fear",
                            @"score": @"emotions.fear",
                            @"image": [UIImage imageNamed:@"Fear.jpg"]
                            },
                          @{@"name" : @"Joy",
                            @"propertyName" : @"joy",
                            @"score": @"emotions.joy",
                            @"image": [UIImage imageNamed:@"Joy.jpg"]
                            },
                          @{@"name" : @"Sadness",
                            @"propertyName" : @"sadness",
                            @"score": @"emotions.sadness",
                            @"image": [UIImage imageNamed:@"Sadness.jpg"]
                            },
                          @{@"name" : @"Surprise",
                            @"propertyName" : @"surprise",
                            @"score": @"emotions.surprise",
                            @"image": [UIImage imageNamed:@"Surprise.jpg"]
                            },
                          @{@"name" : @"Valence",
                            @"propertyName" : @"valence",
                            @"score": @"emotions.valence",
                            @"image": [UIImage imageNamed:@"Valence.jpg"]
                            }
                          ];

        self.expressions = @[@{@"name" : @"Attention",
                               @"propertyName" : @"attention",
                               @"score": @"attentionScore",
                               @"image": [UIImage imageNamed:@"Attention.jpg"]
                               },
                             @{@"name" : @"Brow Furrow",
                               @"propertyName" : @"browFurrow",
                               @"score": @"browFurrowScore",
                               @"image": [UIImage imageNamed:@"Brow Furrow.jpg"]
                               },
                             @{@"name" : @"Brow Raise",
                               @"propertyName" : @"browRaise",
                               @"score": @"browRaiseScore",
                               @"image": [UIImage imageNamed:@"Brow Raise.jpg"]
                               },
                             @{@"name" : @"Chin Raise",
                               @"propertyName" : @"chinRaise",
                               @"score": @"chinRaiseScore",
                               @"image": [UIImage imageNamed:@"Chin Raise.jpg"]
                               },
                             @{@"name" : @"Eye Closure",
                               @"propertyName" : @"eyeClosure",
                               @"score": @"eyeClosureScore",
                               @"image": [UIImage imageNamed:@"Eye Closure.jpg"]
                               },
                             @{@"name" : @"Inner Brow Raise",
                               @"propertyName" : @"innerBrowRaise",
                               @"score": @"innerBrowRaiseScore",
                               @"image": [UIImage imageNamed:@"Inner Brow Raise.jpg"]
                               },
                             @{@"name" : @"Frown",
                               @"propertyName" : @"lipCornerDepressor",
                               @"score": @"lipCornerDepressorScore",
                               @"image": [UIImage imageNamed:@"Frown.jpg"]
                               },
                             @{@"name" : @"Lip Press",
                               @"propertyName" : @"lipPress",
                               @"score": @"lipPressScore",
                               @"image": [UIImage imageNamed:@"Lip Press.jpg"]
                               },
                             @{@"name" : @"Lip Pucker",
                               @"propertyName" : @"lipPucker",
                               @"score": @"lipPuckerScore",
                               @"image": [UIImage imageNamed:@"Lip Pucker.jpg"]
                               },
                             @{@"name" : @"Lip Suck",
                               @"propertyName" : @"lipSuck",
                               @"score": @"lipSuckScore",
                               @"image": [UIImage imageNamed:@"Lip Suck.jpg"]
                               },
                             @{@"name" : @"Mouth Open",
                               @"propertyName" : @"mouthOpen",
                               @"score": @"mouthOpenScore",
                               @"image": [UIImage imageNamed:@"Mouth Open.jpg"]
                               },
                             @{@"name" : @"Nose Wrinkle",
                               @"propertyName" : @"noseWrinkle",
                               @"score": @"noseWrinkleScore",
                               @"image": [UIImage imageNamed:@"Nose Wrinkle.jpg"]
                               },
                             @{@"name" : @"Smile",
                               @"propertyName" : @"smile",
                               @"score": @"smileScore",
                               @"image": [UIImage imageNamed:@"Smile.jpg"]
                               },
                             @{@"name" : @"Smirk",
                               @"propertyName" : @"smirk",
                               @"score": @"smirkScore",
                               @"image": [UIImage imageNamed:@"Smirk.jpg"]
                               },
                             @{@"name" : @"Upper Lip Raise",
                               @"propertyName" : @"upperLipRaise",
                               @"score": @"upperLipRaiseScore",
                               @"image": [UIImage imageNamed:@"Upper Lip Raise.jpg"]
                               }
                             ];

        CGFloat emojiFontSize = 80.0;

        self.emojis = @[@{@"name" : @"Laughing",
                          @"score": @"emojis.laughing",
                          @"image": [UIImage imageFromText:@"😆" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_LAUGHING]
                          },
                        @{@"name" : @"Smiley",
                          @"score": @"emojis.smiley",
                          @"image": [UIImage imageFromText:@"😀" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_SMILEY]
                          },
                        @{@"name" : @"Relaxed",
                          @"score": @"emojis.relaxed",
                          @"image": [UIImage imageFromText:@"☺️" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_RELAXED]
                          },
                        @{@"name" : @"Wink",
                          @"score": @"emojis.wink",
                          @"image": [UIImage imageFromText:@"😉" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_WINK]
                          },
                        @{@"name" : @"Kiss",
                          @"score": @"emojis.kissing",
                          @"image": [UIImage imageFromText:@"😗" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_KISSING]
                          },
                        @{@"name" : @"Tongue Wink",
                          @"score": @"emojis.stuckOutTongueWinkingEye",
                          @"image": [UIImage imageFromText:@"😜" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_STUCK_OUT_TONGUE_WINKING_EYE]
                          },
                        @{@"name" : @"Tongue Out",
                          @"score": @"emojis.stuckOutTongue",
                          @"image": [UIImage imageFromText:@"😛" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_STUCK_OUT_TONGUE]
                          },
                        @{@"name" : @"Flushed",
                          @"score": @"emojis.flushed",
                          @"image": [UIImage imageFromText:@"😳" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_FLUSHED]
                          },
                        @{@"name" : @"Disappointed",
                          @"score": @"emojis.disappointed",
                          @"image": [UIImage imageFromText:@"😞" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_DISAPPOINTED]
                          },
                        @{@"name" : @"Rage",
                          @"score": @"emojis.rage",
                          @"image": [UIImage imageFromText:@"😡" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_RAGE]
                          },
                        @{@"name" : @"Scream",
                          @"score": @"emojis.scream",
                          @"image": [UIImage imageFromText:@"😱" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_SCREAM]
                          },
                        @{@"name" : @"Smirk",
                          @"score": @"emojis.smirk",
                          @"image": [UIImage imageFromText:@"😏" size:emojiFontSize],
                          @"code": [NSNumber numberWithInt:AFDX_EMOJI_SMIRK]
                          }
                        ];

        self.availableClassifiers = @[self.emotions, self.expressions];

        self.selectedClassifiers = [[[NSUserDefaults standardUserDefaults] objectForKey:@"selectedClassifiers"] mutableCopy];
        if (self.selectedClassifiers == nil)
        {
            self.selectedClassifiers = [NSMutableArray arrayWithObjects:@"Anger", @"Contempt", @"Disgust", @"Fear", @"Joy", @"Sadness", @"Surprise", @"Valence", nil];
        }
    }
    return self;
}


- (void)viewDidLoad;
{
    [super viewDidLoad];

    self.cameraToUse = AFDX_CAMERA_FRONT;

    CGFloat scaleFactor = 1.0;
    BOOL compactWidth = [self traitCollection].horizontalSizeClass == UIUserInterfaceSizeClassCompact;
    if (compactWidth == TRUE) {
        scaleFactor *= 1.0;
    }

    self.maleImage = [UIImage imageNamed:@"male-noglasses.png"];
    self.maleImage = [UIImage imageWithCGImage:[self.maleImage CGImage]
                                         scale:(self.maleImage.scale * scaleFactor)
                                   orientation:(self.maleImage.imageOrientation)];
    self.femaleImage = [UIImage imageNamed:@"female-noglasses.png"];
    self.femaleImage = [UIImage imageWithCGImage:[self.femaleImage CGImage]
                                           scale:(self.femaleImage.scale * scaleFactor)
                                     orientation:(self.femaleImage.imageOrientation)];
    self.maleImageWithGlasses = [UIImage imageNamed:@"male-glasses.png"];
    self.maleImageWithGlasses = [UIImage imageWithCGImage:[self.maleImageWithGlasses CGImage]
                                                    scale:(self.maleImageWithGlasses.scale * scaleFactor)
                                              orientation:(self.maleImageWithGlasses.imageOrientation)];
    self.femaleImageWithGlasses = [UIImage imageNamed:@"female-glasses.png"];
    self.femaleImageWithGlasses = [UIImage imageWithCGImage:[self.femaleImageWithGlasses CGImage]
                                                      scale:(self.femaleImageWithGlasses.scale * scaleFactor)
                                                orientation:(self.femaleImageWithGlasses.imageOrientation)];
    self.unknownImage = [UIImage imageNamed:@"unknown-noglasses.png"];
    self.unknownImage = [UIImage imageWithCGImage:[self.unknownImage CGImage]
                                            scale:(self.unknownImage.scale * scaleFactor)
                                      orientation:(self.unknownImage.imageOrientation)];
    self.unknownImageWithGlasses = [UIImage imageNamed:@"unknown-glasses.png"];
    self.unknownImageWithGlasses = [UIImage imageWithCGImage:[self.unknownImageWithGlasses CGImage]
                                                       scale:(self.unknownImageWithGlasses.scale * scaleFactor)
                                                 orientation:(self.unknownImageWithGlasses.imageOrientation)];

    // The classifier views are all defined as separate IBOutlets.
    // Populate into arrays so we can iterate through them.
    self.classifierViews_compact = [NSMutableArray arrayWithObjects:self.classifier1View_compact,
                                    self.classifier2View_compact,
                                    self.classifier3View_compact,
                                    self.classifier4View_compact,
                                    self.classifier5View_compact,
                                    self.classifier6View_compact,
                                    nil];
    self.classifierViews_regular = [NSMutableArray arrayWithObjects:self.classifier1View_regular,
                                    self.classifier2View_regular,
                                    self.classifier3View_regular,
                                    self.classifier4View_regular,
                                    self.classifier5View_regular,
                                    self.classifier6View_regular,
                                    nil];

    // Version number.
    NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString *)kCFBundleVersionKey];
    NSString *shortVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];

    self.versionLabel_compact.text = [NSString stringWithFormat:@"%@ (%@)", shortVersion, version];
    self.versionLabel_regular.text = self.versionLabel_compact.text;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(prepareForBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(prepareForForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (void)viewWillDisappear:(BOOL)animated;
{
    [self resignFirstResponder];

    [super viewWillDisappear:animated];

    [self stopDetector];

    for (ExpressionViewController *vc in self.expressionViewControllers_compact)
    {
        [vc.view removeFromSuperview];
    }
    for (ExpressionViewController *vc in self.expressionViewControllers_regular)
    {
        [vc.view removeFromSuperview];
    }

    self.expressionViewControllers_compact = nil;
    self.expressionViewControllers_regular = nil;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection;
{
#if 0
    UIUserInterfaceSizeClass previousHorizontalSizeClass = [previousTraitCollection horizontalSizeClass];
    UIUserInterfaceSizeClass newHorizontalSizeClass = [[self traitCollection] horizontalSizeClass];

    NSLog(@"trait collection horizontal size class %ld --> %ld", (long) previousHorizontalSizeClass, (long) newHorizontalSizeClass);
#endif
}

- (void)viewWillAppear:(BOOL)animated;
{
    self.versionLabel_compact.hidden = TRUE;
    self.versionLabel_regular.hidden = TRUE;
    [self.imageView setImage:nil];

    [super viewWillAppear:animated];

    // setup views

    // create the expression view controllers to hold the expressions for this face

    self.expressionViewControllers_compact = [NSMutableArray new];
    self.expressionViewControllers_regular = [NSMutableArray new];

    NSInteger selectedClassifierCount = [self.selectedClassifiers count];
    for (NSInteger i=0; i<6; i++)
    {
        NSString *classifierName;
        if (i < selectedClassifierCount)
        {
            classifierName = [self.selectedClassifiers objectAtIndex:i];
        }
        else
        {
            classifierName = @"";
        }

        // Classifier view
        // compact
        UIView *classifierView_compact = [self.classifierViews_compact objectAtIndex:i];
        [classifierView_compact setBackgroundColor:[UIColor clearColor]];
        classifierView_compact.alpha = 1.0;

        // regular
        UIView *classifierView_regular = [self.classifierViews_regular objectAtIndex:i];
        [classifierView_regular setBackgroundColor:[UIColor clearColor]];
        classifierView_regular.alpha = 1.0;

        // Expression view controller
        ExpressionViewController *vc;

        vc = [[ExpressionViewController alloc] initWithName:classifierName horizontalSizeClass:UIUserInterfaceSizeClassCompact];
        [self.expressionViewControllers_compact addObject:vc];
        [classifierView_compact addSubview:vc.view];

        vc = [[ExpressionViewController alloc] initWithName:classifierName horizontalSizeClass:UIUserInterfaceSizeClassRegular];
        [self.expressionViewControllers_regular addObject:vc];
        [classifierView_regular addSubview:vc.view];
    }

    [[NSUserDefaults standardUserDefaults] setObject:self.selectedClassifiers forKey:@"selectedClassifiers"];

    [self enterSingleFaceMode];
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event;
{
    if (event.subtype == UIEventSubtypeMotionShake)
    {
        self.versionLabel_compact.hidden = !self.versionLabel_compact.hidden;
        self.versionLabel_regular.hidden = !self.versionLabel_regular.hidden;
    }

    [super motionEnded:motion withEvent:event];
}

- (void)viewDidAppear:(BOOL)animated;
{
    [super viewDidAppear:animated];
    [self becomeFirstResponder];

#ifdef DEMO_MODE
    self.mediaFilename = [[NSBundle mainBundle] pathForResource:@"face1" ofType:@"m4v"];
    //    self.mediaFilename = [[NSBundle mainBundle] pathForResource:@"faces_in_out" ofType:@"mp4"];

    if ([[NSFileManager defaultManager] fileExistsAtPath:self.mediaFilename] == YES)
    {
        [self startDetector];
    }
#else
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if(status == AVAuthorizationStatusAuthorized) {
        // authorized
        [self startDetector];
    } else if(status == AVAuthorizationStatusDenied){
        // denied
        [self showAlertWithTitle:@"Error!" message:@"AffdexMe doesn't have permission to use camera, please change privacy settings"];
    } else if(status == AVAuthorizationStatusRestricted){
        // restricted
    } else if(status == AVAuthorizationStatusNotDetermined){
        // not determined
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            if(granted){
                [self startDetector];
            } else {
                [self showAlertWithTitle:@"Error!" message:@"AffdexMe doesn't have permission to use camera, please change privacy settings"];
            }
        }];
    }
#endif
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *dismiss = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:dismiss];
    [self showViewController:alert sender:nil];
}

- (void)stopDetector;
{
    [self.detector stop];
}

- (void)startDetector;
{
    [self.detector stop];

    NSUInteger maximumFaces = 1;
    if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"allowMultiface"] boolValue] == YES) {
        maximumFaces = 3;
    }
#ifdef DEMO_MODE
    // create a detector with our desired facial expressions, using a media file since simulators can't access the camera.
    self.detector = [[AFDXDetector alloc] initWithDelegate:self usingFile:self.mediaFilename maximumFaces:maximumFaces];
#else
    // create a detector with our desired facial expresions, using the front facing camera
    self.detector = [[AFDXDetector alloc] initWithDelegate:self usingCamera:self.cameraToUse maximumFaces:maximumFaces];
#endif
    [self.detector enableAnalytics];

    self.drawFacePoints = [[[NSUserDefaults standardUserDefaults] objectForKey:@"drawFacePoints"] boolValue];
    self.drawFaceRect = [[[NSUserDefaults standardUserDefaults] objectForKey:@"drawFaceRect"] boolValue];//self.drawFacePoints;
    self.drawAppearanceIcons = [[[NSUserDefaults standardUserDefaults] objectForKey:@"drawAppearanceIcons"] boolValue];
    self.drawEmojis = [[[NSUserDefaults standardUserDefaults] objectForKey:@"drawEmojis"] boolValue];

    NSInteger maxProcessRate = [[[NSUserDefaults standardUserDefaults] objectForKey:@"maxProcessRate"] integerValue];
    if (0 == maxProcessRate)
    {
        maxProcessRate = 5;
    }

    if ([[[UIDeviceHardware new] platformString] isEqualToString:@"iPhone 4S"])
    {
        maxProcessRate = 4;
    }

    self.detector.maxProcessRate = maxProcessRate;
    self.dateOfLastFrame = nil;
    self.dateOfLastProcessedFrame = nil;

    // tell the detector which facial expressions we want to measure
#define ENABLE_ALL_CLASSIFIERS    0  // 1 to enable all classifiers, 0 for minimum set
#if ENABLE_ALL_CLASSIFIERS  // Enable everything for firehose testing
    [self.detector setDetectAllAppearances:YES];
    [self.detector setDetectAllEmotions:YES];
    [self.detector setDetectAllExpressions:YES];
    [self.detector setDetectEmojis:YES];
#else
    [self.detector setDetectAllAppearances:YES];
    [self.detector setDetectAllEmotions:NO];
    [self.detector setDetectAllExpressions:NO];
    [self.detector setDetectEmojis:YES];
    self.detector.valence = TRUE;
#endif

    for (NSString *s in self.selectedClassifiers)
    {
        for (NSArray *a in self.availableClassifiers)
        {
            for (NSDictionary *d in a) {
                if ([s isEqualToString:[d objectForKey:@"name"]])
                {
                    NSString *pn = [d objectForKey:@"propertyName"];
                    if (nil != pn) {
                        [self.detector setValue:[NSNumber numberWithBool:YES] forKey:pn];
                    } else {
                        [self.detector setDetectEmojis:YES];
                    }
                    break;
                }
            }
        }
    }

    // let's start it up!
    NSError *error = [self.detector start];

    if (nil != error)
    {
        [self showAlertWithTitle:@"Detector Error" message:[error localizedDescription]];

        return;
    }

#ifdef BROADCAST_VIA_UDP
    dispatch_queue_t q = dispatch_queue_create("udp", 0);
    self.udpSocket = [[GCDAsyncUdpSocket alloc] initWithSocketQueue:q];
#endif
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

-(void)addSubView:(UIView *)highlightView withFrame:(CGRect)frame
{
    highlightView.frame = frame;
    highlightView.layer.borderWidth = 1;
    highlightView.layer.borderColor = [[UIColor whiteColor] CGColor];
    [self.imageView addSubview:highlightView];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations;
{
    NSUInteger result;

    result = UIInterfaceOrientationMaskAll;

    return result;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender;
{
    EmotionPickerViewController *vc = segue.destinationViewController;
    vc.selectedClassifiers = self.selectedClassifiers;
    vc.availableClassifiers = self.availableClassifiers;
}

- (IBAction)showPicker:(id)sender;
{
    [self performSegueWithIdentifier:@"select" sender:self];
}

@end

