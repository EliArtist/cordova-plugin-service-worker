/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

/* Foundation included so this module can be unit tested in swift*/
#import <Cordova/CDV.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <CommonCrypto/CommonDigest.h>
#import "CDVServiceWorker.h"
#import "FetchConnectionDelegate.h"
#import "FetchInterceptorProtocol.h"
#import "ServiceWorkerRequest.h"

static bool isServiceWorkerActive = NO;


NSString * const SERVICE_WORKER = @"serviceworker";
NSString * const SERVICE_WORKER_SCOPE = @"serviceworkerscope";
NSString * const SERVICE_WORKER_ACTIVATED = @"ServiceWorkerActivated";
NSString * const SERVICE_WORKER_INSTALLED = @"ServiceWorkerInstalled";
NSString * const SERVICE_WORKER_SCRIPT_CHECKSUM = @"ServiceWorkerScriptChecksum";

NSString * const REGISTER_OPTIONS_KEY_SCOPE = @"scope";

NSString * const REGISTRATION_KEY_ACTIVE = @"active";
NSString * const REGISTRATION_KEY_INSTALLING = @"installing";
NSString * const REGISTRATION_KEY_REGISTERING_SCRIPT_URL = @"registeringScriptURL";
NSString * const REGISTRATION_KEY_SCOPE = @"scope";
NSString * const REGISTRATION_KEY_WAITING = @"waiting";

NSString * const SERVICE_WORKER_KEY_SCRIPT_URL = @"scriptURL";

@implementation CDVServiceWorker

@synthesize context = _context;
@synthesize workerWebView = _workerWebView;
@synthesize registration = _registration;
@synthesize requestDelegates = _requestDelegates;
@synthesize requestQueue = _requestQueue;
@synthesize serviceWorkerScriptFilename = _serviceWorkerScriptFilename;
@synthesize initiateHandler = _initiateHandler;
@synthesize isServiceWorkerActive = _isServiceWorkerActive;


- (NSString *)hashForString:(NSString *)string
{
    const char *cstring = [string UTF8String];
    size_t length = strlen(cstring);

    // We're assuming below that CC_LONG is an unsigned int; fail here if that's not true.
    assert(sizeof(CC_LONG) == sizeof(unsigned int));

    unsigned char hash[33];

    CC_MD5_CTX hashContext;

    // We'll almost certainly never see >4GB files, but loop with UINT32_MAX sized-chunks just to be correct
    CC_MD5_Init(&hashContext);
    CC_LONG dataToHash;
    while (length != 0) {
        if (length > UINT32_MAX) {
            dataToHash = UINT32_MAX;
            length -= UINT32_MAX;
        } else {
            dataToHash = (CC_LONG)length;
            length = 0;
        }
        CC_MD5_Update(&hashContext, cstring, dataToHash);
        cstring += dataToHash;
    }
    CC_MD5_Final(hash, &hashContext);

    // Construct a simple base-16 representation of the hash for comparison
    for (int i=15; i >= 0; --i) {
        hash[i*2+1] = 'a' + (hash[i] & 0x0f);
        hash[i*2] = 'a' + ((hash[i] >> 4) & 0x0f);
    }
    // Null-terminate
    hash[32] = 0;

    return [NSString stringWithCString:(char *)hash
                                          encoding:NSUTF8StringEncoding];
}

CDVServiceWorker * singletonInstance = nil;
+ (CDVServiceWorker *)instanceForRequest:(NSURLRequest *)request
{
    return isServiceWorkerActive ? singletonInstance : nil;
}

+ (CDVServiceWorker *)getSingletonInstance
{
    if (singletonInstance == nil) {
        singletonInstance = [[CDVServiceWorker alloc] init];
    }
    return singletonInstance;
}

- (void)onReset {
    NSLog(@"CDVServiceWorker.onReset");
}

- (void)pluginInitialize
{
    NSLog(@"CDVServiceWorker.pluginInitialize");
    // TODO: Make this better; probably a registry
    singletonInstance = self;

    self.requestDelegates = [[NSMutableDictionary alloc] initWithCapacity:10];
    self.requestQueue = [NSMutableArray new];

    [NSURLProtocol registerClass:[FetchInterceptorProtocol class]];


    self.workerWebView = [[WKWebView alloc] init]; // Headless
    [self.workerWebView.configuration.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
    [self registerForJavascriptMessages];

    [self.viewController.view addSubview:self.workerWebView];
//    [self.workerWebView setDelegate:self];
    
    [self.workerWebView setUIDelegate:self];
    [self.workerWebView setNavigationDelegate:self];
    
    NSURL* bundleURL = [NSURL fileURLWithPath:[[NSBundle mainBundle] bundlePath]];
    NSURL* swShellURL = [bundleURL URLByAppendingPathComponent: @"www/sw_assets/sw.html"];
    NSLog(@"loadFileURL %@", [swShellURL absoluteString]);
    [self.workerWebView loadFileURL:swShellURL allowingReadAccessToURL:bundleURL];
}

-(void) registerForJavascriptMessages
{
    WKUserContentController *controller = self.workerWebView.configuration.userContentController;
    [controller addScriptMessageHandler:self name:@"log"];
    [controller addScriptMessageHandler:self name:@"installServiceWorkerCallback"];
    [controller addScriptMessageHandler:self name:@"activateServiceWorkerCallback"];
    [controller addScriptMessageHandler:self name:@"fetchResponse"];
    [controller addScriptMessageHandler:self name:@"fetchDefault"];
    [controller addScriptMessageHandler:self name:@"trueFetch"];
    [controller addScriptMessageHandler:self name:@"postMessage"];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
    NSString *handlerName = [self handlerNameForMessage:message];
    //TODO Figure out why choosing selector by name is not working
    //    SEL s = NSSelectorFromString(handlerName);
    //    [self performSelector:s withObject: message];
    
    if ([handlerName isEqualToString:@"handleLogScriptMessage"]) {
        [self handleLogScriptMessage:message];
    } else if ([handlerName isEqualToString:@"handleInstallServiceWorkerCallbackScriptMessage"]) {
         [self handleInstallServiceWorkerCallbackScriptMessage:message];
    } else if ([handlerName isEqualToString:@"handleActivateServiceWorkerCallbackScriptMessage"]) {
         [self handleActivateServiceWorkerCallbackScriptMessage:message];
    } else if ([handlerName isEqualToString:@"handleFetchResponseScriptMessage"]) {
         [self handleFetchResponseScriptMessage:message];
    } else if ([handlerName isEqualToString:@"handleTrueFetchScriptMessage"]) {
         [self handleTrueFetchScriptMessage:message];
    } else if ([handlerName isEqualToString:@"handleFetchDefaultScriptMessage"]) {
         [self handleFetchDefaultScriptMessage:message];
    } else if ([handlerName isEqualToString:@"handlePostMessageScriptMessage"]) {
         [self handlePostMessageScriptMessage:message];
    } else {
        NSLog(@"DidReceiveScriptMessage %@", handlerName);
    }
}


- (void) sendResultToWorker:(NSNumber*) messageId parameters:(NSDictionary *)parameters
{
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:parameters options:NSJSONWritingPrettyPrinted error:&error];
    NSString *parameterString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString* cordovaCallbackScript = [NSString stringWithFormat:@"cordovaCallback(%@, %@);", messageId, parameterString];
    [self.workerWebView evaluateJavaScript:cordovaCallbackScript completionHandler:^(id result, NSError *error) {
        if (error != nil) {
            NSLog(@"Failed to run cordovaCallback due to error %@", [error localizedDescription]);
            NSLog(@"Script: %@", cordovaCallbackScript);
        }
    }];
}

- (void) sendResultToWorker:(NSNumber*) messageId parameters:(NSDictionary *)parameters withError: (NSError*) error {
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:parameters options:NSJSONWritingPrettyPrinted error:&error];
    NSString *parameterString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString* cordovaCallbackScript = [NSString stringWithFormat:@"cordovaCallback(%@, %@, %@);", messageId, parameterString, error];
    [self.workerWebView evaluateJavaScript:cordovaCallbackScript completionHandler:^(id result, NSError *error) {
        if (error != nil) {
            NSLog(@"Failed to run cordovaCallback due to error %@", [error localizedDescription]);
            NSLog(@"Script: %@", cordovaCallbackScript);
        }
    }];
}

- (NSString *) handlerNameForMessage: (WKScriptMessage *) message {
    NSString *upperName = [[[message name] substringToIndex: 1] uppercaseString];
    upperName = [upperName stringByAppendingString:[[message name] substringFromIndex: 1]];
    return [NSString stringWithFormat: @"handle%@ScriptMessage", upperName];
}

- (void)handleLogScriptMessage: (WKScriptMessage *) message
{
    NSLog(@"JS:SW %@", message.body);
}

- (void)handleInstallServiceWorkerCallbackScriptMessage: (WKScriptMessage *) message
{
    NSLog(@"Service Worker was installed. Trying to activate...");
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:SERVICE_WORKER_INSTALLED];
    [self activateServiceWorker];
}

- (void)handleActivateServiceWorkerCallbackScriptMessage: (WKScriptMessage *) message
{
    NSLog(@"Service Worker was activated. Trying to initiate...");
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:SERVICE_WORKER_ACTIVATED];
    [self initiateServiceWorker];
}

- (void)handleFetchResponseScriptMessage: (WKScriptMessage *) message
{
    NSDictionary *body = [message body];
    NSDictionary *response = [body valueForKey: @"response"];
    NSString *jsRequestId = [body valueForKey: @"requestId"];
//    [formatter numberFromString:[jsRequestId toString]]
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
//    NSNumber *requestId = [formatter numberFromString:[jsRequestId toString]];
    NSNumber *requestId = [formatter numberFromString:jsRequestId];
    FetchInterceptorProtocol *interceptor = (FetchInterceptorProtocol *)[self.requestDelegates objectForKey:jsRequestId];
    [self.requestDelegates removeObjectForKey:requestId];

    // Convert the response body to base64.
//        NSData *data = [NSData dataFromBase64String:[response[@"body"] toString]];
//        NSData *data = [NSData dataFromBase64String:[response[@"body"] toString]];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:[response[@"body"] toString] options:0];
    JSValue *headers = response[@"headers"];
    NSString *mimeType = [headers[@"mimeType"] toString];
    NSString *encoding = @"utf-8";
    NSString *url = [response[@"url"] toString]; // TODO: Can this ever be different than the request url? if not, don't allow it to be overridden

    NSURLResponse *urlResponse = [[NSURLResponse alloc] initWithURL:[NSURL URLWithString:url]
                                                        MIMEType:mimeType
                                           expectedContentLength:data.length
                                                textEncodingName:encoding];

    [interceptor handleAResponse:urlResponse withSomeData:data];
}

- (void)handleTrueFetchScriptMessage: (WKScriptMessage *) message
{
    NSDictionary *body = [message body];
    NSNumber *messageId = [body valueForKey:@"messageId"];
    NSString *url = [body valueForKey:@"url"];
    NSString *method = [body valueForKey:@"method"];
    NSDictionary *headers = [body valueForKey:@"headers"];
    NSDictionary *headersDict = [headers valueForKey:@"headerDict"];
    NSLog(@"handleTrueFetch: %@", url);

    if (headersDict != nil) {
        headers = headersDict;
    }
//    NSString *resourceUrlString = [resourceUrl toString];

    NSLog(@"handleTrueFetch: %@", url);
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *internalUrlString = url;


    if (![url containsString:@"://"]) {
        internalUrlString = [NSString stringWithFormat:@"/%@/www/%@", [[NSBundle mainBundle] resourcePath], url];
        if (![fileManager fileExistsAtPath:internalUrlString]) {
            url = [NSString stringWithFormat:@"%@%@", _clientUrl, url];
            NSLog(@"File roes not exist in local fs. Requesting remotely from: %@", url);
        } else {
            url = [NSString stringWithFormat:@"file://%@/www/%@", [[NSBundle mainBundle] resourcePath], url];
        }
    }
//
    // Create the request.
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString: url]];
    [request setHTTPMethod:method];
    if (headers != nil) {
        if ([NSThread isMainThread]) {
            [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL* stop) {
                if([value isKindOfClass:[NSArray class]]){
                    value = [value objectAtIndex:0];
                }
                [request addValue:value forHTTPHeaderField:key];
            }];
        } else {
            [NSThread performSelectorOnMainThread:@selector(enumerateKeysAndObjectsUsingBlock:) withObject:^(NSString *key, NSString *value, BOOL* stop) {
                [request addValue:value forHTTPHeaderField:key];
            } waitUntilDone:NO];
        }
    };

    
    [NSURLProtocol setProperty:@YES forKey:@"PureFetch" inRequest:request];

    // Create a connection and send the request.
    FetchConnectionDelegate *delegate = [FetchConnectionDelegate new];
    delegate.resolve = ^(ServiceWorkerResponse *response) {
        NSDictionary *responseDict = [response toDictionary];
        [self sendResultToWorker:messageId parameters: responseDict];
    };
    delegate.reject = ^(NSError *error) {
        [self sendResultToWorker:messageId parameters: nil withError: error];
    };
    [NSURLConnection connectionWithRequest:request delegate:delegate];
}


- (void)handleFetchDefaultScriptMessage: (WKScriptMessage *) message {
    NSDictionary *body = [message body];
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    NSString *jsRequestId = [body valueForKey:@"requestId"];
    [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
    NSNumber *requestId = [formatter numberFromString:jsRequestId];
    FetchInterceptorProtocol *interceptor = (FetchInterceptorProtocol *)[self.requestDelegates objectForKey:requestId];
    [self.requestDelegates removeObjectForKey:requestId];
    [interceptor passThrough];
}

- (void)handlePostMessageScriptMessage: (WKScriptMessage *) message {
    NSString *body = [message body];
    NSString *postMessageCode = [NSString stringWithFormat:@"window.postMessage(Kamino.parse('%@'), '*')", body];

    if ([self.webView isKindOfClass:[WKWebView class]]) {
        [self.webView performSelectorOnMainThread:@selector(evaluateScript:) withObject:postMessageCode waitUntilDone:NO];
    } else {
        [self.webView performSelectorOnMainThread:@selector(stringByEvaluatingJavaScriptFromString:) withObject:postMessageCode waitUntilDone:NO];
    }
    
}

# pragma mark ServiceWorker Functions

- (void)register:(CDVInvokedUrlCommand*)command
{
    NSString *scriptUrl = [command argumentAtIndex:0];
//    NSDictionary *options = [command argumentAtIndex:1];
    NSString *absoluteScriptUrl = [command argumentAtIndex:2];
    NSString *clientURL = [absoluteScriptUrl stringByReplacingOccurrencesOfString:scriptUrl   withString:@""];
    NSLog(@"Register service worker: %@ (for client: %@)", scriptUrl, clientURL);
    
    
    if (clientURL != nil) {
        NSString *setBaseURLCode = [NSString stringWithFormat: @"window.mainClientURL = '%@';", clientURL];
        [self evaluateScript: setBaseURLCode];
    }


    // The script url must be at the root.
    // TODO: Look into supporting non-root ServiceWorker scripts.
    if ([scriptUrl containsString:@"/"]) {
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                          messageAsString:@"The script URL must be at the root."];
        [[self commandDelegate] sendPluginResult:pluginResult callbackId:[command callbackId]];
    }

    // The provided scope is ignored; we always set it to the root.
    // TODO: Support provided scopes.
    NSString *scopeUrl = @"/";

    // If we have a registration on record, make sure it matches the attempted registration.
    // If it matches, return it.  If it doesn't, we have a problem!
    // If we don't have a registration on record, create one, store it, and return it.
    if (self.registration != nil) {
        if (![[self.registration valueForKey:REGISTRATION_KEY_REGISTERING_SCRIPT_URL] isEqualToString:scriptUrl]) {
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                              messageAsString:[NSString stringWithFormat:@"The script URL doesn't match the existing registration. existing: %@  new: %@", self.serviceWorkerScriptFilename, scriptUrl]];
            [[self commandDelegate] sendPluginResult:pluginResult callbackId:[command callbackId]];
        } else if (![[self.registration valueForKey:REGISTRATION_KEY_SCOPE] isEqualToString:scopeUrl]) {
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                              messageAsString:@"The scope URL doesn't match the existing registration."];
            [[self commandDelegate] sendPluginResult:pluginResult callbackId:[command callbackId]];
        }
    } else {
//        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
//        bool serviceWorkerInstalled = [defaults boolForKey:SERVICE_WORKER_INSTALLED];
//        bool serviceWorkerActivated = [defaults boolForKey:SERVICE_WORKER_ACTIVATED];
        NSString *serviceWorkerScriptRelativePath = [NSString stringWithFormat:@"www/%@", scriptUrl];
//        NSString *serviceWorkerScriptChecksum = [defaults stringForKey:SERVICE_WORKER_SCRIPT_CHECKSUM];
        NSString *serviceWorkerScript = [self readScriptAtRelativePath:serviceWorkerScriptRelativePath];
        if (serviceWorkerScript != nil) {
//            if (![[self hashForString:serviceWorkerScript] isEqualToString:serviceWorkerScriptChecksum]) {
                NSLog(@"Create Service Worker: %@", serviceWorkerScriptRelativePath);
                [self createServiceWorkerFromScript:absoluteScriptUrl clientUrl:clientURL];
                [self createServiceWorkerClientWithUrl:clientURL];
                [self createServiceWorkerRegistrationWithScriptUrl:scriptUrl scopeUrl:scopeUrl];
            CDVServiceWorker * __weak weakSelf = self;
            [self installServiceWorker: ^() {
                CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:weakSelf.registration];
                [[weakSelf commandDelegate] sendPluginResult:pluginResult callbackId:[command callbackId]];
            }];
//            } else {
//                NSLog(@"ServiceWorker is already registered and contains no changes: %@", serviceWorkerScriptRelativePath);
//            }
        } else {
            NSLog(@"ServiceWorker script is empty: %@", serviceWorkerScriptRelativePath);
        }
    }

    // Return the registration.
//    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:self.registration];
//    [[self commandDelegate] sendPluginResult:pluginResult callbackId:[command callbackId]];
}

- (void)createServiceWorkerRegistrationWithScriptUrl:(NSString*)scriptUrl scopeUrl:(NSString*)scopeUrl
{
    NSDictionary *serviceWorker = [NSDictionary dictionaryWithObject:scriptUrl forKey:SERVICE_WORKER_KEY_SCRIPT_URL];
    // TODO: Add a state to the ServiceWorker object.

    NSArray *registrationKeys = @[REGISTRATION_KEY_INSTALLING,
                                  REGISTRATION_KEY_WAITING,
                                  REGISTRATION_KEY_ACTIVE,
                                  REGISTRATION_KEY_REGISTERING_SCRIPT_URL,
                                  REGISTRATION_KEY_SCOPE];
    NSArray *registrationObjects = @[[NSNull null], [NSNull null], serviceWorker, scriptUrl, scopeUrl];
    self.registration = [NSDictionary dictionaryWithObjects:registrationObjects forKeys:registrationKeys];
}

- (void)serviceWorkerReady:(CDVInvokedUrlCommand*)command
{
    // The provided scope is ignored; we always set it to the root.
    // TODO: Support provided scopes.
    NSString *scopeUrl = @"/";
    NSString *scriptUrl = self.serviceWorkerScriptFilename;

    if (isServiceWorkerActive) {
        NSLog(@"Service Worker is active. Completing registration");
        if (self.registration == nil) {
            [self createServiceWorkerRegistrationWithScriptUrl:scriptUrl scopeUrl:scopeUrl];
        }
        // Return the registration.
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:self.registration];
        [[self commandDelegate] sendPluginResult:pluginResult callbackId:[command callbackId]];
    } else {
        NSLog(@"Service Worker is NOT active. Unable to complete registration");
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                          messageAsString:@"No Service Worker is currently active."];
        [[self commandDelegate] sendPluginResult:pluginResult callbackId:[command callbackId]];
    }
}


- (void)postMessage:(CDVInvokedUrlCommand*)command
{
    NSString *message = [command argumentAtIndex:0];

    // Fire a message event in the JSContext.
    NSString *dispatchCode = [NSString stringWithFormat:@"dispatchEvent(new MessageEvent({data:Kamino.parse('%@')}));", message];
    [self evaluateScript:dispatchCode];
}

//- (void) doSomethingWithCompletionHandler:(void(^)(int))handler
- (void)installServiceWorker:(void(^)())handler
{
    _initiateHandler = handler;
    NSLog(@"Fire Mock SW Install Event");
    [self evaluateScript:@"setTimeout(function () {FireInstallEvent().then(window.installServiceWorkerCallback);}, 10);"];
}

- (void)installServiceWorker
{
    NSLog(@"Fire Mock SW Install Event");
    [self evaluateScript:@"setTimeout(function () {FireInstallEvent().then(window.installServiceWorkerCallback);}, 10);"];
}

- (void)activateServiceWorker
{
    [self evaluateScript:@"window.fireActivateWorkerCallback = true;"];
    [self evaluateScript:@"FireActivateEvent().then(activateServiceWorkerCallback);'';"];
}

- (void)initiateServiceWorker
{
    isServiceWorkerActive = YES;
    _isServiceWorkerActive = YES;
    NSLog(@"Set is Service Worker Active");
    NSLog(@"Initiating Service Worker. Processing request queue.");
    if (_initiateHandler != nil) {
        _initiateHandler();
        
        _initiateHandler = nil;
    }
    [self processRequestQueue];
}


# pragma mark Helper Functions

- (void)evaluateScript:(NSString *)script
{
    
    if ([NSThread isMainThread]) {
        [self.workerWebView evaluateJavaScript:script completionHandler:^(NSString *result, NSError *error) {
            if (error != nil) {
                NSLog(@"CDVServiceWorker failed to evaluate script: %@", error.localizedDescription);
                NSLog(@"Failed script: \n %@", script);
            }
        }];
    } else {
        CDVServiceWorker * __weak weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.workerWebView evaluateJavaScript:script completionHandler:^(NSString *result, NSError *error) {
                if (error != nil) {
                    NSLog(@"CDVServiceWorker failed to evaluate script (dispatched): %@", error.localizedDescription);
                }
            }];
        });
    }
}

NSString *_clientUrl = nil;

- (void)createServiceWorkerFromScript:(NSString *)script clientUrl:(NSString*)clientUrl
{
    _clientUrl = clientUrl;
    // Get the JSContext from the webview
//    self.context = [self.workerWebView valueForKeyPath:@"documentView.webView.mainFrame.javaScriptContext"];
//    JSContext *myContext = self.context;
//    [self.context setExceptionHandler:^(JSContext *context, JSValue *value) {
//        NSLog(@"%@", value);
//    }];

    // Pipe JS logging in this context to NSLog.
    // NOTE: Not the nicest of hacks, but useful!
//    [self evaluateScript:@"var swLog = {}"];
//    self.context[@"swLog"][@"log"] = ^(NSString *message) {
//        NSLog(@"[ServiceWorker] %@", message);
//    };
//    [self evaluateScript:@"var origLog = console.log; console.log=function () {swLog.log(Array.from(arguments).join(' '));origLog.apply(console, arguments);};"];

//    CDVServiceWorker * __weak weakSelf = self;
//    self.context[@"installServiceWorkerCallback"] = ^() {
//        NSLog(@"Service Worker was installed. Trying to activate...");
//        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:SERVICE_WORKER_INSTALLED];
//        [weakSelf activateServiceWorker];
//    };
//
//    self.context[@"activateServiceWorkerCallback"] = ^() {
//        NSLog(@"Service Worker was activated. Trying to initiate...");
//        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:SERVICE_WORKER_ACTIVATED];
//        [weakSelf initiateServiceWorker];
//    };
    
    

//    self.context[@"handleFetchResponse"] = ^(JSValue *jsRequestId, JSValue *response) {
//        NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
//        [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
//        NSNumber *requestId = [formatter numberFromString:[jsRequestId toString]];
//        FetchInterceptorProtocol *interceptor = (FetchInterceptorProtocol *)[weakSelf.requestDelegates objectForKey:requestId];
//        [weakSelf.requestDelegates removeObjectForKey:requestId];
//
//        // Convert the response body to base64.
////        NSData *data = [NSData dataFromBase64String:[response[@"body"] toString]];
////        NSData *data = [NSData dataFromBase64String:[response[@"body"] toString]];
//        NSData *data = [[NSData alloc] initWithBase64EncodedString:[response[@"body"] toString] options:0];
//        JSValue *headers = response[@"headers"];
//        NSString *mimeType = [headers[@"mimeType"] toString];
//        NSString *encoding = @"utf-8";
//        NSString *url = [response[@"url"] toString]; // TODO: Can this ever be different than the request url? if not, don't allow it to be overridden
//
//        NSURLResponse *urlResponse = [[NSURLResponse alloc] initWithURL:[NSURL URLWithString:url]
//                                                            MIMEType:mimeType
//                                               expectedContentLength:data.length
//                                                    textEncodingName:encoding];
//
//        [interceptor handleAResponse:urlResponse withSomeData:data];
//    };
//
//    self.context[@"handleFetchDefault"] = ^(JSValue *jsRequestId, JSValue *response) {
//        NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
//        [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
//        NSNumber *requestId = [formatter numberFromString:[jsRequestId toString]];
//        FetchInterceptorProtocol *interceptor = (FetchInterceptorProtocol *)[weakSelf.requestDelegates objectForKey:requestId];
//        [weakSelf.requestDelegates removeObjectForKey:requestId];
//        [interceptor passThrough];
//    };
//
//    self.context[@"handleTrueFetch"] = ^(JSValue *method, JSValue *resourceUrl, JSValue *headers, JSValue *resolve, JSValue *reject) {
//        NSString *resourceUrlString = [resourceUrl toString];
//
//        NSLog(@"handleTrueFetch: %@", resourceUrlString);
//        NSFileManager *fileManager = [NSFileManager defaultManager];
//        NSString *internalUrlString = [resourceUrl toString];
//
//
//        if (![[resourceUrl toString] containsString:@"://"]) {
//            internalUrlString = [NSString stringWithFormat:@"/%@/www/%@", [[NSBundle mainBundle] resourcePath], resourceUrlString];
//            if (![fileManager fileExistsAtPath:internalUrlString]) {
//                resourceUrlString = [NSString stringWithFormat:@"%@%@", clientUrl, resourceUrlString];
//                NSLog(@"File roes not exist in local fs. Requesting remotely from: %@", resourceUrlString);
//            } else {
//                resourceUrlString = [NSString stringWithFormat:@"file://%@/www/%@", [[NSBundle mainBundle] resourcePath], resourceUrlString];
//            }
//        }
//
//        // Create the request.
//        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:resourceUrlString]];
//        [request setHTTPMethod:[method toString]];
//        JSValue *jsHeaderDictionary = [headers valueForProperty:@"headerDict"];
//        NSDictionary *headerDictionary = [jsHeaderDictionary toDictionary];
//        if (headerDictionary != nil) {
//            if ([NSThread isMainThread]) {
//                [headerDictionary enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL* stop) {
//                    [request addValue:value forHTTPHeaderField:key];
//                }];
//            } else {
//                [NSThread performSelectorOnMainThread:@selector(enumerateKeysAndObjectsUsingBlock:) withObject:^(NSString *key, NSString *value, BOOL* stop) {
//                    [request addValue:value forHTTPHeaderField:key];
//                } waitUntilDone:NO];
//            }
//        };
//
//
//        [NSURLProtocol setProperty:@YES forKey:@"PureFetch" inRequest:request];
//
//
//
//        // Create a connection and send the request.
//        FetchConnectionDelegate *delegate = [FetchConnectionDelegate new];
//        delegate.resolve = ^(ServiceWorkerResponse *response) {
//            NSDictionary *responseDict = [response toDictionary];
//            JSValue *responseValue = [JSValue valueWithObject: responseDict inContext: myContext];
//            NSArray *arguments = @[responseValue];
//            NSLog(@"Fetch complete with status (%@): %@", [response status], resourceUrlString);
//            if ([NSThread isMainThread]) {
//                [resolve callWithArguments:arguments];
//            } else {
//                [resolve performSelectorOnMainThread:@selector(callWithArguments:) withObject:arguments waitUntilDone:NO];
//            }
//        };
//        delegate.reject = ^(NSError *error) {
//            JSValue *jsError = [JSValue valueWithObject: error inContext: myContext];
//            NSArray *arguments = @[jsError];
//            NSLog(@"Fetch failed: ", resourceUrlString);
//            if ([NSThread isMainThread]) {
//                [resolve callWithArguments:arguments];
//            } else {
//                [resolve performSelectorOnMainThread:@selector(callWithArguments:) withObject:arguments waitUntilDone:NO];
//            }
//        };
//        [NSURLConnection connectionWithRequest:request delegate:delegate];
//    };
//
//    // This function is called by `postMessage`, defined in message.js.
//    // `postMessage` serializes the message using kamino.js and passes it here.
//    self.context[@"postMessageInternal"] = ^(JSValue *serializedMessage) {
//        NSString *postMessageCode = [NSString stringWithFormat:@"window.postMessage(Kamino.parse('%@'), '*')", [serializedMessage toString]];
//        [weakSelf.webView performSelectorOnMainThread:@selector(stringByEvaluatingJavaScriptFromString:) withObject:postMessageCode waitUntilDone:NO];
//    };

   NSString *originalLoader = [self readScriptAtRelativePath:@"www/load_sw.js"];
   NSString *processedLoader = [originalLoader stringByReplacingOccurrencesOfString:@"{{SERVICE_WORKER_PATH}}" withString:script];
   [self loadScript:processedLoader];
//    NSString *swScript = [self readScriptAtRelativePath:@"www/sw.js"];
//    [self loadScript:swScript];
}

- (void)createServiceWorkerClientWithUrl:(NSString *)url
{
    // Create a ServiceWorker client.
    NSString *createClientCode = [NSString stringWithFormat:@"var client = new Client('%@');", url];
    [self evaluateScript:createClientCode];
}

- (NSString *)readScriptAtRelativePath:(NSString *)relativePath
{
    // NOTE: Relative path means relative to the app bundle.

    // Compose the absolute path.
    NSString *absolutePath = [[[NSBundle mainBundle] resourcePath] stringByAppendingString:[NSString stringWithFormat:@"/%@", relativePath]];

    // Read the script from the file.
    NSError *error;
    NSString *script = [NSString stringWithContentsOfFile:absolutePath encoding:NSUTF8StringEncoding error:&error];

    // If there was an error, log it and return.
    if (error) {
        NSLog(@"Could not read script: %@", [error description]);
        return nil;
    }

    // Return our script!
    return script;
}

- (void)loadServiceWorkerAssetsIntoContext
{
    // Specify the assets directory.
    // TODO: Move assets up one directory, so they're not in www.
    NSString *assetDirectoryPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingString:@"/www/sw_assets"];

    // Get the list of assets.
    NSArray *assetFilenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:assetDirectoryPath error:NULL];

    NSString *loader = [self readScriptAtRelativePath:@"www/load_sw_assets.js"];
   
    [self loadScript:loader];
    NSLog(@"Load Service Worker Assets into context");
}

- (void)loadScript:(NSString *)script
{
    // Evaluate the script.
    [self evaluateScript:script];
}


- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    
    NSLog(@"didFinishNavigation");
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    bool serviceWorkerInstalled = [defaults boolForKey:SERVICE_WORKER_INSTALLED];
    bool serviceWorkerActivated = [defaults boolForKey:SERVICE_WORKER_ACTIVATED];
    NSString *serviceWorkerScriptChecksum = [defaults stringForKey:SERVICE_WORKER_SCRIPT_CHECKSUM];
    // Load the Service Worker polyfills
    [self loadServiceWorkerAssetsIntoContext];
    
      
    if (self.serviceWorkerScriptFilename == nil) {
        NSLog(@"No service worker script defined. Please add the following line to config.xml: <preference name=\"ServiceWorker\" value=\"[your-service-worker].js\" />");
    }
}



- (void)webView:(WKWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request {}
- (void)webViewDidStartLoad:(WKWebView *)wv {}
- (void)webView:(WKWebView *)wv didFailLoadWithError:(NSError *)error {}


- (void)addRequestToQueue:(NSURLRequest *)request withId:(NSNumber *)requestId delegateTo:(NSURLProtocol *)protocol
{
    // Log!
    NSLog(@"Adding to queue: %@", [[request URL] absoluteString]);

    // Create a request object.
    ServiceWorkerRequest *swRequest = [ServiceWorkerRequest new];
    swRequest.request = request;
    swRequest.requestId = requestId;
    swRequest.protocol = protocol;

    // Add the request object to the queue.
    [self.requestQueue addObject:swRequest];

    // Process the request queue.
    [self processRequestQueue];
}

- (void)processRequestQueue {
    // If the ServiceWorker isn't active, there's nothing we can do yet.
    NSLog(@"processRequestQueue");
    if (!isServiceWorkerActive) {
        return;
    }

    for (ServiceWorkerRequest *swRequest in self.requestQueue) {
        // Log!
        NSLog(@"Processing from queue: %@", [[swRequest.request URL] absoluteString]);

        // Register the request and delegate.
        [self.requestDelegates setObject:swRequest.protocol forKey:swRequest.requestId];

        // Fire a fetch event in the JSContext.
        NSURLRequest *request = swRequest.request;
        NSString *method = [request HTTPMethod];
        NSString *url = [[request URL] absoluteString];
        NSData *headerData = [NSJSONSerialization dataWithJSONObject:[request allHTTPHeaderFields]
                                                             options:NSJSONWritingPrettyPrinted
                                                               error:nil];
        NSString *headers = [[[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];

        NSString *createRequestSnippet = [NSString stringWithFormat:@"Request.create('%@', '%@', %@)", method, url, headers];
        NSString *dispatchCode = [NSString stringWithFormat:@"dispatchEvent(new FetchEvent({request:%@, id:'%lld'}));", createRequestSnippet, [swRequest.requestId longLongValue]];
        [self evaluateScript:dispatchCode];
    }

    // Clear the queue.
    // TODO: Deal with the possibility that requests could be added during the loop that we might not necessarily want to remove.
    [self.requestQueue removeAllObjects];
}

@end

