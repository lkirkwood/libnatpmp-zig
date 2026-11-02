const std = @import("std");
const natpmp = @import("natpmp");

pub const ClientErrors = error{
    NotEnoughArgs,
    InvalidProtocol,
    InvalidLifetime,
    MultipleGatewayAddresses,
    InvalidGatewayAddress,
    ReallyBigPublicPort,
};

/// Format an IPv4 address as a number to a string.
fn splitOctets(addr: u32) ![4]u8 {
    const octet_0: u8 = @truncate(addr);
    const octet_1: u8 = @truncate(addr >> 8);
    const octet_2: u8 = @truncate(addr >> 16);
    const octet_3: u8 = @truncate(addr >> 24);
    return .{ octet_0, octet_1, octet_2, octet_3 };
}

/// Initialise a client, log the private and public gateway addresses,
/// and return the client.
pub fn setupClient(gateway_addr: ?[4]u8) !natpmp.Client {
    std.log.info("Using {d}.{d}.{d}.{d} as the gateway address.", .{
        gateway_addr.?[0],
        gateway_addr.?[1],
        gateway_addr.?[2],
        gateway_addr.?[3],
    });

    var client = try natpmp.initClient(gateway_addr);
    try client.requestPublicAddress();
    const response = try client.awaitResponse();
    const gw_addr = try splitOctets(response.resource.public_address);

    std.log.info(
        "Gateway has public address: {d}.{d}.{d}.{d}",
        .{ gw_addr[0], gw_addr[1], gw_addr[2], gw_addr[3] },
    );

    return client;
}

/// Arguments expected to the port mapping function.
pub const MapArgs = struct {
    private_port: u16,
    public_port: u16,
    protocol: natpmp.NatPmpProtocol,
    lifetime: u32,
    gateway_addr: ?[4]u8,
};

/// Request a port mapping and return the actual public port assigned.
pub fn mapPort(args: *const MapArgs) !natpmp.NatPmpPortMapping {
    var client = try setupClient(args.gateway_addr);

    try client.requestPortMapping(
        args.protocol,
        args.private_port,
        args.public_port,
        args.lifetime,
    );

    const response = try client.awaitResponse();
    const public_port = response.resource.port_mapping.public_port;

    std.log.info(
        "Successfully mapped private port {d} to public port {d}.",
        .{ args.private_port, public_port },
    );
    std.log.info(
        "Mapping has a lifetime of {d} seconds.",
        .{response.resource.port_mapping.lifetime},
    );

    return response.resource.port_mapping;
}

/// Persist a port mapping for the lifetime, or indefinitely if lifetime is 0.
/// Writes the public port assigned to stdout whenever it changes.
pub fn persistPort(io: std.Io, args: *MapArgs) !void {
    var now = std.Io.Clock.now(.boot, io);
    var deadline: ?std.Io.Timestamp = null;
    if (args.lifetime != 0) {
        deadline = now.addDuration(std.Io.Duration.fromSeconds(args.lifetime));
    }

    const stdout = std.Io.File.stdout();
    while (deadline == null or deadline.?.compare(.gt, now)) {
        const response = try mapPort(args);
        std.log.info(
            "Public port {d} mapped to {d} for {d} seconds.",
            .{ response.public_port, args.private_port, response.lifetime },
        );

        if (response.public_port != args.public_port) {
            args.public_port = response.public_port;
            var port_str_buf: [64]u8 = undefined;
            const port_str = std.fmt.bufPrint(
                &port_str_buf,
                "{d}\n",
                .{response.public_port},
            ) catch {
                std.log.err(
                    "Public port number somehow longer than 64 digits??",
                    .{},
                );
                return error.ReallyBigPublicPort;
            };
            stdout.writeStreamingAll(io, port_str) catch |err| {
                std.log.err(
                    "Failed to write public port to stdout: {s}",
                    .{@errorName(err)},
                );
                return err;
            };
        }

        const sleep_seconds = @max(0, response.lifetime - 10);
        try std.Io.sleep(io, .fromSeconds(sleep_seconds), .boot);

        now = std.Io.Clock.now(.boot, io);
    }
}
