//
//  file: Rules.m
//  project: lulu (launch daemon)
//  description: handles rules & actions such as add/delete
//
//  created by Patrick Wardle
//  copyright (c) 2017 Objective-See. All rights reserved.
//


#import "const.h"

#import "Rule.h"
#import "Rules.h"
#import "logging.h"
#import "KextComms.h"
#import "Utilities.h"

//global kext comms object
extern KextComms* kextComms;

@implementation Rules

@synthesize rules;
@synthesize appQuery;

//init method
-(id)init
{
    //init super
    self = [super init];
    if(nil != self)
    {
        //alloc
        rules = [NSMutableDictionary dictionary];
    }
    
    return self;
}

//load rules from disk
-(BOOL)load
{
    //result
    BOOL result = NO;
    
    //serialized rules
    NSDictionary* serializedRules = nil;
    
    //rules obj
    Rule* rule = nil;
    
    //load serialized rules from disk
    serializedRules = [NSMutableDictionary dictionaryWithContentsOfFile:RULES_FILE];
    if(nil == serializedRules)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to load rules from: %@", RULES_FILE]);
        
        //bail
        goto bail;
    }
    
    //create rule objects for each
    for(NSString* key in serializedRules)
    {
        //init
        rule = [[Rule alloc] init:key rule:serializedRules[key]];
        if(nil == rule)
        {
            //skip
            continue;
        }
        
        //add
        self.rules[rule.path] = rule;
    }
    
    //add default/pre-existing apps
    // TODO: maybe move this into installer!
    [self startBaselining];
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"loaded %lu rules from: %@", (unsigned long)self.rules.count, RULES_FILE]);
    
    //happy
    result = YES;
    
bail:
    
    return result;
}

//save to disk
-(BOOL)save
{
    //result
    BOOL result = NO;
    
    //serialized rules
    NSDictionary* serializedRules = nil;

    //serialize
    serializedRules = [self serialize];
    
    //write out
    if(YES != [serializedRules writeToFile:RULES_FILE atomically:YES])
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to save rules to: %@", RULES_FILE]);
        
        //bail
        goto bail;
    }
    
    //happy
    result = YES;
    
bail:
    
    return result;
}

//start query for all installed apps
// TODO: maybe move this into installer
-(void)startBaselining
{
    //alloc
    appQuery = [[NSMetadataQuery alloc] init];
    
    //register for query completion
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(endBaselining:) name:NSMetadataQueryDidFinishGatheringNotification object:nil];
    
    //set predicate
    [self.appQuery setPredicate:[NSPredicate predicateWithFormat:@"kMDItemKind == 'Application'"]];
    
    //start query
    // ->will generate notification when done
    [self.appQuery startQuery];
    
    return;
}

//invoked when spotlight query is done
// ->process each app by adding 'allow' rule
-(void)endBaselining:(NSNotification *)notification
{
    //app url
    __block NSString* currentApp = nil;
    
    //full path to binary
    __block NSString* currentAppBinary = nil;
    
    //iterate over all
    // ->create/add default/baseline rule for each
    [self.appQuery enumerateResultsUsingBlock:^(id result, NSUInteger idx, BOOL *stop)
    {
        //grab current app
        currentApp = [result valueForAttribute:NSMetadataItemPathKey];
        if(nil == currentApp)
        {
            //skip
            return;
        }
        
        //skip app store
        // ->its a default/system rule already
        if(YES == [currentApp isEqualToString:@"/Applications/App Store.app"])
        {
            //skip
            return;
        }
        
        //get full binary path
        currentAppBinary = getAppBinary(currentApp);
        if(nil == currentAppBinary)
        {
            //skip
            return;    
        }
        
        //add
        // ->allow, type: 'baseline'
        [self add:currentAppBinary action:RULE_STATE_ALLOW type:RULE_TYPE_BASELINE user:0];
    }];
    
    return;
}

//convert list of rule objects to dictionary
-(NSMutableDictionary*)serialize
{
    //serialized rules
    NSMutableDictionary* serializedRules = nil;
    
    //alloc
    serializedRules = [NSMutableDictionary dictionary];
    
    //sync to access
    @synchronized(self.rules)
    {
        //iterate over all rules
        // ->serialize & add each
        for(NSString* path in self.rules)
        {
            //covert/add
            serializedRules[path] = [rules[path] serialize];
        }
    }
    
    return serializedRules;
}

//find
// ->for now, just by path
-(Rule*)find:(NSString*)path
{
    //matching rule
    Rule* matchingRule = nil;
    
    //sync to access
    @synchronized(self.rules)
    {
        //extract rule
        matchingRule = [self.rules objectForKey:path];
        if(nil == matchingRule)
        {
            //not found, bail
            goto bail;
        }
    }
    
    //TOOD: validate binary still matches hash
    
    //TOOD: check that rule is for this user!

bail:
    
    return matchingRule;
}

//add rule
// TODO: ignore if it matches existing rule (also do this check in the client)
-(BOOL)add:(NSString*)path action:(NSUInteger)action type:(NSUInteger)type user:(NSUInteger)user
{
    //result
    BOOL result = NO;
    
    //rule
    Rule* rule = nil;
    
    //sync to access
    @synchronized(self.rules)
    {
        //init rule
        rule = [[Rule alloc] init:path rule:@{RULE_ACTION:[NSNumber numberWithUnsignedInteger:action], RULE_TYPE:[NSNumber numberWithUnsignedInteger:type], RULE_USER:[NSNumber numberWithUnsignedInteger:user]}];
        
        //add
        self.rules[path] = rule;
        
        //save to disk
        [self save];
    }
    
    //for user rules find any running processes that match
    // ->then for each, tell the kernel to add/update any rules it has
    if(RULE_TYPE_USER == type)
    {
        //find processes and add
        for(NSNumber* processID in getProcessIDs(path, -1))
        {
            //add rule
            [kextComms addRule:[processID unsignedShortValue] action:(unsigned int)action];
        }
    }

    //happy
    result = YES;
    
bail:
    
    return result;
}

//delete rule
-(BOOL)delete:(NSString*)path
{
    //result
    BOOL result = NO;
    
    //sync to access
    @synchronized(self.rules)
    {
        //add
        self.rules[path] = nil;
        
        //save to disk
        [self save];
    }
    
    //find any running processes that match
    // ->then for each, tell the kernel to delete any rules it has
    for(NSNumber* processID in getProcessIDs(path, -1))
    {
        //remove rule
        [kextComms removeRule:[processID unsignedShortValue]];
    }

    //happy
    result = YES;
    
bail:
    
    return result;
}

@end
