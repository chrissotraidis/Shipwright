#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <SDL.h>

#include "HarkinianPadTouchControls.h"

static std::atomic_bool sTouchControlsDesired(false);
static std::atomic_bool sCustomizableTouchControlsDesired(false);
static std::atomic<float> sTouchControlsOpacity(1.0f);
static std::atomic_bool sTouchControlsMenuVisible(false);
static std::atomic_bool sLayoutEditorActive(false);
static BOOL sLayoutEditorRequested;
static std::atomic_bool sNativeHudTouchDesired(false);
static std::atomic_bool sNativeHudTouchGameplayActive(false);
static std::atomic<float> sNativeHudButtonCenters[HARKINIANPAD_HUD_BUTTON_COUNT][2];
static std::atomic<float> sNativeHudButtonWidths[HARKINIANPAD_HUD_BUTTON_COUNT];

static void HarkinianPad_PushKey(SDL_Scancode scancode, BOOL pressed) {
    SDL_Event event = {};
    event.type = pressed ? SDL_KEYDOWN : SDL_KEYUP;
    event.key.timestamp = SDL_GetTicks();
    event.key.state = pressed ? SDL_PRESSED : SDL_RELEASED;
    event.key.repeat = 0;
    event.key.keysym.scancode = scancode;
    event.key.keysym.sym = SDL_GetKeyFromScancode(scancode);
    SDL_Window* window = SDL_GetKeyboardFocus();
    if (window != nullptr) {
        event.key.windowID = SDL_GetWindowID(window);
    }
    SDL_PushEvent(&event);
}

@interface HarkinianPadTouchButton : UIButton

@property(nonatomic) SDL_Scancode scancode;
@property(nonatomic) BOOL inputPressed;
@property(nonatomic) BOOL inputLatched;
@property(nonatomic) BOOL holdToLatch;
@property(nonatomic) NSUInteger latchGeneration;
@property(nonatomic) BOOL layoutEditing;
@property(nonatomic) BOOL usesPillShape;
@property(nonatomic) BOOL nativeHudArtworkHidden;
@property(nonatomic, strong) UIColor* idleColor;
@property(nonatomic, strong) UIColor* pressedColor;

- (instancetype)initWithLabel:(NSString*)label
                     scancode:(SDL_Scancode)scancode
                         pill:(BOOL)pill;
- (void)applyIdleColor:(UIColor*)idleColor
          pressedColor:(UIColor*)pressedColor;
- (void)setNativeHudArtworkHidden:(BOOL)hidden;
- (void)updateAppearance;
- (void)cancelInput;

@end

@implementation HarkinianPadTouchButton

- (instancetype)initWithLabel:(NSString*)label
                     scancode:(SDL_Scancode)scancode
                         pill:(BOOL)pill {
    self = [super initWithFrame:CGRectZero];
    if (self != nil) {
        self.scancode = scancode;
        self.usesPillShape = pill;
        self.multipleTouchEnabled = YES;
        self.idleColor = [UIColor colorWithWhite:0.04 alpha:0.38];
        self.pressedColor = [UIColor colorWithWhite:0.72 alpha:0.48];
        self.backgroundColor = self.idleColor;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.58].CGColor;
        self.layer.borderWidth = 2.0;
        [self setTitle:label forState:UIControlStateNormal];
        [self setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.92]
                   forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
        self.accessibilityLabel = label;

        [self addTarget:self
                      action:@selector(inputDown)
            forControlEvents:UIControlEventTouchDown];
        [self addTarget:self
                      action:@selector(inputDragEnter)
            forControlEvents:UIControlEventTouchDragEnter];
        [self addTarget:self
                      action:@selector(inputUp)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                             UIControlEventTouchCancel | UIControlEventTouchDragExit];
    }
    return self;
}

- (void)applyIdleColor:(UIColor*)idleColor
          pressedColor:(UIColor*)pressedColor {
    self.idleColor = idleColor;
    self.pressedColor = pressedColor;
    [self updateAppearance];
}

- (void)setNativeHudArtworkHidden:(BOOL)hidden {
    if (_nativeHudArtworkHidden == hidden) {
        return;
    }
    _nativeHudArtworkHidden = hidden;
    [self updateAppearance];
}

- (void)updateAppearance {
    if (self.nativeHudArtworkHidden) {
        self.layer.opacity = 1.0f;
        self.backgroundColor = UIColor.clearColor;
        self.layer.borderColor = UIColor.clearColor.CGColor;
        [self setTitleColor:UIColor.clearColor forState:UIControlStateNormal];
        return;
    }

    self.layer.opacity = 1.0f;
    self.backgroundColor =
        self.inputLatched
            ? [UIColor colorWithRed:0.22 green:0.58 blue:0.96 alpha:0.92]
            : (self.inputPressed ? self.pressedColor : self.idleColor);
    self.layer.borderColor =
        (self.inputLatched
             ? [UIColor colorWithRed:0.62 green:0.82 blue:1.0 alpha:1.0]
             : [UIColor colorWithWhite:1.0 alpha:0.58]).CGColor;
    [self setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.92]
               forState:UIControlStateNormal];
}

- (void)setHoldToLatch:(BOOL)holdToLatch {
    if (_holdToLatch == holdToLatch) {
        return;
    }
    if (!holdToLatch) {
        [self cancelInput];
    }
    _holdToLatch = holdToLatch;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius =
        self.usesPillShape ? CGRectGetHeight(self.bounds) * 0.48
                           : MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.5;
}

- (void)beginInput {
    if (self.layoutEditing || self.inputPressed) {
        return;
    }
    self.inputPressed = YES;
    [self updateAppearance];
    HarkinianPad_PushKey(self.scancode, YES);
    if (self.holdToLatch) {
        NSUInteger generation = ++self.latchGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (self.latchGeneration == generation) {
                               [self latchInput];
                           }
                       });
    }
}

- (void)inputDown {
    if (self.layoutEditing) {
        return;
    }
    if (self.inputLatched) {
        self.inputLatched = NO;
        self.inputPressed = NO;
        self.accessibilityValue = nil;
        [self updateAppearance];
        HarkinianPad_PushKey(self.scancode, NO);
        return;
    }
    [self beginInput];
}

- (void)inputDragEnter {
    if (!self.inputLatched) {
        [self beginInput];
    }
}

- (void)latchInput {
    if (!self.holdToLatch || self.layoutEditing || !self.inputPressed) {
        return;
    }
    self.inputLatched = YES;
    self.accessibilityValue = @"Locked";
    UIImpactFeedbackGenerator* feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
}

- (void)inputUp {
    self.latchGeneration++;
    if (self.layoutEditing || self.inputLatched || !self.inputPressed) {
        return;
    }
    self.inputPressed = NO;
    [self updateAppearance];
    HarkinianPad_PushKey(self.scancode, NO);
}

- (void)cancelInput {
    self.latchGeneration++;
    self.inputLatched = NO;
    self.accessibilityValue = nil;
    if (!self.inputPressed) {
        [self updateAppearance];
        return;
    }
    self.inputPressed = NO;
    [self updateAppearance];
    HarkinianPad_PushKey(self.scancode, NO);
}

@end

static HarkinianPadTouchButton* sMenuButton;

@interface HarkinianPadTouchStick : UIView

@property(nonatomic, strong) UIView* knob;
@property(nonatomic) BOOL layoutEditing;
@property(nonatomic) BOOL upPressed;
@property(nonatomic) BOOL downPressed;
@property(nonatomic) BOOL leftPressed;
@property(nonatomic) BOOL rightPressed;

- (void)cancelInput;

@end

@implementation HarkinianPadTouchStick

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.multipleTouchEnabled = NO;
        self.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.30];
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
        self.layer.borderWidth = 2.0;
        self.accessibilityLabel = @"Control Stick";

        self.knob = [[UIView alloc] initWithFrame:CGRectZero];
        self.knob.userInteractionEnabled = NO;
        self.knob.backgroundColor = [UIColor colorWithRed:0.34 green:0.62 blue:0.82 alpha:0.68];
        self.knob.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.62].CGColor;
        self.knob.layer.borderWidth = 2.0;
        [self addSubview:self.knob];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.5;
    CGFloat knobSize = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.43;
    self.knob.bounds = CGRectMake(0.0, 0.0, knobSize, knobSize);
    if (!self.upPressed && !self.downPressed && !self.leftPressed && !self.rightPressed) {
        self.knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    }
    self.knob.layer.cornerRadius = knobSize * 0.5;
}

- (void)setScancode:(SDL_Scancode)scancode pressed:(BOOL)pressed state:(BOOL*)state {
    if (*state == pressed) {
        return;
    }
    *state = pressed;
    HarkinianPad_PushKey(scancode, pressed);
}

- (void)updateForPoint:(CGPoint)point {
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGFloat radius = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.34;
    CGFloat dx = point.x - center.x;
    CGFloat dy = point.y - center.y;
    CGFloat distance = hypot(dx, dy);
    if (distance > radius && distance > 0.0) {
        dx = dx / distance * radius;
        dy = dy / distance * radius;
    }
    self.knob.center = CGPointMake(center.x + dx, center.y + dy);

    // Use separate engage/release thresholds so a thumb near the boundary
    // does not chatter between directions. Keep smaller deflections cardinal
    // for precise menu and name-entry navigation; the outer ring allows
    // normal diagonal movement.
    CGFloat engageThreshold = radius * 0.46;
    CGFloat releaseThreshold = radius * 0.28;
    CGFloat horizontalThreshold = (self.leftPressed || self.rightPressed) ? releaseThreshold : engageThreshold;
    CGFloat verticalThreshold = (self.upPressed || self.downPressed) ? releaseThreshold : engageThreshold;
    BOOL pressUp = dy < -verticalThreshold;
    BOOL pressDown = dy > verticalThreshold;
    BOOL pressLeft = dx < -horizontalThreshold;
    BOOL pressRight = dx > horizontalThreshold;

    if (distance < radius * 0.78) {
        if (fabs(dx) >= fabs(dy)) {
            pressUp = NO;
            pressDown = NO;
        } else {
            pressLeft = NO;
            pressRight = NO;
        }
    }

    [self setScancode:SDL_SCANCODE_W pressed:pressUp state:&_upPressed];
    [self setScancode:SDL_SCANCODE_S pressed:pressDown state:&_downPressed];
    [self setScancode:SDL_SCANCODE_A pressed:pressLeft state:&_leftPressed];
    [self setScancode:SDL_SCANCODE_D pressed:pressRight state:&_rightPressed];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (self.layoutEditing) {
        return;
    }
    UITouch* touch = touches.anyObject;
    if (touch != nil) {
        [self updateForPoint:[touch locationInView:self]];
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (self.layoutEditing) {
        return;
    }
    UITouch* touch = touches.anyObject;
    if (touch != nil) {
        [self updateForPoint:[touch locationInView:self]];
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self cancelInput];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self cancelInput];
}

- (void)cancelInput {
    [self setScancode:SDL_SCANCODE_W pressed:NO state:&_upPressed];
    [self setScancode:SDL_SCANCODE_S pressed:NO state:&_downPressed];
    [self setScancode:SDL_SCANCODE_A pressed:NO state:&_leftPressed];
    [self setScancode:SDL_SCANCODE_D pressed:NO state:&_rightPressed];
    self.knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
}

@end

@interface HarkinianPadTouchOverlay : UIView

@property(nonatomic, strong) HarkinianPadTouchStick* controlStick;
@property(nonatomic, strong) NSArray<HarkinianPadTouchButton*>* buttons;
@property(nonatomic, strong) HarkinianPadTouchButton* buttonA;
@property(nonatomic, strong) HarkinianPadTouchButton* buttonB;
@property(nonatomic, strong) HarkinianPadTouchButton* buttonL;
@property(nonatomic, strong) HarkinianPadTouchButton* buttonZRight;
@property(nonatomic, strong) HarkinianPadTouchButton* buttonR;
@property(nonatomic, strong) HarkinianPadTouchButton* buttonStart;
@property(nonatomic, strong) HarkinianPadTouchButton* dUp;
@property(nonatomic, strong) HarkinianPadTouchButton* dDown;
@property(nonatomic, strong) HarkinianPadTouchButton* dLeft;
@property(nonatomic, strong) HarkinianPadTouchButton* dRight;
@property(nonatomic, strong) HarkinianPadTouchButton* cUp;
@property(nonatomic, strong) HarkinianPadTouchButton* cDown;
@property(nonatomic, strong) HarkinianPadTouchButton* cLeft;
@property(nonatomic, strong) HarkinianPadTouchButton* cRight;
@property(nonatomic) BOOL customizableControls;
@property(nonatomic) BOOL layoutEditing;
@property(nonatomic) CGFloat touchControlsOpacity;
@property(nonatomic, strong) NSArray<UIView*>* editableControls;
@property(nonatomic, strong) NSMutableArray<UIGestureRecognizer*>* editGestures;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSArray<NSNumber*>*>* layoutCenters;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*>* layoutScales;
@property(nonatomic, strong) NSMutableSet<NSString*>* hiddenControls;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSValue*>* defaultSizes;
@property(nonatomic, copy) NSString* layoutProfile;
@property(nonatomic, strong) UIView* selectedControl;
@property(nonatomic, strong) UIView* editorPanel;
@property(nonatomic, strong) UILabel* editorLabel;
@property(nonatomic, strong) UISlider* sizeSlider;
@property(nonatomic, strong) UIButton* visibilityButton;
@property(nonatomic, strong) UIButton* resetButton;
@property(nonatomic, strong) UIButton* doneButton;

- (void)cancelAllInputs;
- (void)setCustomizableControlsEnabled:(BOOL)enabled;
- (void)setTouchControlsOpacity:(CGFloat)opacity;
- (void)beginLayoutEditing;
- (void)endLayoutEditing;
- (void)installLayoutEditor;
- (void)finishControlLayoutForCompact:(BOOL)compact;
- (void)publishNativeHudButtonCenters;
- (void)applyNativeHudVisualState;

@end

@implementation HarkinianPadTouchOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = YES;

        self.controlStick = [[HarkinianPadTouchStick alloc] initWithFrame:CGRectZero];
        self.buttonA = [[HarkinianPadTouchButton alloc] initWithLabel:@"A" scancode:SDL_SCANCODE_X pill:NO];
        self.buttonB = [[HarkinianPadTouchButton alloc] initWithLabel:@"B" scancode:SDL_SCANCODE_C pill:NO];
        self.buttonL = [[HarkinianPadTouchButton alloc] initWithLabel:@"L" scancode:SDL_SCANCODE_E pill:YES];
        self.buttonZRight = [[HarkinianPadTouchButton alloc] initWithLabel:@"Z" scancode:SDL_SCANCODE_Z pill:NO];
        self.buttonR = [[HarkinianPadTouchButton alloc] initWithLabel:@"R" scancode:SDL_SCANCODE_R pill:YES];
        self.buttonStart =
            [[HarkinianPadTouchButton alloc] initWithLabel:@"▶" scancode:SDL_SCANCODE_SPACE pill:NO];
        self.dUp =
            [[HarkinianPadTouchButton alloc] initWithLabel:@"▲" scancode:SDL_SCANCODE_T pill:NO];
        self.dDown =
            [[HarkinianPadTouchButton alloc] initWithLabel:@"▼" scancode:SDL_SCANCODE_G pill:NO];
        self.dLeft =
            [[HarkinianPadTouchButton alloc] initWithLabel:@"◀" scancode:SDL_SCANCODE_F pill:NO];
        self.dRight =
            [[HarkinianPadTouchButton alloc] initWithLabel:@"▶" scancode:SDL_SCANCODE_H pill:NO];
        self.cUp =
            [[HarkinianPadTouchButton alloc] initWithLabel:@"▲" scancode:SDL_SCANCODE_UP pill:NO];
        self.cDown =
            [[HarkinianPadTouchButton alloc] initWithLabel:@"▼" scancode:SDL_SCANCODE_DOWN pill:NO];
        self.cLeft =
            [[HarkinianPadTouchButton alloc] initWithLabel:@"◀" scancode:SDL_SCANCODE_LEFT pill:NO];
        self.cRight =
            [[HarkinianPadTouchButton alloc] initWithLabel:@"▶" scancode:SDL_SCANCODE_RIGHT pill:NO];

        [self.buttonA
            applyIdleColor:[UIColor colorWithRed:0.08 green:0.35 blue:0.88 alpha:0.58]
              pressedColor:[UIColor colorWithRed:0.14 green:0.48 blue:1.00 alpha:0.88]];
        [self.buttonB
            applyIdleColor:[UIColor colorWithRed:0.05 green:0.55 blue:0.24 alpha:0.58]
              pressedColor:[UIColor colorWithRed:0.10 green:0.76 blue:0.34 alpha:0.88]];
        [self.buttonStart
            applyIdleColor:[UIColor colorWithRed:0.68 green:0.12 blue:0.16 alpha:0.52]
              pressedColor:[UIColor colorWithRed:0.94 green:0.22 blue:0.26 alpha:0.88]];
        UIColor* cIdle =
            [UIColor colorWithRed:0.95 green:0.67 blue:0.12 alpha:0.48];
        UIColor* cPressed =
            [UIColor colorWithRed:1.00 green:0.78 blue:0.20 alpha:0.86];
        for (HarkinianPadTouchButton* button in
             @[ self.cUp, self.cDown, self.cLeft, self.cRight ]) {
            [button applyIdleColor:cIdle pressedColor:cPressed];
        }

        self.buttonStart.accessibilityLabel = @"Start";
        self.buttonZRight.accessibilityLabel = @"Z right";
        self.dUp.accessibilityLabel = @"D-pad Up";
        self.dDown.accessibilityLabel = @"D-pad Down";
        self.dLeft.accessibilityLabel = @"D-pad Left";
        self.dRight.accessibilityLabel = @"D-pad Right";
        self.cUp.accessibilityLabel = @"C Up";
        self.cDown.accessibilityLabel = @"C Down";
        self.cLeft.accessibilityLabel = @"C Left";
        self.cRight.accessibilityLabel = @"C Right";

        self.controlStick.accessibilityIdentifier = @"stick";
        self.buttonA.accessibilityIdentifier = @"a";
        self.buttonB.accessibilityIdentifier = @"b";
        self.buttonL.accessibilityIdentifier = @"l";
        self.buttonZRight.accessibilityIdentifier = @"z";
        self.buttonR.accessibilityIdentifier = @"r";
        self.buttonStart.accessibilityIdentifier = @"start";
        self.dUp.accessibilityIdentifier = @"d-up";
        self.dDown.accessibilityIdentifier = @"d-down";
        self.dLeft.accessibilityIdentifier = @"d-left";
        self.dRight.accessibilityIdentifier = @"d-right";
        self.cUp.accessibilityIdentifier = @"c-up";
        self.cDown.accessibilityIdentifier = @"c-down";
        self.cLeft.accessibilityIdentifier = @"c-left";
        self.cRight.accessibilityIdentifier = @"c-right";

        self.buttons = @[
            self.buttonA, self.buttonB, self.buttonL, self.buttonZRight,
            self.buttonR, self.buttonStart,
            self.dUp, self.dDown, self.dLeft, self.dRight, self.cUp, self.cDown,
            self.cLeft, self.cRight,
        ];
        self.editableControls = @[
            self.controlStick, self.buttonA, self.buttonB, self.buttonL,
            self.buttonZRight, self.buttonR, self.buttonStart,
            self.dUp, self.dDown, self.dLeft, self.dRight,
            self.cUp, self.cDown, self.cLeft, self.cRight,
        ];
        self.layoutCenters = [NSMutableDictionary dictionary];
        self.layoutScales = [NSMutableDictionary dictionary];
        self.hiddenControls = [NSMutableSet set];
        self.defaultSizes = [NSMutableDictionary dictionary];
        self.editGestures = [NSMutableArray array];
        self.touchControlsOpacity = 1.0;

        [self addSubview:self.controlStick];
        for (HarkinianPadTouchButton* button in self.buttons) {
            [self addSubview:button];
        }
        [self installLayoutEditor];
    }
    return self;
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    BOOL compact = height < 560.0;

    if (compact) {
        // A phone needs its own grip layout. Scaling the iPad controls down
        // made the face and C buttons smaller than useful touch targets.
        CGFloat left = safe.left + 10.0;
        CGFloat right = safe.right + 10.0;
        CGFloat top = safe.top + 36.0;
        CGFloat shoulderHeight = 44.0;
        CGFloat shoulderWidth = 76.0;

        self.buttonR.frame =
            CGRectMake(width - right - shoulderWidth, top, shoulderWidth, shoulderHeight);
        self.buttonStart.frame =
            CGRectMake(CGRectGetMinX(self.buttonR.frame) - shoulderHeight - 8.0, top, shoulderHeight,
                       shoulderHeight);
        self.buttonL.frame =
            CGRectMake(CGRectGetMinX(self.buttonR.frame), CGRectGetMaxY(self.buttonR.frame) + 8.0,
                       shoulderWidth, shoulderHeight);

        CGFloat dSize = 44.0;
        CGFloat dRadius = 38.0;
        CGPoint dCenter = CGPointMake(left + 54.0, top + shoulderHeight + 80.0);
        self.dUp.frame =
            CGRectMake(dCenter.x - dSize * 0.5, dCenter.y - dRadius - dSize * 0.5, dSize, dSize);
        self.dDown.frame =
            CGRectMake(dCenter.x - dSize * 0.5, dCenter.y + dRadius - dSize * 0.5, dSize, dSize);
        self.dLeft.frame =
            CGRectMake(dCenter.x - dRadius - dSize * 0.5, dCenter.y - dSize * 0.5, dSize, dSize);
        self.dRight.frame =
            CGRectMake(dCenter.x + dRadius - dSize * 0.5, dCenter.y - dSize * 0.5, dSize, dSize);

        CGFloat stickSize = 116.0;
        CGPoint stickCenter =
            CGPointMake(left + 88.0, height - safe.bottom - 88.0);
        self.controlStick.frame =
            CGRectMake(stickCenter.x - stickSize * 0.5, stickCenter.y - stickSize * 0.5, stickSize, stickSize);

        CGFloat rightCenterX = width - right - 58.0;
        CGFloat faceCenterY = height - safe.bottom - 82.0;
        CGFloat faceSize = 52.0;
        self.buttonA.frame =
            CGRectMake(rightCenterX + 22.0 - faceSize * 0.5, faceCenterY + 18.0 - faceSize * 0.5, faceSize,
                       faceSize);
        self.buttonB.frame =
            CGRectMake(rightCenterX - 34.0 - faceSize * 0.5, faceCenterY + 2.0 - faceSize * 0.5, faceSize,
                       faceSize);
        self.buttonZRight.frame =
            CGRectMake(rightCenterX + 12.0 - faceSize * 0.5, faceCenterY - 44.0 - faceSize * 0.5, faceSize,
                       faceSize);

        CGFloat cSize = 40.0;
        CGFloat cRadius = 34.0;
        // Keep conditional C-up/Navi clear of L while preserving the accepted
        // C-button vertical placement.
        CGFloat cCenterX = CGRectGetMinX(self.buttonL.frame) - 8.0 - cSize * 0.5;
        CGPoint cCenter = CGPointMake(cCenterX, top + shoulderHeight + 80.0);
        self.cUp.frame =
            CGRectMake(cCenter.x - cSize * 0.5, cCenter.y - cRadius - cSize * 0.5, cSize, cSize);
        self.cDown.frame =
            CGRectMake(cCenter.x - cSize * 0.5, cCenter.y + cRadius - cSize * 0.5, cSize, cSize);
        self.cLeft.frame =
            CGRectMake(cCenter.x - cRadius - cSize * 0.5, cCenter.y - cSize * 0.5, cSize, cSize);
        self.cRight.frame =
            CGRectMake(cCenter.x + cRadius - cSize * 0.5, cCenter.y - cSize * 0.5, cSize, cSize);

        for (HarkinianPadTouchButton* button in self.buttons) {
            button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        }
        self.buttonStart.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];

        // Promoted from the accepted physical iPhone layout.
        self.cLeft.center = CGPointMake(width * 0.823855, height * 0.485470);
        self.dDown.center = CGPointMake(width * 0.130727, height * 0.501709);
        self.cDown.center = CGPointMake(width * 0.866509, height * 0.570085);
        self.cUp.center = CGPointMake(width * 0.866904, height * 0.398291);
        self.controlStick.center = CGPointMake(width * 0.214455, height * 0.722222);
        self.buttonZRight.center = CGPointMake(width * 0.242496, height * 0.499145);
        self.buttonA.center = CGPointMake(width * 0.876382, height * 0.737607);
        self.cRight.center = CGPointMake(width * 0.911137, height * 0.486325);
        self.buttonB.center = CGPointMake(width * 0.805687, height * 0.664957);

        [self finishControlLayoutForCompact:YES];
        [self publishNativeHudButtonCenters];
        [self applyNativeHudVisualState];
        return;
    }

    CGFloat scale = MAX(0.78, MIN(1.12, height / 834.0));
    CGFloat edge = 18.0 * scale;
    CGFloat right = safe.right + edge;
    CGFloat usableWidth = width - safe.left - safe.right;
    CGFloat railWidth = MIN(250.0 * scale, usableWidth * 0.22);
    CGFloat leftCenter = safe.left + railWidth * 0.5;
    CGFloat rightCenter = width - safe.right - railWidth * 0.5;
    CGFloat middleCenterY = height * 0.60;
    CGFloat lowCenterY = height * 0.86;
    CGFloat stickCenterX = leftCenter + 71.0 * scale;
    CGFloat stickCenterY = lowCenterY - 87.0 * scale;
    CGFloat dpadCenterX = leftCenter - 30.0 * scale;
    CGFloat dpadCenterY = middleCenterY + 5.0 * scale;
    CGFloat faceCenterX = rightCenter - 2.0 * scale;
    CGFloat cCenterX = rightCenter + 8.0 * scale;
    CGFloat faceCenterY = middleCenterY + 58.0 * scale;

    CGFloat stickSize = 150.0 * scale;
    self.controlStick.frame =
        CGRectMake(stickCenterX - stickSize * 0.5, stickCenterY - stickSize * 0.5,
                   stickSize, stickSize);

    CGFloat pillHeight = 54.0 * scale;
    CGFloat shoulderWidth = 106.0 * scale;
    CGFloat dSize = 52.0 * scale;
    CGFloat dRadius = 48.0 * scale;
    CGPoint dCenter = CGPointMake(dpadCenterX, dpadCenterY);
    self.dUp.frame =
        CGRectMake(dCenter.x - dSize * 0.5,
                   dCenter.y - dRadius - dSize * 0.5, dSize, dSize);
    self.dDown.frame =
        CGRectMake(dCenter.x - dSize * 0.5,
                   dCenter.y + dRadius - dSize * 0.5, dSize, dSize);
    self.dLeft.frame =
        CGRectMake(dCenter.x - dRadius - dSize * 0.5,
                   dCenter.y - dSize * 0.5, dSize, dSize);
    self.dRight.frame =
        CGRectMake(dCenter.x + dRadius - dSize * 0.5,
                   dCenter.y - dSize * 0.5, dSize, dSize);

    CGFloat faceSize = 79.2 * scale;
    CGFloat faceX = faceCenterX - faceSize * 0.5;
    self.buttonA.frame =
        CGRectMake(faceX, faceCenterY + 12.0 * scale, faceSize, faceSize);
    self.buttonB.frame =
        CGRectMake(faceX - faceSize - 10.0 * scale,
                   faceCenterY - faceSize * 0.5, faceSize, faceSize);
    self.buttonZRight.frame =
        CGRectMake(faceX, faceCenterY - faceSize - 12.0 * scale,
                   faceSize, faceSize);

    CGFloat cSize = 55.2 * scale;
    CGFloat cRadius = 58.0 * scale;
    CGFloat faceBottom =
        MAX(CGRectGetMaxY(self.buttonA.frame),
            MAX(CGRectGetMaxY(self.buttonB.frame), CGRectGetMaxY(self.buttonZRight.frame)));
    // The enlarged C diamond begins directly below the A/B/Z cluster while
    // retaining separate rectangular hit frames.
    CGFloat cTopGap = 12.0 * scale;
    CGPoint cCenter =
        CGPointMake(cCenterX, faceBottom + cTopGap + cRadius + cSize * 0.5);
    CGFloat cUpDrop = 8.0 * scale;
    self.cUp.frame =
        CGRectMake(cCenter.x - cSize * 0.5,
                   cCenter.y - cRadius - cSize * 0.5 + cUpDrop, cSize, cSize);
    CGFloat cLowerClusterLift = 20.0 * scale;
    self.cDown.frame =
        CGRectMake(cCenter.x - cSize * 0.5,
                   cCenter.y + cRadius - cSize * 0.5 - cLowerClusterLift, cSize, cSize);
    self.cLeft.frame =
        CGRectMake(cCenter.x - cRadius - cSize * 0.5,
                   cCenter.y - cSize * 0.5 - cLowerClusterLift, cSize, cSize);
    self.cRight.frame =
        CGRectMake(cCenter.x + cRadius - cSize * 0.5,
                   cCenter.y - cSize * 0.5 - cLowerClusterLift, cSize, cSize);

    // Keep the shoulder stack above the face cluster: R, then L, then the
    // right-side Z target, with matching gaps and no overlapping hit frames.
    CGFloat shoulderGap = 12.0 * scale;
    CGFloat rightRowY =
        CGRectGetMinY(self.buttonZRight.frame) - pillHeight * 2.0 - shoulderGap * 2.0;
    self.buttonR.frame =
        CGRectMake(width - right - shoulderWidth, rightRowY, shoulderWidth,
                   pillHeight);
    self.buttonStart.frame =
        CGRectMake(CGRectGetMinX(self.buttonR.frame) - pillHeight - shoulderGap,
                   rightRowY, pillHeight, pillHeight);
    self.buttonL.frame =
        CGRectMake(CGRectGetMinX(self.buttonR.frame), CGRectGetMaxY(self.buttonR.frame) + shoulderGap,
                   shoulderWidth, pillHeight);

    CGFloat labelSize = 18.0 * scale;
    for (HarkinianPadTouchButton* button in self.buttons) {
        button.titleLabel.font = [UIFont systemFontOfSize:labelSize weight:UIFontWeightSemibold];
    }
    self.buttonStart.titleLabel.font =
        [UIFont systemFontOfSize:18.0 * scale weight:UIFontWeightBold];

    // Promoted from the accepted physical iPad layout.
    self.cLeft.center = CGPointMake(width * 0.856515, height * 0.853922);
    self.cDown.center = CGPointMake(width * 0.902240, height * 0.905152);
    self.cUp.center = CGPointMake(width * 0.903338, height * 0.805484);
    self.controlStick.center = CGPointMake(width * 0.164363, height * 0.745313);
    self.buttonZRight.center = CGPointMake(width * 0.193089, height * 0.612859);
    self.buttonA.center = CGPointMake(width * 0.893309, height * 0.693020);
    self.cRight.center = CGPointMake(width * 0.948331, height * 0.852945);
    self.buttonB.center = CGPointMake(width * 0.826029, height * 0.635117);

    [self finishControlLayoutForCompact:NO];
    [self publishNativeHudButtonCenters];
    [self applyNativeHudVisualState];
}

- (void)setCustomizableControlsEnabled:(BOOL)enabled {
    if (self.customizableControls == enabled) {
        return;
    }
    [self cancelAllInputs];
    self.customizableControls = enabled;
    self.buttonZRight.holdToLatch = enabled;
    if (!enabled && self.layoutEditing) {
        [self endLayoutEditing];
    }
    [self setNeedsLayout];
}

- (void)setTouchControlsOpacity:(CGFloat)opacity {
    _touchControlsOpacity = std::clamp(opacity, 0.25, 1.0);
    [self setNeedsLayout];
}

- (UIButton*)editorButtonWithTitle:(NSString*)title action:(SEL)action {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    button.layer.cornerRadius = 10.0;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)installLayoutEditor {
    self.editorPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.editorPanel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.88];
    self.editorPanel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.24].CGColor;
    self.editorPanel.layer.borderWidth = 1.0;
    self.editorPanel.layer.cornerRadius = 16.0;
    self.editorPanel.hidden = YES;

    self.editorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.editorLabel.textColor = UIColor.whiteColor;
    self.editorLabel.numberOfLines = 2;
    self.editorLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [self.editorPanel addSubview:self.editorLabel];

    self.sizeSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.sizeSlider.minimumValue = 0.70f;
    self.sizeSlider.maximumValue = 1.50f;
    self.sizeSlider.value = 1.0f;
    self.sizeSlider.minimumTrackTintColor =
        [UIColor colorWithRed:0.28 green:0.68 blue:1.0 alpha:1.0];
    [self.sizeSlider addTarget:self
                        action:@selector(editorSizeChanged:)
              forControlEvents:UIControlEventValueChanged];
    [self.editorPanel addSubview:self.sizeSlider];

    self.visibilityButton =
        [self editorButtonWithTitle:@"Hide" action:@selector(toggleSelectedVisibility)];
    self.resetButton =
        [self editorButtonWithTitle:@"Reset" action:@selector(resetCurrentLayout)];
    self.doneButton =
        [self editorButtonWithTitle:@"Done" action:@selector(endLayoutEditing)];
    self.doneButton.backgroundColor =
        [UIColor colorWithRed:0.10 green:0.48 blue:0.92 alpha:0.88];
    self.resetButton.accessibilityIdentifier = @"touch-layout-reset";
    self.doneButton.accessibilityIdentifier = @"touch-layout-done";
    [self.editorPanel addSubview:self.visibilityButton];
    [self.editorPanel addSubview:self.resetButton];
    [self.editorPanel addSubview:self.doneButton];
    [self addSubview:self.editorPanel];

    for (UIView* control in self.editableControls) {
        UIPanGestureRecognizer* pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveControl:)];
        UITapGestureRecognizer* tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(selectControlGesture:)];
        pan.enabled = NO;
        tap.enabled = NO;
        [control addGestureRecognizer:pan];
        [control addGestureRecognizer:tap];
        [self.editGestures addObject:pan];
        [self.editGestures addObject:tap];
    }
}

- (void)layoutEditorPanel {
    if (self.editorPanel.hidden) {
        return;
    }
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat width = CGRectGetWidth(self.bounds);
    BOOL compact = CGRectGetHeight(self.bounds) < 560.0;
    CGFloat panelWidth =
        MIN(width - safe.left - safe.right - (compact ? 8.0 : 16.0),
            compact ? 560.0 : 720.0);
    CGFloat panelHeight = compact ? 50.0 : 86.0;
    self.editorPanel.frame =
        CGRectMake(CGRectGetMidX(self.bounds) - panelWidth * 0.5,
                   safe.top + (compact ? 4.0 : 8.0), panelWidth, panelHeight);
    self.editorPanel.layer.cornerRadius = compact ? 12.0 : 16.0;

    CGFloat inset = compact ? 5.0 : 12.0;
    CGFloat buttonWidth = compact ? 54.0 : 70.0;
    CGFloat gap = compact ? 4.0 : 8.0;
    CGFloat contentHeight = panelHeight - inset * 2.0;
    CGFloat trailingButtonsWidth = buttonWidth * 3.0 + gap * 2.0;
    CGFloat labelWidth = compact ? 94.0 : MIN(150.0, panelWidth * 0.23);
    CGFloat sliderX = inset + labelWidth + gap;
    CGFloat sliderWidth =
        panelWidth - inset * 2.0 - labelWidth - gap - trailingButtonsWidth - gap;
    self.editorLabel.numberOfLines = compact ? 1 : 2;
    self.editorLabel.font =
        [UIFont systemFontOfSize:(compact ? 11.0 : 14.0) weight:UIFontWeightSemibold];
    self.editorLabel.frame = CGRectMake(inset, inset, labelWidth, contentHeight);
    self.sizeSlider.frame =
        CGRectMake(sliderX, inset, MAX(80.0, sliderWidth), contentHeight);

    CGFloat buttonX = panelWidth - inset - trailingButtonsWidth;
    for (UIButton* button in
         @[ self.visibilityButton, self.resetButton, self.doneButton ]) {
        button.titleLabel.font =
            [UIFont systemFontOfSize:(compact ? 12.0 : 14.0) weight:UIFontWeightSemibold];
        button.layer.cornerRadius = compact ? 8.0 : 10.0;
        button.frame = CGRectMake(buttonX, inset, buttonWidth, contentHeight);
        buttonX += buttonWidth + gap;
    }
}

- (NSString*)profileForCompact:(BOOL)compact {
    return compact ? @"phone-v1" : @"tablet-v1";
}

- (NSString*)storageKeyForProfile:(NSString*)profile {
    return [@"HarkinianPad.TouchLayout." stringByAppendingString:profile];
}

- (void)loadLayoutForProfile:(NSString*)profile {
    if ([self.layoutProfile isEqualToString:profile]) {
        return;
    }
    self.layoutProfile = profile;
    [self.layoutCenters removeAllObjects];
    [self.layoutScales removeAllObjects];
    [self.hiddenControls removeAllObjects];

    NSDictionary* stored =
        [NSUserDefaults.standardUserDefaults
            dictionaryForKey:[self storageKeyForProfile:profile]];
    NSDictionary* centers = stored[@"centers"];
    NSDictionary* scales = stored[@"scales"];
    NSArray* hidden = stored[@"hidden"];
    if ([centers isKindOfClass:NSDictionary.class]) {
        [self.layoutCenters addEntriesFromDictionary:centers];
    }
    if ([scales isKindOfClass:NSDictionary.class]) {
        [self.layoutScales addEntriesFromDictionary:scales];
    }
    if ([hidden isKindOfClass:NSArray.class]) {
        [self.hiddenControls addObjectsFromArray:hidden];
    }
}

- (void)saveCurrentLayout {
    if (self.layoutProfile.length == 0) {
        return;
    }
    NSDictionary* stored = @{
        @"centers": [self.layoutCenters copy],
        @"scales": [self.layoutScales copy],
        @"hidden": self.hiddenControls.allObjects,
    };
    [NSUserDefaults.standardUserDefaults
        setObject:stored
           forKey:[self storageKeyForProfile:self.layoutProfile]];
}

- (void)clampControlToSafeBounds:(UIView*)control {
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat halfWidth = CGRectGetWidth(control.bounds) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(control.bounds) * 0.5;
    CGFloat minX = safe.left + halfWidth + 4.0;
    CGFloat maxX = CGRectGetWidth(self.bounds) - safe.right - halfWidth - 4.0;
    CGFloat minY = safe.top + halfHeight + 4.0;
    CGFloat maxY = CGRectGetHeight(self.bounds) - safe.bottom - halfHeight - 4.0;
    control.center = CGPointMake(
        std::clamp(control.center.x, minX, MAX(minX, maxX)),
        std::clamp(control.center.y, minY, MAX(minY, maxY)));
}

- (void)finishControlLayoutForCompact:(BOOL)compact {
    if (!self.customizableControls) {
        for (UIView* control in self.editableControls) {
            control.hidden = NO;
            control.alpha = self.touchControlsOpacity;
            control.layer.shadowOpacity = 0.0;
        }
        [self layoutEditorPanel];
        return;
    }

    [self loadLayoutForProfile:[self profileForCompact:compact]];
    [self.defaultSizes removeAllObjects];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    for (UIView* control in self.editableControls) {
        NSString* key = control.accessibilityIdentifier;
        if (key.length == 0) {
            continue;
        }
        CGSize defaultSize = control.bounds.size;
        self.defaultSizes[key] = [NSValue valueWithCGSize:defaultSize];
        CGFloat scale = self.layoutScales[key] == nil
            ? 1.0
            : std::clamp(self.layoutScales[key].doubleValue, 0.70, 1.50);
        control.bounds =
            CGRectMake(0.0, 0.0, defaultSize.width * scale, defaultSize.height * scale);
        NSArray<NSNumber*>* center = self.layoutCenters[key];
        if ([center isKindOfClass:NSArray.class] && center.count == 2) {
            control.center =
                CGPointMake(center[0].doubleValue * width, center[1].doubleValue * height);
        }
        [self clampControlToSafeBounds:control];
        BOOL hidden = [self.hiddenControls containsObject:key];
        control.hidden = self.layoutEditing ? NO : hidden;
        control.alpha = self.layoutEditing ? (hidden ? 0.28 : 1.0) : self.touchControlsOpacity;
        BOOL selected = self.layoutEditing && control == self.selectedControl;
        control.layer.shadowColor =
            [UIColor colorWithRed:1.0 green:0.78 blue:0.16 alpha:1.0].CGColor;
        control.layer.shadowRadius = selected ? 8.0 : 0.0;
        control.layer.shadowOpacity = selected ? 1.0 : 0.0;
        control.layer.shadowOffset = CGSizeZero;
    }
    [self layoutEditorPanel];
    [self bringSubviewToFront:self.editorPanel];
}

- (void)selectControl:(UIView*)control {
    if (!self.layoutEditing || control == nil) {
        return;
    }
    self.selectedControl = control;
    NSString* label = control.accessibilityLabel;
    if (label.length == 0) {
        label = control.accessibilityIdentifier;
    }
    BOOL compact = CGRectGetHeight(self.bounds) < 560.0;
    self.editorLabel.text =
        compact ? [NSString stringWithFormat:@"%@ • Drag • Size", label]
                : [NSString stringWithFormat:@"%@\nDrag to move • Size", label];
    NSString* key = control.accessibilityIdentifier;
    self.sizeSlider.value =
        self.layoutScales[key] == nil ? 1.0f : self.layoutScales[key].floatValue;
    BOOL hidden = [self.hiddenControls containsObject:key];
    [self.visibilityButton setTitle:(hidden ? @"Show" : @"Hide")
                           forState:UIControlStateNormal];
    self.visibilityButton.enabled = ![key isEqualToString:@"stick"];
    self.visibilityButton.alpha = self.visibilityButton.enabled ? 1.0 : 0.4;
    [self setNeedsLayout];
}

- (void)selectControlGesture:(UITapGestureRecognizer*)gesture {
    [self selectControl:gesture.view];
}

- (void)moveControl:(UIPanGestureRecognizer*)gesture {
    UIView* control = gesture.view;
    if (!self.layoutEditing || control == nil) {
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self selectControl:control];
    }
    CGPoint translation = [gesture translationInView:self];
    control.center =
        CGPointMake(control.center.x + translation.x, control.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self];
    [self clampControlToSafeBounds:control];
    self.layoutCenters[control.accessibilityIdentifier] = @[
        @(control.center.x / CGRectGetWidth(self.bounds)),
        @(control.center.y / CGRectGetHeight(self.bounds)),
    ];
}

- (void)editorSizeChanged:(UISlider*)slider {
    UIView* control = self.selectedControl;
    NSString* key = control.accessibilityIdentifier;
    NSValue* sizeValue = self.defaultSizes[key];
    if (control == nil || key.length == 0 || sizeValue == nil) {
        return;
    }
    CGFloat scale = slider.value;
    self.layoutScales[key] = @(scale);
    CGSize baseSize = sizeValue.CGSizeValue;
    control.bounds =
        CGRectMake(0.0, 0.0, baseSize.width * scale, baseSize.height * scale);
    [self clampControlToSafeBounds:control];
    self.layoutCenters[key] = @[
        @(control.center.x / CGRectGetWidth(self.bounds)),
        @(control.center.y / CGRectGetHeight(self.bounds)),
    ];
}

- (void)toggleSelectedVisibility {
    NSString* key = self.selectedControl.accessibilityIdentifier;
    if (key.length == 0 || [key isEqualToString:@"stick"]) {
        return;
    }
    if ([self.hiddenControls containsObject:key]) {
        [self.hiddenControls removeObject:key];
    } else {
        [self.hiddenControls addObject:key];
    }
    [self selectControl:self.selectedControl];
}

- (void)resetCurrentLayout {
    if (self.layoutProfile.length == 0) {
        return;
    }
    [self.layoutCenters removeAllObjects];
    [self.layoutScales removeAllObjects];
    [self.hiddenControls removeAllObjects];
    [NSUserDefaults.standardUserDefaults
        removeObjectForKey:[self storageKeyForProfile:self.layoutProfile]];
    [self setNeedsLayout];
    [self selectControl:self.buttonA];
}

- (void)beginLayoutEditing {
    if (!self.customizableControls || self.layoutEditing) {
        return;
    }
    [self cancelAllInputs];
    self.layoutEditing = YES;
    for (HarkinianPadTouchButton* button in self.buttons) {
        button.layoutEditing = YES;
    }
    self.controlStick.layoutEditing = YES;
    for (UIGestureRecognizer* gesture in self.editGestures) {
        gesture.enabled = YES;
    }
    self.editorPanel.hidden = NO;
    sLayoutEditorActive.store(true);
    sMenuButton.hidden = YES;
    [self applyNativeHudVisualState];
    [self selectControl:self.buttonA];
    [self setNeedsLayout];
    SDL_Log("[HarkinianPad] touch layout editor opened");
}

- (void)endLayoutEditing {
    if (!self.layoutEditing) {
        return;
    }
    [self saveCurrentLayout];
    self.layoutEditing = NO;
    for (HarkinianPadTouchButton* button in self.buttons) {
        button.layoutEditing = NO;
    }
    self.controlStick.layoutEditing = NO;
    for (UIGestureRecognizer* gesture in self.editGestures) {
        gesture.enabled = NO;
    }
    self.editorPanel.hidden = YES;
    self.selectedControl = nil;
    sLayoutEditorActive.store(false);
    sMenuButton.hidden = NO;
    [self setNeedsLayout];
    SDL_Log("[HarkinianPad] touch layout saved");
}

- (void)publishNativeHudButtonCenters {
    const CGFloat width = CGRectGetWidth(self.bounds);
    const CGFloat height = CGRectGetHeight(self.bounds);
    if (width <= 0.0 || height <= 0.0) {
        return;
    }

    NSArray<HarkinianPadTouchButton*>* nativeButtons = @[
        self.buttonA, self.buttonB, self.cUp, self.cDown, self.cLeft, self.cRight,
    ];
    for (NSUInteger index = 0; index < nativeButtons.count; index++) {
        if (nativeButtons[index].hidden && !self.layoutEditing) {
            sNativeHudButtonCenters[index][0].store(0.0f);
            sNativeHudButtonCenters[index][1].store(0.0f);
            sNativeHudButtonWidths[index].store(0.0f);
            continue;
        }
        const CGPoint center = nativeButtons[index].center;
        sNativeHudButtonCenters[index][0].store(center.x / width);
        sNativeHudButtonCenters[index][1].store(center.y / height);
        sNativeHudButtonWidths[index].store(CGRectGetWidth(nativeButtons[index].frame) / height);
    }
}

- (void)applyNativeHudVisualState {
    const BOOL hideUIKitFaceButtons =
        sTouchControlsDesired.load() && sNativeHudTouchDesired.load() &&
        sNativeHudTouchGameplayActive.load() && !sTouchControlsMenuVisible.load() &&
        !sLayoutEditorActive.load();
    for (HarkinianPadTouchButton* button in
         @[ self.buttonA, self.buttonB, self.cUp, self.cDown, self.cLeft, self.cRight ]) {
        // Hide only UIKit's artwork. The button itself stays fully opaque and
        // interactive so touches cannot fall through to SDL's mouse mapping.
        button.nativeHudArtworkHidden = hideUIKitFaceButtons;
    }
}

- (void)cancelAllInputs {
    [self.controlStick cancelInput];
    for (HarkinianPadTouchButton* button in self.buttons) {
        [button cancelInput];
    }
}

@end

static HarkinianPadTouchOverlay* sTouchOverlay;
static BOOL sLifecycleObserversInstalled;

static UIWindow* HarkinianPad_ActiveWindow(void) {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static void HarkinianPad_InstallMenuButton(UIWindow* window) {
    if (sMenuButton == nil) {
        sMenuButton =
            [[HarkinianPadTouchButton alloc] initWithLabel:@"•••" scancode:SDL_SCANCODE_ESCAPE pill:NO];
        sMenuButton.accessibilityLabel = @"Menu";
        sMenuButton.titleLabel.font =
            [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        [sMenuButton
            applyIdleColor:[UIColor colorWithWhite:0.04 alpha:0.42]
              pressedColor:[UIColor colorWithWhite:0.72 alpha:0.62]];
        sMenuButton.autoresizingMask =
            UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    }

    const UIEdgeInsets safe = window.safeAreaInsets;
    const CGFloat height = CGRectGetHeight(window.bounds);
    const BOOL compact = height < 560.0;
    const CGFloat size = compact ? 44.0 : 38.0;
    if (compact) {
        const BOOL menuVisible = sTouchControlsMenuVisible.load();
        const CGFloat y =
            menuVisible ? height - safe.bottom - size - 8.0
                        : safe.top + 8.0;
        sMenuButton.frame =
            CGRectMake(CGRectGetMidX(window.bounds) - size * 0.5, y, size, size);
        sMenuButton.autoresizingMask =
            UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
            (menuVisible ? UIViewAutoresizingFlexibleTopMargin : UIViewAutoresizingFlexibleBottomMargin);
    } else {
        sMenuButton.frame =
            CGRectMake(CGRectGetWidth(window.bounds) - safe.right - size - 8.0,
                       safe.top + 8.0, size, size);
        sMenuButton.autoresizingMask =
            UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    }
    if (sMenuButton.superview != window) {
        [sMenuButton removeFromSuperview];
        [window addSubview:sMenuButton];
    }
    sMenuButton.alpha = sTouchControlsOpacity.load();
    [window bringSubviewToFront:sMenuButton];
}

static void HarkinianPad_InstallLifecycleObservers(void) {
    if (sLifecycleObserversInstalled) {
        return;
    }
    sLifecycleObserversInstalled = YES;
    NSNotificationCenter* notifications = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in
         @[ UIApplicationWillResignActiveNotification,
            UIApplicationDidEnterBackgroundNotification ]) {
        [notifications addObserverForName:name
                                   object:nil
                                    queue:NSOperationQueue.mainQueue
                               usingBlock:^(NSNotification* notification) {
                                   (void)notification;
                                   [sTouchOverlay cancelAllInputs];
                               }];
    }
}

static void HarkinianPad_ApplyTouchControlsState(void) {
    UIWindow* window = HarkinianPad_ActiveWindow();
    if (window == nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           HarkinianPad_ApplyTouchControlsState();
                       });
        return;
    }

    HarkinianPad_InstallMenuButton(window);
    if (!sTouchControlsDesired.load() || sTouchControlsMenuVisible.load()) {
        if (sTouchOverlay.layoutEditing) {
            [sTouchOverlay endLayoutEditing];
        }
        [sTouchOverlay cancelAllInputs];
        [sTouchOverlay removeFromSuperview];
        sTouchOverlay = nil;
        if (!sTouchControlsDesired.load()) {
            sLayoutEditorRequested = NO;
        }
        return;
    }

    if (sTouchOverlay == nil) {
        sTouchOverlay = [[HarkinianPadTouchOverlay alloc] initWithFrame:window.bounds];
        sTouchOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    [sTouchOverlay
        setCustomizableControlsEnabled:sCustomizableTouchControlsDesired.load()];
    [sTouchOverlay setTouchControlsOpacity:sTouchControlsOpacity.load()];
    if (sTouchOverlay.superview != window) {
        [sTouchOverlay removeFromSuperview];
        sTouchOverlay.frame = window.bounds;
        [window addSubview:sTouchOverlay];
    }
    if (sLayoutEditorRequested && sCustomizableTouchControlsDesired.load()) {
        sLayoutEditorRequested = NO;
        [sTouchOverlay beginLayoutEditing];
    }
    [sTouchOverlay applyNativeHudVisualState];
    [window bringSubviewToFront:sTouchOverlay];
    if (!sLayoutEditorActive.load()) {
        [window bringSubviewToFront:sMenuButton];
    }
}

int HarkinianPad_TouchControlsAvailable(void) {
    return 1;
}

void HarkinianPad_SetTouchControlsEnabled(int enabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        HarkinianPad_InstallLifecycleObservers();
        sTouchControlsDesired.store(enabled != 0);
        HarkinianPad_ApplyTouchControlsState();
    });
}

void HarkinianPad_SetCustomizableTouchControlsEnabled(int enabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        const BOOL customizable = enabled != 0;
        sCustomizableTouchControlsDesired.store(customizable);
        if (!customizable) {
            sLayoutEditorRequested = NO;
        }
        [sTouchOverlay setCustomizableControlsEnabled:customizable];
        HarkinianPad_ApplyTouchControlsState();
    });
}

void HarkinianPad_SetTouchControlsOpacity(float opacity) {
    const float clampedOpacity = std::clamp(opacity, 0.25f, 1.0f);
    sTouchControlsOpacity.store(clampedOpacity);
    dispatch_async(dispatch_get_main_queue(), ^{
        [sTouchOverlay setTouchControlsOpacity:clampedOpacity];
        UIWindow* window = HarkinianPad_ActiveWindow();
        if (window != nil) {
            HarkinianPad_InstallMenuButton(window);
        }
    });
}

void HarkinianPad_BeginTouchLayoutEditing(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sTouchControlsDesired.load() ||
            !sCustomizableTouchControlsDesired.load()) {
            SDL_Log("[HarkinianPad] customizable touch controls are disabled");
            return;
        }
        sLayoutEditorRequested = YES;
        if (sTouchControlsMenuVisible.load()) {
            HarkinianPad_PushKey(SDL_SCANCODE_ESCAPE, YES);
            HarkinianPad_PushKey(SDL_SCANCODE_ESCAPE, NO);
        } else {
            HarkinianPad_ApplyTouchControlsState();
        }
    });
}

void HarkinianPad_SetTouchControlsMenuVisible(int visible) {
    const bool menuVisible = visible != 0;
    if (sTouchControlsMenuVisible.exchange(menuVisible) == menuVisible) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        HarkinianPad_ApplyTouchControlsState();
    });
}

void HarkinianPad_SetNativeHudTouchEnabled(int enabled) {
    sNativeHudTouchDesired.store(enabled != 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [sTouchOverlay setNeedsLayout];
        [sTouchOverlay layoutIfNeeded];
        [sTouchOverlay applyNativeHudVisualState];
        UIWindow* window = HarkinianPad_ActiveWindow();
        if (window != nil) {
            HarkinianPad_InstallMenuButton(window);
        }
    });
}

void HarkinianPad_SetNativeHudTouchGameplayActive(int active) {
    const bool gameplayActive = active != 0;
    if (sNativeHudTouchGameplayActive.exchange(gameplayActive) == gameplayActive) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [sTouchOverlay setNeedsLayout];
        [sTouchOverlay layoutIfNeeded];
        [sTouchOverlay applyNativeHudVisualState];
        UIWindow* window = HarkinianPad_ActiveWindow();
        if (window != nil) {
            HarkinianPad_InstallMenuButton(window);
        }
    });
}

int HarkinianPad_GetNativeHudButtonCenter(int button, float aspectRatio, float* x, float* y) {
    if (button < 0 || button >= HARKINIANPAD_HUD_BUTTON_COUNT || x == nullptr || y == nullptr ||
        aspectRatio <= 0.0f || !sTouchControlsDesired.load() || !sNativeHudTouchDesired.load() ||
        !sNativeHudTouchGameplayActive.load() || sTouchControlsMenuVisible.load() ||
        sLayoutEditorActive.load()) {
        return 0;
    }

    const float normalizedX = sNativeHudButtonCenters[button][0].load();
    const float normalizedY = sNativeHudButtonCenters[button][1].load();
    if (normalizedX <= 0.0f || normalizedX >= 1.0f || normalizedY <= 0.0f || normalizedY >= 1.0f) {
        return 0;
    }

    const float virtualWidth = 240.0f * aspectRatio;
    const float virtualLeft = 160.0f - virtualWidth * 0.5f;
    *x = virtualLeft + normalizedX * virtualWidth;
    *y = normalizedY * 240.0f;
    return 1;
}

float HarkinianPad_GetNativeHudButtonScale(int button, float aspectRatio) {
    if (button < 0 || button >= HARKINIANPAD_HUD_BUTTON_COUNT || aspectRatio <= 0.0f ||
        !sTouchControlsDesired.load() || !sNativeHudTouchDesired.load() ||
        !sNativeHudTouchGameplayActive.load() || sTouchControlsMenuVisible.load() ||
        sLayoutEditorActive.load()) {
        return 1.0f;
    }

    // C-up/Navi is natively drawn at 16 points; the other C buttons use
    // their 27-point draw size.
    static const float nativeButtonWidths[] = {
        29.0f, 30.0f, 16.0f, 27.0f, 27.0f, 27.0f,
    };
    const float normalizedWidth = sNativeHudButtonWidths[button].load();
    if (normalizedWidth <= 0.0f || normalizedWidth >= 1.0f) {
        return 1.0f;
    }

    const float virtualWidth = normalizedWidth * 240.0f;
    return virtualWidth / nativeButtonWidths[button];
}

int HarkinianPad_GetNativeHudTouchAlpha(int alpha) {
    const bool nativeTouchArtworkVisible =
        sTouchControlsDesired.load() && sNativeHudTouchDesired.load() &&
        sNativeHudTouchGameplayActive.load() && !sTouchControlsMenuVisible.load() &&
        !sLayoutEditorActive.load();
    if (!nativeTouchArtworkVisible) {
        return std::clamp(alpha, 0, 255);
    }
    return std::clamp(static_cast<int>(alpha * sTouchControlsOpacity.load() + 0.5f), 0, 255);
}
