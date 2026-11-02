const std = @import("std");
const Io = std.Io;

const natpmp = @import("natpmp_c");

/// The primary type from the C library that stores all the data.
const NatPmp = natpmp.natpmp_t;
/// A time value.
const NatPmpTimeVal = natpmp.struct_timeval;

/// Various errors that the different operations can return.
pub const NatPmpError = error{
    /// Some unknown return code from the C library.
    UnknownError,
    /// The response to the last request was not returned before the timeout.
    TimeoutError,
    /// Polling for the gateway response returned an error,
    /// check `last_errno` on the client for details.
    ResponsePollError,
    /// Invalid arguments to the function.
    InvalidArgs,
    /// `socket()` failed, check `last_errno` on the client for details.
    SocketError,
    /// Can't get the default gateway IP.
    CannotGetGateway,
    /// `close()` failed, check `last_errno` on the client for details.
    CloseError,
    /// `recvfrom()` failed, check `last_errno` on the client for details.
    RecvFromError,
    /// `readnatpmpresponseorretry()` was called while no
    /// NAT-PMP request was pending.
    NoPendingRequest,
    /// The gateway does not support NAT-PMP.
    NoGatewaySupport,
    /// The request required too many retries to get a response.
    /// The gateway likely does not support the protocol.
    TooManyRetries,
    /// `connect()` failed, check `last_errno` on the client for details.
    ConnectError,
    /// Packet was not received from the network gateway.
    WrongPacketSource,
    /// `send()` failed, check `last_errno` on the client for details.
    SendError,
    /// `fcntl()` failed, check `last_errno` on the client for details.
    FcntlError,
    /// `gettimeofday()` failed, check `last_errno` on
    /// the client for details.
    GetTimeOfDayError,
    /// This version of the library doesn't support the
    /// gateway's version of NAT-PMP.
    UnsupportedVersion,
    /// The gateway doesn't support the requested opcode.
    UnsupportedOpcode,
    /// The server refused the request as not authorized.
    NotAuthorized,
    /// The server reported a network failure.
    NetworkFailure,
    /// The server is out of resources.
    OutOfResources,
    /// No data available for the moment. Try again later.
    TryAgain,
};

/// The transport protocol to use when requesting a port mapping.
pub const NatPmpProtocol = enum(c_int) {
    UDP = 1,
    TCP = 2,
};

/// A port mapping from a local `private_port` to `public_port` on the gateway,
/// living for `lifetime` seconds from `epoch` the timestamp in the response.
pub const NatPmpPortMapping = struct {
    protocol: NatPmpProtocol,
    private_port: u16,
    public_port: u16,
    lifetime: u32,
};

/// A resource returned as part of a response to a gateway request.
pub const NatPmpResource = union {
    public_address: u32,
    port_mapping: NatPmpPortMapping,
};

/// A response from a gateway request, and the resource requested.
/// If you have this object, you probably don't need to check `resultcode`.
pub const NatPmpResponse = struct {
    epoch: u32,
    resultcode: u16,
    resource: NatPmpResource,
};

/// A single connection to a single NAT-PMP gateway.
///
/// You probably want to call `requestPublicAddress`,
/// which gets and stores the address of the gateway,
/// and then `requestPortMapping`.
///
/// You can get the response by either looping on
/// `getPendingResponse` or just calling `awaitPendingResponse`
/// which will poll and retry for you.
pub const Client = struct {
    const This = @This();

    c_obj: NatPmp,
    last_errno: *c_int,
    public_address: ?u32,

    /// Requests and stores the public address of the gateway.
    /// You should call this before you request a port mapping.
    pub fn requestPublicAddress(self: *This) !void {
        switch (natpmp.sendpublicaddressrequest(&self.c_obj)) {
            2 => return,
            natpmp.NATPMP_ERR_INVALIDARGS => return error.InvalidArgs,
            natpmp.NATPMP_ERR_SENDERR => {
                self.last_errno = std.c._errno();
                return error.SendError;
            },
            else => return error.UnknownError,
        }
    }

    /// Request a port mapping from `private_port` on this
    /// machine to `public_port` on the gateway.
    /// The public port requested is a suggestion. The return value of this
    /// function is the actual public port used in the mapping.
    ///
    /// Only packets sent using `protocol` will be forwarded by the gateway.
    ///
    /// If `lifetime` is zero, the port mapping will be cleared.
    /// You can use `clearPortMapping` for this.
    /// If both ports are also zero, all port mappings for that protocol
    /// will be cleared. You can use `clearAllPortMappings` for this.
    pub fn requestPortMapping(
        self: *This,
        protocol: NatPmpProtocol,
        private_port: u16,
        public_port: u16,
        lifetime: u32,
    ) !void {
        const retcode = natpmp.sendnewportmappingrequest(
            &self.c_obj,
            @backingInt(protocol),
            private_port,
            public_port,
            lifetime,
        );

        switch (retcode) {
            12 => return,
            natpmp.NATPMP_ERR_INVALIDARGS => return error.InvalidArgs,
            natpmp.NATPMP_ERR_SENDERR => {
                self.last_errno = std.c._errno();
                return error.SendError;
            },
            else => return error.UnknownError,
        }
    }

    /// Clear a specific port mapping.
    pub fn clearPortMapping(
        self: *This,
        protocol: NatPmpProtocol,
        private_port: u16,
        public_port: u16,
    ) !void {
        return self.requestPortMapping(
            protocol,
            private_port,
            public_port,
            0,
        );
    }

    /// Clear all port mappings for the specified protocol.
    pub fn clearAllPortMappings(self: *This, protocol: NatPmpProtocol) !void {
        return self.requestPortMapping(protocol, 0, 0, 0);
    }

    /// Get the pending response if one is ready.
    /// If the response is `error.TryAgain`,
    /// the pending request will be sent again.
    pub fn getPendingResponse(self: *This) !NatPmpResponse {
        var response: natpmp.natpmpresp_t = undefined;

        try self.handleResponseError(
            natpmp.readnatpmpresponseorretry(&self.c_obj, &response),
        );

        if (response.type == natpmp.NATPMP_RESPTYPE_PUBLICADDRESS) {
            const addr = response.pnu.publicaddress.addr.s_addr;
            self.public_address = addr;
            return NatPmpResponse{
                .epoch = response.epoch,
                .resultcode = response.resultcode,
                .resource = .{
                    .public_address = addr,
                },
            };
        }

        var protocol: NatPmpProtocol = undefined;
        switch (response.type) {
            natpmp.NATPMP_RESPTYPE_UDPPORTMAPPING => {
                protocol = .UDP;
            },
            natpmp.NATPMP_RESPTYPE_TCPPORTMAPPING => {
                protocol = .TCP;
            },
            else => return error.UnknownError,
        }

        const mapping = response.pnu.newportmapping;
        return NatPmpResponse{
            .epoch = response.epoch,
            .resultcode = response.resultcode,
            .resource = .{
                .port_mapping = .{
                    .protocol = protocol,
                    .private_port = mapping.privateport,
                    .public_port = mapping.mappedpublicport,
                    .lifetime = mapping.lifetime,
                },
            },
        };
    }

    /// Poll the socket being used for the connection until it receives
    /// a response, and retry the request when its safe to do so.
    pub fn awaitResponse(self: *This) !NatPmpResponse {
        var retries: u4 = 0;
        while (retries < 10) {
            const response = self._awaitResponse() catch |err| {
                if (err == error.TryAgain) {
                    retries += 1;
                    continue;
                }
                return err;
            };
            return response;
        }

        std.log.err(
            "Failed to get the response from the gateway after {d} retries.",
            .{retries},
        );
        std.log.err("The gateway might not support the protocol,", .{});
        std.log.err("or it might have it disabled for your client.", .{});
        return error.TooManyRetries;
    }

    /// Actual logic for `awaitResponse` inside retry loop.
    fn _awaitResponse(self: *This) !NatPmpResponse {
        var timeout_val: NatPmpTimeVal = undefined;
        var timeout_ms: i32 = undefined;
        switch (natpmp.getnatpmprequesttimeout(&self.c_obj, &timeout_val)) {
            0 => {
                var _timeout_ms = (1000 * timeout_val.tv_sec);
                _timeout_ms += @divTrunc(timeout_val.tv_usec, 1000);
                timeout_ms = @intCast(@max(0, _timeout_ms));
            },
            natpmp.NATPMP_ERR_INVALIDARGS => return error.InvalidArgs,
            natpmp.NATPMP_ERR_GETTIMEOFDAYERR => return error.GetTimeOfDayError,
            natpmp.NATPMP_ERR_NOPENDINGREQ => return error.NoPendingRequest,
            else => return error.UnknownError,
        }

        var fds: [1]std.posix.pollfd = .{.{
            .fd = self.c_obj.s,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        _ = try std.posix.poll(&fds, timeout_ms);

        return self.getPendingResponse();
    }

    /// Handle a `readnatpmpresponseorretry` return code.
    /// Sets `self.last_errno` for the various errors that use it.
    fn handleResponseError(self: *This, retcode: c_int) !void {
        switch (retcode) {
            0 => return, // continue to response processing
            natpmp.NATPMP_ERR_INVALIDARGS => {
                return error.InvalidArgs;
            },
            natpmp.NATPMP_ERR_RECVFROM => {
                self.last_errno = std.c._errno();
                return error.RecvFromError;
            },
            natpmp.NATPMP_ERR_NOPENDINGREQ => {
                return error.NoPendingRequest;
            },
            natpmp.NATPMP_ERR_NOGATEWAYSUPPORT => {
                self.last_errno = std.c._errno();
                return error.NoGatewaySupport;
            },
            natpmp.NATPMP_ERR_WRONGPACKETSOURCE => {
                return error.WrongPacketSource;
            },
            natpmp.NATPMP_ERR_UNSUPPORTEDVERSION => {
                return error.UnsupportedVersion;
            },
            natpmp.NATPMP_ERR_UNSUPPORTEDOPCODE => {
                return error.UnsupportedOpcode;
            },
            natpmp.NATPMP_ERR_NOTAUTHORIZED => {
                return error.NotAuthorized;
            },
            natpmp.NATPMP_ERR_NETWORKFAILURE => {
                return error.NetworkFailure;
            },
            natpmp.NATPMP_ERR_OUTOFRESOURCES => {
                return error.OutOfResources;
            },
            natpmp.NATPMP_TRYAGAIN => {
                return error.TryAgain;
            },
            else => return error.UnknownError,
        }
    }

    /// Free all the resources associated with this client and destroy it.
    pub fn deinit(self: *This) !void {
        switch (natpmp.closenatpmp(&self.c_obj)) {
            0 => return,
            natpmp.NATPMP_ERR_INVALIDARGS => return error.InvalidArgs,
            natpmp.NATPMP_ERR_CLOSEERR => {
                self.last_errno = std.c._errno();
                return error.CloseError;
            },
            else => return error.UnknownError,
        }
    }
};

/// Initialise a `Client`.
/// You must call `deinit` on the object when you're done.
///
/// If the gateway address is not supplied it will be
/// detected automatically. It must be given in network byte
/// order, so last octet first i.e. 192.168.1.1 would be:
/// `[1, 1, 168, 192]`
pub fn initClient(gateway_addr: ?[4]u8) !Client {
    var obj: NatPmp = undefined;

    var force_gw: c_int = undefined;
    var forced_gw: u32 = undefined;
    if (gateway_addr == null) {
        force_gw = 0;
        forced_gw = 0;
    } else {
        force_gw = 1;
        forced_gw = @bitCast(gateway_addr.?);
    }

    return switch (natpmp.initnatpmp(&obj, force_gw, forced_gw)) {
        0 => Client{
            .c_obj = obj,
            .last_errno = undefined,
            .public_address = null,
        },
        natpmp.NATPMP_ERR_INVALIDARGS => error.InvalidArgs,
        natpmp.NATPMP_ERR_SOCKETERROR => error.SocketError,
        natpmp.NATPMP_ERR_CANNOTGETGATEWAY => error.CannotGetGateway,
        natpmp.NATPMP_ERR_CONNECTERR => error.ConnectError,
        natpmp.NATPMP_ERR_FCNTLERROR => error.FcntlError,
        else => error.UnknownError,
    };
}

test "trigger build" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Client);
}
