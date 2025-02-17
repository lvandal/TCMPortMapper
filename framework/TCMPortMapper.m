#import "TCMPortMapper.h"
#import "TCMNATPMPPortMapper.h"
#import "TCMUPNPPortMapper.h"
#import "TCMSystemConfiguration.h"
#import "NSNotificationCenterThreadingAdditions.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <SystemConfiguration/SCSchemaDefinitions.h>
#import <sys/sysctl.h> 
#import <netinet/in.h>
#import <arpa/inet.h>
#import <net/route.h>
#import <netinet/if_ether.h>
#import <net/if_dl.h>
#import <err.h>
#import <CommonCrypto/CommonDigest.h>

#import <zlib.h>

// update port mappings all 30 minutes as a default
#define UPNP_REFRESH_INTERVAL (30.*60.)

NSString * const TCMPortMapperExternalIPAddressDidChange             = @"TCMPortMapperExternalIPAddressDidChange";
NSString * const TCMPortMapperWillStartSearchForRouterNotification   = @"TCMPortMapperWillStartSearchForRouterNotification";
NSString * const TCMPortMapperDidFinishSearchForRouterNotification   = @"TCMPortMapperDidFinishSearchForRouterNotification";
NSString * const TCMPortMappingDidChangeMappingStatusNotification    = @"TCMPortMappingDidChangeMappingStatusNotification";
NSString * const TCMPortMapperDidStartWorkNotification               = @"TCMPortMapperDidStartWorkNotification";
NSString * const TCMPortMapperDidFinishWorkNotification              = @"TCMPortMapperDidFinishWorkNotification";

NSString * const TCMPortMapperDidReceiveUPNPMappingTableNotification = @"TCMPortMapperDidReceiveUPNPMappingTableNotification";


NSString * const TCMNATPMPPortMapProtocol = @"NAT-PMP";
NSString * const TCMUPNPPortMapProtocol   = @"UPnP";
NSString * const TCMNoPortMapProtocol     = @"None";


enum {
    TCMPortMapProtocolFailed = 0,
    TCMPortMapProtocolTrying = 1,
    TCMPortMapProtocolWorks = 2
};

@implementation NSString (TCMPortMapper_IPAdditions)

- (BOOL)isIPv4Address {
    in_addr_t myaddr = inet_addr([self UTF8String]);
    if (myaddr == INADDR_NONE) {
        return NO;
    } else {
        return YES;
    }
}

- (BOOL)IPv4AddressIsInPrivateSubnet {
    in_addr_t myaddr = inet_addr([self UTF8String]);
    if (myaddr == INADDR_NONE) {
        return NO;
    }
    // private subnets as defined in http://tools.ietf.org/html/rfc1918
    // loopback addresses 127.0.0.1/8 http://tools.ietf.org/html/rfc3330
    // zeroconf/bonjour self assigned addresses 169.254.0.0/16 http://tools.ietf.org/html/rfc3927
    char *ipAddresses[]  = {"192.168.0.0", "10.0.0.0", "172.16.0.0","127.0.0.1","169.254.0.0"};
    char *networkMasks[] = {"255.255.0.0","255.0.0.0","255.240.0.0","255.0.0.0","255.255.0.0"};
    int countOfAddresses = 5;
    int i = 0;
    for (i=0; i<countOfAddresses; i++) {
        in_addr_t subnetmask = inet_addr(networkMasks[i]);
        in_addr_t networkaddress = inet_addr(ipAddresses[i]);
        if ((myaddr & subnetmask) == (networkaddress & subnetmask)) {
            return YES;
        }
    }
    return NO;
}
@end

typedef void (^ TCMCompletionBlock)(void);

@implementation TCMPortMapping

+ (instancetype)portMappingWithLocalPort:(uint16_t)privatePort desiredExternalPort:(uint16_t)publicPort transportProtocol:(TCMPortMappingTransportProtocol)transportProtocol userInfo:(id)userInfo {

    NSAssert(privatePort>=0 && publicPort>=0, @"Port number has to be between 0 and 65535");
    return [[self alloc] initWithLocalPort:privatePort desiredExternalPort:publicPort transportProtocol:transportProtocol userInfo:userInfo];
}

- (instancetype)initWithLocalPort:(uint16_t)privatePort desiredExternalPort:(uint16_t)publicPort transportProtocol:(TCMPortMappingTransportProtocol)transportProtocol userInfo:(id)userInfo {
    if ((self=[super init])) {
        _desiredExternalPort = publicPort;
        _localPort = privatePort;
        _userInfo = userInfo;
        _transportProtocol = transportProtocol;
    }
    return self;
}

- (void)setMappingStatus:(TCMPortMappingStatus)aStatus {
    if (_mappingStatus != aStatus) {
        _mappingStatus = aStatus;
        if (_mappingStatus == TCMPortMappingStatusUnmapped) {
            [self setExternalPort:0];
        }
        [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:TCMPortMappingDidChangeMappingStatusNotification object:self];
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ privatePort:%u desiredPublicPort:%u publicPort:%u mappingStatus:%@ transportProtocol:%d",[super description], _localPort, _desiredExternalPort, _externalPort, _mappingStatus == TCMPortMappingStatusUnmapped ? @"unmapped" : (_mappingStatus == TCMPortMappingStatusMapped ? @"mapped" : @"trying"),_transportProtocol];
}

@end

@interface TCMPortMapper () {
    TCMNATPMPPortMapper *_NATPMPPortMapper;
    TCMUPNPPortMapper *_UPNPPortMapper;
    NSMutableSet *_portMappings;
    NSMutableSet *_removeMappingQueue;
    BOOL _isRunning;
    int _NATPMPStatus;
    int _UPNPStatus;
    int _workCount;
    BOOL _localIPOnRouterSubnet;
    BOOL _sendUPNPMappingTableNotification;
    NSMutableSet *_upnpPortMappingsToRemove;
    NSTimer *_upnpPortMapperTimer;
    BOOL _ignoreNetworkChanges;
    BOOL _refreshIsScheduled;
    
    NSMutableSet *_systemConfigurationObservations;
    
    TCMCompletionBlock _completionBlock;
}

@property (nonatomic, strong, readwrite) NSString *externalIPAddress;
@property (nonatomic, strong, readwrite) NSString *localIPAddress;

- (void)cleanupUPNPPortMapperTimer;
- (void)increaseWorkCount:(NSNotification *)aNotification;
- (void)decreaseWorkCount:(NSNotification *)aNotification;
- (void)scheduleRefresh;
@end

@implementation TCMPortMapper
@synthesize localIPAddress=_localIPAddress;

static TCMPortMapper *S_sharedInstance;

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        S_sharedInstance = [self new];
    });
    return S_sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isRunning = NO;
        _ignoreNetworkChanges = NO;
        _refreshIsScheduled = NO;
        _NATPMPPortMapper = [[TCMNATPMPPortMapper alloc] init];
        _UPNPPortMapper = [[TCMUPNPPortMapper alloc] init];
        _portMappings = [NSMutableSet new];
        _removeMappingQueue = [NSMutableSet new];
        _upnpPortMappingsToRemove = [NSMutableSet new];
        
        [self hashUserID:NSUserName()];
        
        S_sharedInstance = self;

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        
        [center addObserver:self selector:@selector(increaseWorkCount:) 
                name:  TCMUPNPPortMapperDidBeginWorkingNotification    object:_UPNPPortMapper];
        [center addObserver:self selector:@selector(increaseWorkCount:) 
                name:TCMNATPMPPortMapperDidBeginWorkingNotification    object:_NATPMPPortMapper];

        [center addObserver:self selector:@selector(decreaseWorkCount:) 
                name:  TCMUPNPPortMapperDidEndWorkingNotification    object:_UPNPPortMapper];
        [center addObserver:self selector:@selector(decreaseWorkCount:) 
                name:TCMNATPMPPortMapperDidEndWorkingNotification    object:_NATPMPPortMapper];
        
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];

        [self startObservingSystemConfiguration];
    }
    return self;
}

- (void)dealloc {
    [self cleanupUPNPPortMapperTimer];
}

- (BOOL)networkReachable {
    SCNetworkConnectionFlags flags;
    SCNetworkReachabilityRef target = SCNetworkReachabilityCreateWithName(NULL, "www.apple.com");
    Boolean success = SCNetworkReachabilityGetFlags(target, &flags);
    CFRelease(target);
    
    BOOL result = success && (flags & kSCNetworkFlagsReachable) && !(flags & kSCNetworkFlagsConnectionRequired);
    
    return result;
}

- (void)handleNetworkChange {
    if (!_ignoreNetworkChanges) {
        [self scheduleRefresh];
    }
}

- (NSString *)localBonjourHostName {
    SCDynamicStoreRef dynRef = SCDynamicStoreCreate(kCFAllocatorSystemDefault, (CFStringRef)@"TCMPortMapper", NULL, NULL); 
    NSString *hostname = (NSString *)CFBridgingRelease(SCDynamicStoreCopyLocalHostName(dynRef));
    CFRelease(dynRef);
    return [hostname stringByAppendingString:@".local"];
}

- (void)updateLocalIPAddress {
    NSString *routerAddress = [self routerIPAddress];
    SCDynamicStoreRef dynRef = SCDynamicStoreCreate(kCFAllocatorSystemDefault, (CFStringRef)@"TCMPortMapper", NULL, NULL); 
    NSDictionary *scobjects = (NSDictionary *)CFBridgingRelease(SCDynamicStoreCopyValue(dynRef,(CFStringRef)@"State:/Network/Global/IPv4" )); 
    
    NSString *ipv4Key = [NSString stringWithFormat:@"State:/Network/Interface/%@/IPv4", [scobjects objectForKey:(NSString *)kSCDynamicStorePropNetPrimaryInterface]];
    
    CFRelease(dynRef);
    
    dynRef = SCDynamicStoreCreate(kCFAllocatorSystemDefault, (CFStringRef)@"TCMPortMapper", NULL, NULL); 
    scobjects = (NSDictionary *)CFBridgingRelease(SCDynamicStoreCopyValue(dynRef,(CFStringRef)ipv4Key)); 
    
//        NSLog(@"%s scobjects:%@",__FUNCTION__,scobjects);
    NSArray *IPAddresses = (NSArray *)[scobjects objectForKey:(NSString *)kSCPropNetIPv4Addresses];
    NSArray *subNetMasks = (NSArray *)[scobjects objectForKey:(NSString *)kSCPropNetIPv4SubnetMasks];
//    NSLog(@"%s addresses:%@ masks:%@",__FUNCTION__,IPAddresses, subNetMasks);
    if (routerAddress) {
        NSString *ipAddress = nil;
        int i;
        for (i=0;i<[IPAddresses count];i++) {
            ipAddress = (NSString *) [IPAddresses objectAtIndex:i];
            NSString *subNetMask = (NSString *) [subNetMasks objectAtIndex:i];
 //           NSLog(@"%s ipAddress:%@ subNetMask:%@",__FUNCTION__, ipAddress, subNetMask);
            // Check if local to Host
            if (ipAddress && subNetMask) {
                in_addr_t myaddr = inet_addr([ipAddress UTF8String]);
                in_addr_t subnetmask = inet_addr([subNetMask UTF8String]);
                in_addr_t routeraddr = inet_addr([routerAddress UTF8String]);
        //            NSLog(@"%s ipNative:%X maskNative:%X",__FUNCTION__,routeraddr,subnetmask);
                if ((myaddr & subnetmask) == (routeraddr & subnetmask)) {
                    [self setLocalIPAddress:ipAddress];
                    _localIPOnRouterSubnet = YES;
                    break;
                }
            }
            
        }
        // this should never happen - if we have a router then we need to have an IP address on the same subnet to know this...
        if (i==[IPAddresses count]) {
            // we haven't found an IP address that matches - so set the last one
            _localIPOnRouterSubnet = NO;
            [self setLocalIPAddress:ipAddress];
        }
    } else {
        [self setLocalIPAddress:[IPAddresses lastObject]];
        _localIPOnRouterSubnet = NO;
    }
    CFRelease(dynRef);
}

- (NSString *)localIPAddress {
    // make sure it is up to date
    [self updateLocalIPAddress];
    return _localIPAddress;
}

+ (NSString *)sizereducableHashOfString:(NSString *)inString {
    unsigned char digest[16];
    char hashstring[16*2+1];
    int i;
    NSData *dataToHash = [inString dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    CC_MD5([dataToHash bytes], (CC_LONG)[dataToHash length], digest);
    for(i=0;i<16;i++) sprintf(hashstring+i*2,"%02x",digest[i]);
    hashstring[i*2]=0;
    
    return [NSString stringWithUTF8String:hashstring];
}

- (void)hashUserID:(NSString *)aUserIDToHash {
    NSString *hashString = [TCMPortMapper sizereducableHashOfString:aUserIDToHash];
    if ([hashString length] > 16) hashString = [hashString substringToIndex:16];
    [self setUserID:hashString];
}

- (void)setUserID:(NSString *)aUserID {
    if (_userID != aUserID) {
        _userID = [aUserID copy];
    }
}

- (NSSet *)portMappings{
    return _portMappings;
}

- (NSMutableSet *)removeMappingQueue {
    return _removeMappingQueue;
}

- (NSMutableSet *)_upnpPortMappingsToRemove {
    return _upnpPortMappingsToRemove;
}

- (void)updatePortMappings {
    NSString *protocol = [self mappingProtocol];
    if ([protocol isEqualToString:TCMNATPMPPortMapProtocol]) {
        [_NATPMPPortMapper updatePortMappings];
    } else if ([protocol isEqualToString:TCMUPNPPortMapProtocol]) {
        [_UPNPPortMapper updatePortMappings];
    }
}

- (void)addPortMapping:(TCMPortMapping *)aMapping completion:(void (^)(void))completionBlock {
    @synchronized(_portMappings) {
        _completionBlock = completionBlock;
        
        if (aMapping.mappingStatus != TCMPortMappingStatusUnmapped &&
            ![_portMappings containsObject:aMapping]) {
            [aMapping setMappingStatus:TCMPortMappingStatusUnmapped];
        }
        [_portMappings addObject:aMapping];
    }
    [self updatePortMappings];
}

- (void)removePortMapping:(TCMPortMapping *)aMapping completion:(void (^)(void))completionBlock {
    if (aMapping) {
        _completionBlock = completionBlock;
        
        __autoreleasing TCMPortMapping *mapping = aMapping;
        @synchronized(_portMappings) {
            [_portMappings removeObject:mapping];
        }
        @synchronized(_removeMappingQueue) {
            if ([mapping mappingStatus] != TCMPortMappingStatusUnmapped) {
                [_removeMappingQueue addObject:mapping];
            }
        }
        if (_isRunning) [self updatePortMappings];
    }
}

// add some delay to the refresh caused by network changes so mDNSResponer has a little time to grab its port before us
- (void)scheduleRefresh {
    if (!_refreshIsScheduled) {
        [self performSelector:@selector(refresh) withObject:nil afterDelay:0.5];
    }
}

- (void)refresh {

    [self increaseWorkCount:nil];
    
    [self setRouterName:@"Unknown"];
    [self setMappingProtocol:TCMNoPortMapProtocol];
    [self setExternalIPAddress:nil];
    
    @synchronized(_portMappings) {
       NSEnumerator *portMappings = [_portMappings objectEnumerator];
       TCMPortMapping *portMapping = nil;
       while ((portMapping = [portMappings nextObject])) {
           if (portMapping.mappingStatus != TCMPortMappingStatusUnmapped) {
               [portMapping setMappingStatus:TCMPortMappingStatusUnmapped];
           }
       }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperWillStartSearchForRouterNotification object:self];   
    
    NSString *routerAddress = [self routerIPAddress];
    if (routerAddress) {
        NSString *manufacturer = [TCMPortMapper manufacturerForHardwareAddress:[self routerHardwareAddress]];
        if (manufacturer) {
            [self setRouterName:manufacturer];
        } else {
            [self setRouterName:@"Unknown"];
        }
        NSString *localIPAddress = [self localIPAddress]; // will always be updated when accessed
        if (localIPAddress && _localIPOnRouterSubnet) {
            [self setExternalIPAddress:nil];
            if ([routerAddress IPv4AddressIsInPrivateSubnet]) {
                _NATPMPStatus = TCMPortMapProtocolTrying;
                _UPNPStatus   = TCMPortMapProtocolTrying;
                [_NATPMPPortMapper refresh];
                [_UPNPPortMapper refresh];
            } else {
                _NATPMPStatus = TCMPortMapProtocolFailed;
                _UPNPStatus   = TCMPortMapProtocolFailed;
                [self setExternalIPAddress:localIPAddress];
                [self setMappingProtocol:TCMNoPortMapProtocol];
                // set all mappings to be mapped with their local port number being the external one
                @synchronized(_portMappings) {
                   NSEnumerator *portMappings = [_portMappings objectEnumerator];
                   TCMPortMapping *portMapping = nil;
                   while ((portMapping = [portMappings nextObject])) {
                        [portMapping setExternalPort:[portMapping localPort]];
                        [portMapping setMappingStatus:TCMPortMappingStatusMapped];
                   }
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperDidFinishSearchForRouterNotification object:self];
                // we know we have a public address so we are finished - but maybe we should set all mappings to mapped
            }
        } else {
            [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperDidFinishSearchForRouterNotification object:self];
        }
    } else {
        [_NATPMPPortMapper stopListeningToExternalIPAddressChanges];
        [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperDidFinishSearchForRouterNotification object:self];
    }

    // add the delay to bridge the gap between the thread starting and this method returning
    [self performSelector:@selector(decreaseWorkCount:) withObject:nil afterDelay:1.0];
    // make way for further refresh schedulings
    _refreshIsScheduled = NO;
}

- (void)setExternalIPAddress:(NSString *)anIPAddress {
    // Maybe too strong: 
//    if (anIPAddress && [anIPAddress IPv4AddressIsInPrivateSubnet]) {
//        anIPAddress = nil; // prevent non-public addresses to be set this way.
//    }
    if (_externalIPAddress != anIPAddress) {
        _externalIPAddress = anIPAddress;
    }
    // notify always even if the external IP Address is unchanged so that we get the notification anytime when new information is here
    [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperExternalIPAddressDidChange object:self];
}

- (void)setLocalIPAddress:(NSString *)anIPAddress {
    if (_localIPAddress != anIPAddress) {
        _localIPAddress = anIPAddress;
    }
}

- (NSString *)hardwareAddressForIPAddress: (NSString *) address {
    if (!address) return nil;
    int mib[6];
    size_t needed;
    char *lim, *buf, *next;
    struct sockaddr_inarp blank_sin = {sizeof(blank_sin), AF_INET };
    struct rt_msghdr *rtm;
    struct sockaddr_inarp *sin;
    struct sockaddr_dl *sdl;

    struct sockaddr_inarp sin_m;
    struct sockaddr_inarp *sin2 = &sin_m;

    sin_m = blank_sin;
    sin2->sin_addr.s_addr = inet_addr([address UTF8String]);
    u_long addr = sin2->sin_addr.s_addr;

    mib[0] = CTL_NET;
    mib[1] = PF_ROUTE;
    mib[2] = 0;
    mib[3] = AF_INET;
    mib[4] = NET_RT_FLAGS;
    mib[5] = RTF_LLINFO;
    
    if (sysctl(mib, 6, NULL, &needed, NULL, 0) < 0) err(1, "route-sysctl-estimate");
    if ((buf = malloc(needed)) == NULL) err(1, "malloc");
    if (sysctl(mib, 6, buf, &needed, NULL, 0) < 0) err(1, "actual retrieval of routing table");
    
    lim = buf + needed;
    for (next = buf; next < lim; next += rtm->rtm_msglen) {
        rtm = (struct rt_msghdr *)next;
        sin = (struct sockaddr_inarp *)(rtm + 1);
        sdl = (struct sockaddr_dl *)(sin + 1);
        if (addr) {
            if (addr != sin->sin_addr.s_addr) continue;
        }
            
        if (sdl->sdl_alen) {
            u_char *cp = (u_char *)LLADDR(sdl);
            NSString* result = [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x", cp[0], cp[1], cp[2], cp[3], cp[4], cp[5]];
            free(buf);
            return result;
        } else {
            free(buf);
          return nil;
        }
    }
    return nil;
}

/**
 Returns the manufacturer name specified in the IEEE OUI.txt file as preprocessed at https://linuxnet.ca/ieee/oui/

 @param MACAddress MAC address as string of the form @"e0:28:6d:54:d6:50"
 @return Manufacturer name if we know it for the prefix of this MAC Address
 */
+ (NSString *)manufacturerForHardwareAddress:(NSString *)MACAddress {
    if ([MACAddress length]<8) {
        return nil;
    }

    
    static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *hardwareManufacturerDictionary = nil;
    if (hardwareManufacturerDictionary==nil) {
        NSURL *fileURL = [[NSBundle bundleForClass:[self class]] URLForResource:@"OUItoCompany2Level" withExtension:@"json.gz"];
        if (fileURL) {
            NSData *gzippedData = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedAlways error:nil];
            // unzip the data
            z_stream stream;
            stream.zalloc = Z_NULL;
            stream.zfree = Z_NULL;
            stream.avail_in = (uint)gzippedData.length;
            stream.next_in = (Bytef *)gzippedData.bytes;
            stream.total_out = 0;
            stream.avail_out = 0;
            
            if (inflateInit2(&stream, 47) == Z_OK) {
                NSMutableData *data = [NSMutableData dataWithLength:gzippedData.length * 2];
                int status = Z_OK;
                while (status == Z_OK) {
                    if (stream.total_out >= data.length) {
                        data.length += data.length / 2;
                    }
                    stream.next_out = (uint8_t *)data.mutableBytes + stream.total_out;
                    stream.avail_out = (uInt)(data.length - stream.total_out);
                    status = inflate(&stream, Z_SYNC_FLUSH);
                }
                if (inflateEnd(&stream) == Z_OK) {
                    if (status == Z_STREAM_END) {
                        data.length = stream.total_out;
                    }
                }
                
                hardwareManufacturerDictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }
            
        } else {
            hardwareManufacturerDictionary = [NSDictionary new];
        }
    }
    NSString *firstKey = [[MACAddress substringToIndex:2] lowercaseString];
    NSString *secondKey = [[[MACAddress substringWithRange:NSMakeRange(3,2)] stringByAppendingString:[MACAddress substringWithRange:NSMakeRange(6,2)]] lowercaseString];
    
    NSString *result = hardwareManufacturerDictionary[firstKey][secondKey];
    return result;
}


- (void)start {
    if (!_isRunning) {
        [self startObservingSystemConfiguration];

        NSNotificationCenter *center=[NSNotificationCenter defaultCenter];

        [center addObserver:self
                selector:@selector(NATPMPPortMapperDidGetExternalIPAddress:) 
                name:TCMNATPMPPortMapperDidGetExternalIPAddressNotification 
                object:_NATPMPPortMapper];
    
        [center addObserver:self 
                selector:@selector(NATPMPPortMapperDidFail:) 
                name:TCMNATPMPPortMapperDidFailNotification 
                object:_NATPMPPortMapper];

        [center addObserver:self 
                selector:@selector(NATPMPPortMapperDidReceiveBroadcastedExternalIPChange:) 
                name:TCMNATPMPPortMapperDidReceiveBroadcastedExternalIPChangeNotification 
                object:_NATPMPPortMapper];

    
        [center addObserver:self 
                selector:@selector(UPNPPortMapperDidGetExternalIPAddress:) 
                name:TCMUPNPPortMapperDidGetExternalIPAddressNotification 
                object:_UPNPPortMapper];
    
        [center addObserver:self 
                selector:@selector(UPNPPortMapperDidFail:) 
                name:TCMUPNPPortMapperDidFailNotification 
                object:_UPNPPortMapper];
    
        _isRunning = YES;
    }
    [self refresh];
}


- (void)NATPMPPortMapperDidGetExternalIPAddress:(NSNotification *)aNotification {
    BOOL shouldNotify = NO;
    if (_NATPMPStatus==TCMPortMapProtocolTrying) {
        _NATPMPStatus =TCMPortMapProtocolWorks;
        [self setMappingProtocol:TCMNATPMPPortMapProtocol];
        shouldNotify = YES;
    }
    NSString *externalIPAddress = [[aNotification userInfo] objectForKey:@"externalIPAddress"];
    [self setExternalIPAddress:externalIPAddress];
    if (shouldNotify) {
        [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperDidFinishSearchForRouterNotification object:self];
    }
}

- (void)NATPMPPortMapperDidFail:(NSNotification *)aNotification {
    if (_NATPMPStatus==TCMPortMapProtocolTrying) {
        _NATPMPStatus =TCMPortMapProtocolFailed;
    } else if (_NATPMPStatus==TCMPortMapProtocolWorks) {
        [self setExternalIPAddress:nil];
    }
    // also mark all port mappings as unmapped if UPNP failed too
    if (_UPNPStatus == TCMPortMapProtocolFailed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperDidFinishSearchForRouterNotification object:self];
    }
}

- (void)UPNPPortMapperDidGetExternalIPAddress:(NSNotification *)aNotification {
    BOOL shouldNotify = NO;
    if (_UPNPStatus==TCMPortMapProtocolTrying) {
        _UPNPStatus =TCMPortMapProtocolWorks;
        [self setMappingProtocol:TCMUPNPPortMapProtocol];
        shouldNotify = YES;
        if (_NATPMPStatus==TCMPortMapProtocolTrying) {
            [_NATPMPPortMapper stop];
            _NATPMPStatus =TCMPortMapProtocolFailed;
        }
    }
    NSDictionary *userInfo = [aNotification userInfo];
    NSString *routerName = userInfo[@"routerName"];
    if (routerName) {
        [self setRouterName:routerName];
    }
    [self setExternalIPAddress:userInfo[@"externalIPAddress"]];
    if (shouldNotify) {
        [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperDidFinishSearchForRouterNotification object:self];
    }
    if (!_upnpPortMapperTimer) {
        _upnpPortMapperTimer = [NSTimer scheduledTimerWithTimeInterval:UPNP_REFRESH_INTERVAL target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    }
}

- (void)UPNPPortMapperDidFail:(NSNotification *)aNotification {
    if (_UPNPStatus==TCMPortMapProtocolTrying) {
        _UPNPStatus =TCMPortMapProtocolFailed;
    } else if (_UPNPStatus==TCMPortMapProtocolWorks) {
        // only kill the external IP if everything failed, and not just a mapping.
        if (!(aNotification.userInfo[@"failedMapping"])) {
            [self setExternalIPAddress:nil];
        }
    }
    [self cleanupUPNPPortMapperTimer];
    // also mark all port mappings as unmapped if NATPMP failed too
    if (_NATPMPStatus == TCMPortMapProtocolFailed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperDidFinishSearchForRouterNotification object:self];
    }
}

- (void)cleanupUPNPPortMapperTimer {
    if (_upnpPortMapperTimer) {
        [_upnpPortMapperTimer invalidate];
        _upnpPortMapperTimer = nil;
    }
}

- (void)startObservingSystemConfiguration {
    _systemConfigurationObservations = [NSMutableSet new];
    id observation = [[TCMSystemConfiguration sharedConfiguration] observeConfigurationKeys:@[@"State:/Network/Global/IPv4"/*, @"State:/Network/Global/IPv6" */] observationBlock:^(TCMSystemConfiguration *config, NSArray<NSString *> *changedKeys) {
        [self handleNetworkChange];
    }];
    [_systemConfigurationObservations addObject:observation];
}

- (void)stopObservingSystemConfiguration {
    for (id observation in _systemConfigurationObservations) {
        [[TCMSystemConfiguration sharedConfiguration] removeConfigurationKeyObservation:observation];
    }
    [_systemConfigurationObservations removeAllObjects];
}

- (void)internalStop {
    [self stopObservingSystemConfiguration];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:TCMNATPMPPortMapperDidGetExternalIPAddressNotification object:_NATPMPPortMapper];
    [center removeObserver:self name:TCMNATPMPPortMapperDidFailNotification object:_NATPMPPortMapper];
    [center removeObserver:self name:TCMNATPMPPortMapperDidReceiveBroadcastedExternalIPChangeNotification object:_NATPMPPortMapper];
    
    [center removeObserver:self name:TCMUPNPPortMapperDidGetExternalIPAddressNotification object:_UPNPPortMapper];
    [center removeObserver:self name:TCMUPNPPortMapperDidFailNotification object:_UPNPPortMapper];
    [self cleanupUPNPPortMapperTimer];
}

- (void)stop {
    if (_isRunning) {
        [self internalStop];
        _isRunning = NO;
        if (_NATPMPStatus != TCMPortMapProtocolFailed) {
            [_NATPMPPortMapper stop];
        }
        if (_UPNPStatus   != TCMPortMapProtocolFailed) {
            [_UPNPPortMapper stop];
        }
    }
}

- (void)stopBlocking {
    if (_isRunning) {
        [self internalStop];
        if (_NATPMPStatus == TCMPortMapProtocolWorks) {
            [_NATPMPPortMapper stopBlocking];
        }
        if (_UPNPStatus   == TCMPortMapProtocolWorks) {
            [_UPNPPortMapper stopBlocking];
        }
        _isRunning = NO;
    }
}

- (void)removeUPNPMappings:(NSArray *)aMappingList {
    if (_UPNPStatus == TCMPortMapProtocolWorks) {
        @synchronized (_upnpPortMappingsToRemove) {
            [_upnpPortMappingsToRemove addObjectsFromArray:aMappingList];
        }
        [_UPNPPortMapper updatePortMappings];
    }
}

- (void)requestUPNPMappingTable {
    if (_UPNPStatus == TCMPortMapProtocolWorks) {
        _sendUPNPMappingTableNotification = YES;
        [_UPNPPortMapper updatePortMappings];
    }
}


- (void)setMappingProtocol:(NSString *)aProtocol {
    _mappingProtocol = [aProtocol copy];
}

- (BOOL)isRunning {
    return _isRunning;
}

- (BOOL)isAtWork {
    return (_workCount > 0);
}

- (NSString *)routerIPAddress {
    SCDynamicStoreRef dynRef = SCDynamicStoreCreate(kCFAllocatorSystemDefault, (CFStringRef)@"TCMPortMapper", NULL, NULL); 
    NSDictionary *scobjects = (NSDictionary *)CFBridgingRelease(SCDynamicStoreCopyValue(dynRef,(CFStringRef)@"State:/Network/Global/IPv4" ));
    
    NSString *routerIPAddress = (NSString *)[scobjects objectForKey:(NSString *)kSCPropNetIPv4Router];
    routerIPAddress = [routerIPAddress copy];
    
    CFRelease(dynRef);
    return routerIPAddress;
}

- (NSString *)routerHardwareAddress {
    NSString *result = nil;
    NSString *routerAddress = [self routerIPAddress];
    if (routerAddress) {
        result = [self hardwareAddressForIPAddress:routerAddress];
    } 
    
    return result;
}

- (void)increaseWorkCount:(NSNotification *)aNotification {
#ifdef DEBUG
    NSLog(@"%s %d %@",__FUNCTION__,_workCount,aNotification);
#endif
    if (_workCount == 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperDidStartWorkNotification object:self];
    }
    _workCount++;
}

- (void)decreaseWorkCount:(NSNotification *)aNotification {
#ifdef DEBUG
    NSLog(@"%s %d %@",__FUNCTION__,_workCount,aNotification);
#endif
    _workCount--;
    if (_workCount == 0) {
        if (_UPNPStatus == TCMPortMapProtocolWorks && _sendUPNPMappingTableNotification) {
            [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperDidReceiveUPNPMappingTableNotification object:self userInfo:[NSDictionary dictionaryWithObject:[_UPNPPortMapper latestUPNPPortMappingsList] forKey:@"mappingTable"]];
            _sendUPNPMappingTableNotification = NO;
        }
    
        [[NSNotificationCenter defaultCenter] postNotificationName:TCMPortMapperDidFinishWorkNotification object:self];
        
        if (_completionBlock) {
            _completionBlock();
        }
    }
}

- (void)postWakeAction {
    _ignoreNetworkChanges = NO;
    if (_isRunning) {
        // take some time because on the moment of awakening e.g. airport isn't yet connected
        [self refresh];
    }
}


- (void)didWake:(NSNotification *)aNotification {
    // postpone the action because we need to wait for some delay until stuff is up. moreover we need to give the buggy mdnsresponder a chance to grab his nat-pmp port so we can do so later
    [self performSelector:@selector(postWakeAction) withObject:nil afterDelay:2.];
}

- (void)willSleep:(NSNotification *)aNotification {
#ifdef DEBUG
    NSLog(@"%s, pmp:%d, upnp:%d",__FUNCTION__,_NATPMPStatus,_UPNPStatus);
#endif
    _ignoreNetworkChanges = YES;
    if (_isRunning) {
        if (_NATPMPStatus == TCMPortMapProtocolWorks) {
            [_NATPMPPortMapper stopBlocking];
        }
        if (_UPNPStatus   == TCMPortMapProtocolWorks) {
            [_UPNPPortMapper stopBlocking];
        }
    }
}

- (void)NATPMPPortMapperDidReceiveBroadcastedExternalIPChange:(NSNotification *)aNotification {
    if (_isRunning) {
        NSDictionary *userInfo = [aNotification userInfo];
        // senderAddress is of the format <ipv4address>:<port>
        NSString *senderIPAddress = userInfo[@"senderAddress"];
        // we have to check if the sender is actually our router - if not disregard
        if ([senderIPAddress isEqualToString:[self routerIPAddress]]) {
            if (![[self externalIPAddress] isEqualToString:userInfo[@"externalIPAddress"]]) {
//                NSLog(@"Refreshing because of  NAT-PMP-Device external IP broadcast:%@",userInfo);
                [self refresh];
            }
        } else {
            NSLog(@"Got Information from rogue NAT-PMP-Device:%@",userInfo);
        }
    }
}

@end
