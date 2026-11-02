const std = @import("std");
const natpmp = @import("natpmp");

pub const ClientErrors = error{
    NotEnoughArgs,
    InvalidProtocol,
    InvalidLifetime,
    MultipleGatewayAddresses,
    InvalidGatewayAddress,
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
pub fn mapPort(args: MapArgs) !u32 {
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

    return response.resource.port_mapping.public_port;
}
