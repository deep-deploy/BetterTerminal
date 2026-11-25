//
//  ViewController.m
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import "TerminalViewController.h"
#import "AppDelegate.h"
#import "TerminalView.h"
#import "BarButton.h"
#import "ArrowBarButton.h"
#import "UserPreferences.h"
#import "AboutViewController.h"
#import "NSObject+SaneKVO.h"
#import "LinuxInterop.h"
#import <objc/runtime.h>

static char BTSessionPIDKey;
#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "fs/devices.h"

@interface TerminalViewController () <UIGestureRecognizerDelegate>

@property UITapGestureRecognizer *tapRecognizer;
@property (weak, nonatomic) IBOutlet TerminalView *termView;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *bottomConstraint;

@property (weak, nonatomic) IBOutlet UIButton *tabKey;
@property (weak, nonatomic) IBOutlet UIButton *controlKey;
@property (weak, nonatomic) IBOutlet UIButton *escapeKey;
@property (strong, nonatomic) IBOutletCollection(id) NSArray *barButtons;
@property (strong, nonatomic) IBOutletCollection(id) NSArray *barControls;

@property (weak, nonatomic) IBOutlet UIInputView *barView;
@property (weak, nonatomic) IBOutlet UIStackView *bar;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barTop;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barBottom;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barLeading;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barTrailing;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barButtonWidth;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barHeight;

@property (weak, nonatomic) IBOutlet UIButton *infoButton;
@property (weak, nonatomic) IBOutlet UIButton *pasteButton;
@property (weak, nonatomic) IBOutlet UIButton *hideKeyboardButton;

// BetterTerminal native tabs v0.2
@property (nonatomic) NSMutableArray<Terminal *> *btTabs;
@property (nonatomic) NSMutableDictionary<NSUUID *, NSNumber *> *btPids;
@property (nonatomic) NSMutableDictionary<NSUUID *, NSString *> *btNames;
@property (nonatomic) NSUInteger btNextNumber;
@property (nonatomic) UIStackView *btTabStack;
@property (nonatomic) UIScrollView *btTabScroll;
@property (nonatomic) UIButton *btAddButton;

@property int sessionPid;
@property (nonatomic) Terminal *sessionTerminal;

@property BOOL ignoreKeyboardMotion;
@property (nonatomic) BOOL hasExternalKeyboard;

@end

@implementation TerminalViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    if (@available(iOS 15.0, *)) {
        self.bottomConstraint.active = NO;
        [self.termView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor].active = YES;
    }

#if !ISH_LINUX
    int bootError = [AppDelegate bootError];
    if (bootError < 0) {
        NSString *message = [NSString stringWithFormat:@"could not boot"];
        NSString *subtitle = [NSString stringWithFormat:@"error code %d", bootError];
        if (bootError == _EINVAL)
            subtitle = [subtitle stringByAppendingString:@"\n(try reinstalling the app, see release notes for details)"];
        [self showMessage:message subtitle:subtitle];
        NSLog(@"boot failed with code %d", bootError);
    }
#endif

    [self btInstallTabs];
    self.terminal = self.terminal;
    [self.termView becomeFirstResponder];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(keyboardDidSomething:)
                   name:UIKeyboardWillChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(keyboardDidSomething:)
                   name:UIKeyboardDidChangeFrameNotification
                 object:nil];
    [self _updateStyleFromPreferences:NO];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        [self.bar removeArrangedSubview:self.hideKeyboardButton];
        [self.hideKeyboardButton removeFromSuperview];
    }
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        self.barHeight.constant = 36;
    } else {
        self.barHeight.constant = 43;
    }
    
    // SF Symbols is cool
    if (@available(iOS 13, *)) {
        [self.infoButton setImage:[UIImage systemImageNamed:@"gear"] forState:UIControlStateNormal];
        [self.pasteButton setImage:[UIImage systemImageNamed:@"doc.on.clipboard"] forState:UIControlStateNormal];
        [self.hideKeyboardButton setImage:[UIImage systemImageNamed:@"keyboard.chevron.compact.down"] forState:UIControlStateNormal];
        
        [self.tabKey setTitle:nil forState:UIControlStateNormal];
        [self.tabKey setImage:[UIImage systemImageNamed:@"arrow.right.to.line.alt"] forState:UIControlStateNormal];
        [self.controlKey setTitle:nil forState:UIControlStateNormal];
        [self.controlKey setImage:[UIImage systemImageNamed:@"control"] forState:UIControlStateNormal];
        [self.escapeKey setTitle:nil forState:UIControlStateNormal];
        [self.escapeKey setImage:[UIImage systemImageNamed:@"escape"] forState:UIControlStateNormal];
    }
    
    [UserPreferences.shared observe:@[@"hideStatusBar"] options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setNeedsStatusBarAppearanceUpdate];
        });
    }];
    [UserPreferences.shared observe:@[@"colorScheme", @"theme", @"hideExtraKeysWithExternalKeyboard"]
                            options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateStyleFromPreferences:YES];
        });
    }];
}

- (void)awakeFromNib {
    [super awakeFromNib];
#if !ISH_LINUX
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(processExited:)
                                               name:ProcessExitedNotification
                                             object:nil];
#else
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(kernelPanicked:)
                                               name:KernelPanicNotification
                                             object:nil];
#endif
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

- (void)startNewSession {
    [self btEnsureTabs];
    Terminal *previous = self.sessionTerminal;
    Terminal *previousDisplay = self.terminal;
    int previousPid = self.sessionPid;
    int err = [self startSession];
    if (err < 0 || !self.sessionTerminal) {
        Terminal *failed = self.sessionTerminal;
        self.sessionTerminal = previous;
        self.sessionPid = previousPid;
        if (self.terminal != previousDisplay) self.terminal = previousDisplay;
        if (failed && failed != previous) [failed destroy];
        NSLog(@"could not start session: %d", err);
        [self showMessage:@"could not start session"
                 subtitle:[NSString stringWithFormat:@"error code %d", err]];
        return;
    }
    [self btRememberTerminal:self.sessionTerminal pid:self.sessionPid];
    [self btActivateTerminal:self.sessionTerminal];
}

- (void)reconnectSessionFromTerminalUUID:(NSUUID *)uuid {
    Terminal *terminal = uuid ? [Terminal terminalWithUUID:uuid] : nil;
    if (!terminal) {
        [self startNewSession];
        return;
    }
    NSNumber *pid = objc_getAssociatedObject(terminal, &BTSessionPIDKey);
    [self btRememberTerminal:terminal pid:pid.intValue];
    [self btActivateTerminal:terminal];
}

- (NSUUID *)sessionTerminalUUID {
    return self.sessionTerminal.uuid;
}

#pragma mark BetterTerminal native tabs

- (void)btEnsureTabs {
    if (self.btTabs != nil) return;
    self.btTabs = [NSMutableArray array];
    self.btPids = [NSMutableDictionary dictionary];
    self.btNames = [NSMutableDictionary dictionary];
    self.btNextNumber = 1;
}

- (void)btRememberTerminal:(Terminal *)terminal pid:(int)pid {
    if (!terminal) return;
    [self btEnsureTabs];
    if (![self.btTabs containsObject:terminal]) {
        [self.btTabs addObject:terminal];
        self.btNames[terminal.uuid] = [NSString stringWithFormat:@"Terminal %lu", (unsigned long)self.btNextNumber++];
    }
    if (pid > 0) {
        self.btPids[terminal.uuid] = @(pid);
        objc_setAssociatedObject(terminal, &BTSessionPIDKey, @(pid), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)btInstallTabs {
    if (self.btTabStack) return;
    [self btEnsureTabs];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *oldTop = nil;
    for (NSLayoutConstraint *constraint in self.view.constraints) {
        if (constraint.firstItem == self.termView && constraint.firstAttribute == NSLayoutAttributeTop &&
            constraint.secondItem == safe && constraint.secondAttribute == NSLayoutAttributeTop) {
            oldTop = constraint;
            break;
        }
    }
    if (!oldTop) {
        NSLog(@"BetterTerminal: terminal top constraint missing; tabs not installed");
        return;
    }
    UIColor *background = [UIColor colorWithRed:0.043 green:0.067 blue:0.067 alpha:1];
    UIColor *accent = [UIColor colorWithRed:0 green:0.90 blue:0.60 alpha:1];
    UIView *strip = [UIView new];
    strip.translatesAutoresizingMaskIntoConstraints = NO;
    strip.backgroundColor = background;
    [self.view addSubview:strip];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceVertical = NO;
    scroll.directionalLockEnabled = YES;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [strip addSubview:scroll];
    self.btTabScroll = scroll;

    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 6;
    [scroll addSubview:stack];
    self.btTabStack = stack;

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.translatesAutoresizingMaskIntoConstraints = NO;
    [add setTitle:@"+" forState:UIControlStateNormal];
    add.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightMedium];
    add.tintColor = accent;
    add.accessibilityLabel = @"New terminal tab";
    [add addTarget:self action:@selector(btAddTab:) forControlEvents:UIControlEventTouchUpInside];
    [strip addSubview:add];
    self.btAddButton = add;

    oldTop.active = NO;
    [NSLayoutConstraint activateConstraints:@[
        [strip.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [strip.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [strip.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [strip.heightAnchor constraintEqualToConstant:46],
        [self.termView.topAnchor constraintEqualToAnchor:strip.bottomAnchor],
        [add.trailingAnchor constraintEqualToAnchor:strip.trailingAnchor constant:-4],
        [add.topAnchor constraintEqualToAnchor:strip.topAnchor],
        [add.bottomAnchor constraintEqualToAnchor:strip.bottomAnchor],
        [add.widthAnchor constraintEqualToConstant:44],
        [scroll.leadingAnchor constraintEqualToAnchor:strip.leadingAnchor constant:6],
        [scroll.trailingAnchor constraintEqualToAnchor:add.leadingAnchor constant:-4],
        [scroll.topAnchor constraintEqualToAnchor:strip.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:strip.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor]
    ]];
    [self btRefreshTabs];
}

- (void)btRefreshTabs {
    if (!self.btTabStack) return;
    for (UIView *view in [self.btTabStack.arrangedSubviews copy]) {
        [self.btTabStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    UIColor *accent = [UIColor colorWithRed:0 green:0.90 blue:0.60 alpha:1];
    UIButton *selectedButton = nil;
    for (NSUInteger i = 0; i < self.btTabs.count; i++) {
        Terminal *terminal = self.btTabs[i];
        BOOL selected = self.terminal == terminal;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = (NSInteger)i;
        NSString *name = self.btNames[terminal.uuid] ?: @"Terminal";
        [button setTitle:name forState:UIControlStateNormal];
        [button setTitleColor:selected ? accent : [UIColor colorWithWhite:0.78 alpha:1] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:selected ? UIFontWeightSemibold : UIFontWeightRegular];
        button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        button.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
        button.backgroundColor = selected ? [UIColor colorWithRed:0.08 green:0.23 blue:0.18 alpha:1] : [UIColor colorWithWhite:0.13 alpha:1];
        button.layer.cornerRadius = 8;
        button.accessibilityLabel = name;
        button.accessibilityHint = @"Double tap to switch. Touch and hold for tab options.";
        if (selected) {
            button.accessibilityTraits |= UIAccessibilityTraitSelected;
            selectedButton = button;
        }
        [button addTarget:self action:@selector(btSelectTab:) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(btTabOptions:)];
        [button addGestureRecognizer:hold];
        [self.btTabStack addArrangedSubview:button];
        [button.heightAnchor constraintEqualToConstant:34].active = YES;
        [button.widthAnchor constraintLessThanOrEqualToConstant:180].active = YES;
    }
    self.btAddButton.enabled = self.btTabs.count < 8;
    [self.view layoutIfNeeded];
    if (selectedButton) {
        CGRect frame = [selectedButton convertRect:selectedButton.bounds toView:self.btTabScroll];
        [self.btTabScroll scrollRectToVisible:CGRectInset(frame, -4, 0) animated:NO];
    }
}

- (void)btActivateTerminal:(Terminal *)terminal {
    if (!terminal || ![self.btTabs containsObject:terminal]) return;
    self.sessionTerminal = terminal;
    self.sessionPid = [self.btPids[terminal.uuid] intValue];
    if (self.terminal != terminal) self.terminal = terminal;
    [self btRefreshTabs];
}

- (void)btAddTab:(id)sender {
    [self btEnsureTabs];
    if (self.btTabs.count >= 8) {
        [self showMessage:@"Tab limit reached" subtitle:@"Close a tab before creating another."];
        return;
    }
    [self startNewSession];
}

- (void)btSelectTab:(UIButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.btTabs.count) return;
    [self btActivateTerminal:self.btTabs[(NSUInteger)sender.tag]];
}

- (void)btRenameTerminal:(Terminal *)terminal {
    if (![self.btTabs containsObject:terminal]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename tab" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = self.btNames[terminal.uuid];
        field.placeholder = @"Tab name";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) self = weakSelf;
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (self && name.length && [self.btTabs containsObject:terminal]) {
            self.btNames[terminal.uuid] = name;
            [self btRefreshTabs];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)btRemoveTerminal:(Terminal *)terminal hangup:(BOOL)hangup {
    NSUInteger index = [self.btTabs indexOfObjectIdenticalTo:terminal];
    if (index == NSNotFound) return;
    BOOL wasActive = self.sessionTerminal == terminal;
    [self.btTabs removeObjectAtIndex:index];
    [self.btNames removeObjectForKey:terminal.uuid];
    [self.btPids removeObjectForKey:terminal.uuid];
    if (wasActive) {
        self.sessionTerminal = nil;
        self.sessionPid = 0;
        if (self.btTabs.count) {
            [self btActivateTerminal:self.btTabs[MIN(index, self.btTabs.count - 1)]];
        }
    }
    if (hangup) [terminal destroy];
    [self btRefreshTabs];
}

- (void)btTabOptions:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSInteger index = gesture.view.tag;
    if (index < 0 || (NSUInteger)index >= self.btTabs.count) return;
    Terminal *terminal = self.btTabs[(NSUInteger)index];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:self.btNames[terminal.uuid] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [menu addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf btRenameTerminal:terminal];
    }]];
    if (self.btTabs.count > 1) {
        [menu addAction:[UIAlertAction actionWithTitle:@"Close tab…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            typeof(self) self = weakSelf;
            if (!self) return;
            UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Close terminal?" message:@"Running jobs in this tab may be terminated." preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
                typeof(self) self = weakSelf;
                if (self.btTabs.count > 1) [self btRemoveTerminal:terminal hangup:YES];
            }]];
            [self presentViewController:confirm animated:YES completion:nil];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (menu.popoverPresentationController) {
        menu.popoverPresentationController.sourceView = gesture.view;
        menu.popoverPresentationController.sourceRect = gesture.view.bounds;
    }
    [self presentViewController:menu animated:YES completion:nil];
}



- (int)startSession {
    NSArray<NSString *> *command = UserPreferences.shared.launchCommand;
    if (command.count == 0) {
        NSLog(@"terminal session launch command is empty");
        return _EINVAL;
    }
    NSLog(@"starting terminal session with command: %@", [command componentsJoinedByString:@" "]);

#if !ISH_LINUX
    int err = become_new_init_child();
    if (err < 0)
        return err;
    struct tty *tty;
    self.sessionTerminal = nil;
    Terminal *terminal = [Terminal createPseudoTerminal:&tty];
    if (terminal == nil) {
        NSAssert(IS_ERR(tty), @"tty should be error");
        return (int) PTR_ERR(tty);
    }
    self.sessionTerminal = terminal;
    NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
    err = create_stdio(stdioFile.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    if (err < 0)
        return err;
    tty_release(tty);

    char argv[4096];
    [Terminal convertCommand:command toArgs:argv limitSize:sizeof(argv)];
    const char *envp = "TERM=xterm-256color\0"
#if defined(GUEST_ARM64)
        "PYTHONMALLOC=malloc\0"
#endif
        ;
    err = do_execve(command[0].UTF8String, command.count, argv, envp);
    if (err < 0)
        return err;
    self.sessionPid = current->pid;
    NSLog(@"started terminal session pid %d on %@", self.sessionPid, stdioFile);
    err = task_start(current);
    if (err < 0) {
        task_discard_unstarted(current);
        current = NULL;
        self.sessionPid = 0;
        return err;
    }
#else
    const char *argv_arr[command.count + 1];
    for (NSUInteger i = 0; i < command.count; i++)
        argv_arr[i] = command[i].UTF8String;
    argv_arr[command.count] = NULL;
    const char *envp_arr[] = {
        "TERM=xterm-256color",
        NULL,
    };
    const char *const *argv = argv_arr;
    const char *const *envp = envp_arr;
    __block Terminal *terminal = nil;
    __block int sessionPid = 0;
    __block int err = 1;
    sync_do_in_workqueue(^(void (^done)(void)) {
        linux_start_session(argv[0], argv, envp, ^(int retval, int pid, nsobj_t term) {
            err = retval;
            if (term)
                terminal = CFBridgingRelease(term);
            sessionPid = pid;
            done();
        });
    });
    NSAssert(err <= 0, @"session start did not finish??");
    if (err < 0)
        return err;
    self.sessionTerminal = terminal;
    self.sessionPid = sessionPid;
    NSLog(@"started terminal session pid %d", self.sessionPid);
#endif
    return 0;
}

#if !ISH_LINUX
- (void)processExited:(NSNotification *)notif {
    int pid = [notif.userInfo[@"pid"] intValue];
    Terminal *exited = nil;
    for (Terminal *terminal in self.btTabs) {
        if (pid > 0 && [self.btPids[terminal.uuid] intValue] == pid) {
            exited = terminal;
            break;
        }
    }
    if (!exited) return;
    int code = [notif.userInfo[@"code"] intValue];
    NSLog(@"terminal session pid %d exited with code %d", pid, code);
    [self btRemoveTerminal:exited hangup:YES];
    current = NULL; // original session-exit cleanup
    if (self.btTabs.count == 0) [self startNewSession];
}
#endif

#if ISH_LINUX
- (void)kernelPanicked:(NSNotification *)notif {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"panik" message:notif.userInfo[@"message"] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"k" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
#endif

- (void)showMessage:(NSString *)message subtitle:(NSString *)subtitle {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:message message:subtitle preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"k"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == [UserPreferences shared]) {
        [self _updateStyleFromPreferences:YES];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)_updateStyleFromPreferences:(BOOL)animated {
    NSAssert(NSThread.isMainThread, @"This method needs to be called on the main thread");
    NSTimeInterval duration = animated ? 0.1 : 0;
    [UIView animateWithDuration:duration animations:^{
        self.view.backgroundColor = [[UIColor alloc] ish_initWithHexString:UserPreferences.shared.palette.backgroundColor];
        UIKeyboardAppearance keyAppearance = UserPreferences.shared.keyboardAppearance;
        self.termView.keyboardAppearance = keyAppearance;
        for (BarButton *button in self.barButtons) {
            button.keyAppearance = keyAppearance;
        }
        UIColor *tintColor = keyAppearance == UIKeyboardAppearanceLight ? UIColor.blackColor : UIColor.whiteColor;
        for (UIControl *control in self.barControls) {
            control.tintColor = tintColor;
        }
    }];
    UIView *oldBarView = self.termView.inputAccessoryView;
    if (UserPreferences.shared.hideExtraKeysWithExternalKeyboard && self.hasExternalKeyboard) {
        self.termView.inputAccessoryView = nil;
    } else {
        self.termView.inputAccessoryView = self.barView;
    }
    if (self.termView.inputAccessoryView != oldBarView && self.termView.isFirstResponder) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.ignoreKeyboardMotion = YES; // avoid infinite recursion
            [self.termView reloadInputViews];
            self.ignoreKeyboardMotion = NO;
        });
    }
}
- (void)_updateStyleAnimated {
    [self _updateStyleFromPreferences:YES];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UserPreferences.shared.statusBarStyle;
}

- (BOOL)prefersStatusBarHidden {
    return UserPreferences.shared.hideStatusBar;
}

- (void)keyboardDidSomething:(NSNotification *)notification {
    if (self.ignoreKeyboardMotion)
        return;

    CGRect screenKeyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
    // notification.object is nil before iOS 16.1 and the correct UIScreen after iOS 16.1
    if ([notification.object isKindOfClass:UIScreen.class])
        screen = notification.object;
    CGRect keyboardFrame = [self.view convertRect:screenKeyboardFrame fromCoordinateSpace:screen.coordinateSpace];
    if (CGRectEqualToRect(keyboardFrame, CGRectZero))
        return;
    CGRect intersection = CGRectIntersection(keyboardFrame, self.view.bounds);
    BOOL intersects = !CGRectIsNull(intersection) && !CGRectIsEmpty(intersection);
    self.hasExternalKeyboard = !intersects || intersection.size.height < 100;
    if (@available(iOS 15.0, *))
        return; // UIKit's layout guide handles keyboard movement and safe areas.

    keyboardFrame = intersects ? intersection : CGRectZero;
    CGFloat pad = self.view.safeAreaInsets.bottom;
    // The keyboard appears to be undocked. This means it can either be split or
    // truly floating. In the former case we want to keep the pad, but in the
    // latter we should fall back to the input accessory view instead of the
    // keyboard.
    if (intersects) {
        pad = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboardFrame);
    }
    if (intersects && pad != keyboardFrame.size.height && keyboardFrame.size.width != self.view.bounds.size.width) {
        pad = MAX(self.view.safeAreaInsets.bottom, self.termView.inputAccessoryView.frame.size.height);
    }
    self.bottomConstraint.constant = pad;

    BOOL initialLayout = self.termView.needsUpdateConstraints;
    [self.view setNeedsUpdateConstraints];
    if (!initialLayout) {
        // if initial layout hasn't happened yet, the terminal view is going to be at a really weird place, so animating it is going to look really bad
        NSNumber *interval = notification.userInfo[UIKeyboardAnimationDurationUserInfoKey];
        NSNumber *curve = notification.userInfo[UIKeyboardAnimationCurveUserInfoKey];
        [UIView animateWithDuration:interval.doubleValue
                              delay:0
                            options:curve.integerValue << 16
                         animations:^{
                             [self.view layoutIfNeeded];
                         }
                         completion:nil];
    }
}

- (void)setHasExternalKeyboard:(BOOL)hasExternalKeyboard {
    _hasExternalKeyboard = hasExternalKeyboard;
    [self _updateStyleFromPreferences:YES];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"embed"]) {
        // You might want to check if this is your embed segue here
        // in case there are other segues triggered from this view controller.
        segue.destinationViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    // Hack to resolve a layering mismatch between the UI and preferences.
    if (@available(iOS 12.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            // Ensure that the relevant things listening for this will update.
            UserPreferences.shared.colorScheme = UserPreferences.shared.colorScheme;
        }
    }
}

#pragma mark Bar

- (IBAction)showAbout:(id)sender {
    UINavigationController *navigationController = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
    if ([sender isKindOfClass:[UIGestureRecognizer class]]) {
        UIGestureRecognizer *recognizer = sender;
        if (recognizer.state == UIGestureRecognizerStateBegan) {
            AboutViewController *aboutViewController = (AboutViewController *) navigationController.topViewController;
            aboutViewController.includeDebugPanel = YES;
        } else {
            return;
        }
    }
    [self presentViewController:navigationController animated:YES completion:nil];
    [self.termView resignFirstResponder];
}

- (void)resizeBar {
    CGSize bar = self.barView.bounds.size;
    // set sizing parameters on bar
    // numbers stolen from iVim and modified somewhat
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        // phone
        [self setBarHorizontalPadding:6 verticalPadding:6 buttonWidth:32];
    } else if (bar.width >= 450) {
        // wide ipad
        [self setBarHorizontalPadding:15 verticalPadding:8 buttonWidth:43];
    } else {
        // narrow ipad (slide over)
        [self setBarHorizontalPadding:10 verticalPadding:8 buttonWidth:36];
    }
    [UIView performWithoutAnimation:^{
        [self.barView layoutIfNeeded];
    }];
}

- (void)setBarHorizontalPadding:(CGFloat)horizontal verticalPadding:(CGFloat)vertical buttonWidth:(CGFloat)buttonWidth {
    self.barLeading.constant = self.barTrailing.constant = horizontal;
    self.barTop.constant = self.barBottom.constant = vertical;
    self.barButtonWidth.constant = buttonWidth;
}

- (IBAction)pressEscape:(id)sender {
    [self pressKey:@"\x1b"];
}
- (IBAction)pressTab:(id)sender {
    [self pressKey:@"\t"];
}
- (void)pressKey:(NSString *)key {
    [self.termView insertText:key];
}

- (IBAction)pressControl:(id)sender {
    self.controlKey.selected = !self.controlKey.selected;
}
    
- (IBAction)pressArrow:(ArrowBarButton *)sender {
    switch (sender.direction) {
        case ArrowUp: [self pressKey:[self.terminal arrow:'A']]; break;
        case ArrowDown: [self pressKey:[self.terminal arrow:'B']]; break;
        case ArrowLeft: [self pressKey:[self.terminal arrow:'D']]; break;
        case ArrowRight: [self pressKey:[self.terminal arrow:'C']]; break;
        case ArrowNone: break;
    }
}

- (void)switchTerminal:(UIKeyCommand *)sender {
    unsigned i = (unsigned) sender.input.integerValue;
    if (i == 7)
        self.terminal = self.sessionTerminal;
    else
        self.terminal = [Terminal terminalWithType:TTY_CONSOLE_MAJOR number:i];
    [self btRefreshTabs];
}

- (void)increaseFontSize:(UIKeyCommand *)command {
    self.termView.overrideFontSize = self.termView.effectiveFontSize + 1;
}
- (void)decreaseFontSize:(UIKeyCommand *)command {
    self.termView.overrideFontSize = self.termView.effectiveFontSize - 1;
}
- (void)resetFontSize:(UIKeyCommand *)command {
    self.termView.overrideFontSize = 0;
}

- (NSArray<UIKeyCommand *> *)keyCommands {
    static NSMutableArray<UIKeyCommand *> *commands = nil;
    if (commands == nil) {
        commands = [NSMutableArray new];
        for (unsigned i = 1; i <= 7; i++) {
            [commands addObject:
             [UIKeyCommand keyCommandWithInput:[NSString stringWithFormat:@"%d", i]
                                 modifierFlags:UIKeyModifierCommand|UIKeyModifierAlternate|UIKeyModifierShift
                                        action:@selector(switchTerminal:)]];
        }
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"+"
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(increaseFontSize:)
                      discoverabilityTitle:@"Increase Font Size"]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"="
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(increaseFontSize:)]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"-"
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(decreaseFontSize:)
                      discoverabilityTitle:@"Decrease Font Size"]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"0"
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(resetFontSize:)
                      discoverabilityTitle:@"Reset Font Size"]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@","
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(showAbout:)
                      discoverabilityTitle:@"Settings"]];
    }
    // Keep existing shortcuts; Command-T opens a native shell tab.
    return [commands arrayByAddingObject:[UIKeyCommand keyCommandWithInput:@"t"
        modifierFlags:UIKeyModifierCommand action:@selector(btAddTab:)
        discoverabilityTitle:@"New Terminal Tab"]];
}

- (void)setTerminal:(Terminal *)terminal {
    _terminal = terminal;
    self.termView.terminal = self.terminal;
}

- (void)setSessionTerminal:(Terminal *)sessionTerminal {
    if (_terminal == _sessionTerminal)
        self.terminal = sessionTerminal;
    _sessionTerminal = sessionTerminal;
}

@end

@interface BarView : UIInputView
@property (weak) IBOutlet TerminalViewController *terminalViewController;
@property (nonatomic) IBInspectable BOOL allowsSelfSizing;
@end
@implementation BarView
@dynamic allowsSelfSizing;

- (void)layoutSubviews {
    [self.terminalViewController resizeBar];
}

@end
