const std = @import("std");
const natpmp = @import("natpmp");

const ClientErrors = error{
    NotEnoughArgs,
    InvalidProtocol,
    InvalidLifetime,
    MultipleGatewayAddresses,
    InvalidGatewayAddress,
};

/// Arguments expected to the port mapping function.
const MapArgs = struct {
    private_port: u16,
    public_port: u16,
    protocol: natpmp.NatPmpProtocol,
    lifetime: u32,
    gateway_addr: ?[4]u8,
};

/// Parse a gateway address from a string and return it.
fn parseGwAddr(string: [:0]const u8) ![4]u8 {
    var addr: [4]u8 = undefined;
    var octets = std.mem.splitSequence(u8, string, ".");
    var octet_pos: u3 = 0;
    while (octets.next()) |octet| {
        if (octet_pos == 4) {
            std.log.err("Too many octets in gateway address '{s}'", .{string});
            return error.InvalidGatewayAddress;
        }

        std.log.debug(
            "Found octet {d} of gateway address: {s}",
            .{ octet_pos, octet },
        );
        addr[octet_pos] = std.fmt.parseUnsigned(u8, octet, 10) catch |err| {
            std.log.err(
                "Failed to parse octet '{s}' in gateway address: {s}",
                .{ octet, @errorName(err) },
            );
            return error.InvalidGatewayAddress;
        };

        octet_pos += 1;
    }

    if (octet_pos < 4) {
        std.log.err("Not enough octets in gateway address '{s}'", .{string});
        return error.InvalidGatewayAddress;
    }

    return addr;
}

/// Format an IPv4 address as a number to a string.
fn splitOctets(addr: u32) ![4]u8 {
    const octet_0: u8 = @truncate(addr);
    const octet_1: u8 = @truncate(addr >> 8);
    const octet_2: u8 = @truncate(addr >> 16);
    const octet_3: u8 = @truncate(addr >> 24);
    return .{ octet_0, octet_1, octet_2, octet_3 };
}

/// Parse an unsigned integer number or print an error.
fn parseUint(comptime T: type, string: [:0]const u8) !T {
    return std.fmt.parseUnsigned(T, string, 10) catch |err| {
        std.log.err(
            "Failed to parse '{s}' as a {s}: {s}",
            .{ string, @typeName(T), @errorName(err) },
        );
        return error.InvalidPort;
    };
}

/// Parse arguments to the map command.
fn parseMapArgs(args_iter: *std.process.Args.Iterator) !MapArgs {
    var num_args: usize = 0;
    var args: [4]?[:0]const u8 = .{ null, null, null, null };
    var gateway_flag = false;
    var gateway_addr: ?[4]u8 = null;
    while (num_args < 4) {
        const next_arg = args_iter.next() orelse if (num_args < 3) {
            std.log.err("Not enough arguments.", .{});
            return error.NotEnoughArgs;
        } else break;

        if (gateway_flag) {
            if (gateway_addr != null) {
                std.log.err("You can only use one gateway address.", .{});
                return error.MultipleGatewayAddresses;
            }
            gateway_addr = try parseGwAddr(next_arg);
            gateway_flag = false;
        } else if (std.mem.eql(u8, next_arg, "-g")) {
            gateway_flag = true;
        } else {
            args[num_args] = next_arg;
            num_args += 1;
        }
    }

    const private_port = try parseUint(u16, args[0].?);
    const public_port = try parseUint(u16, args[1].?);
    const lifetime = if (args[3] != null)
        try parseUint(u32, args[3].?)
    else
        3600;

    var protocol: natpmp.NatPmpProtocol = undefined;
    if (std.mem.eql(u8, args[2].?, "tcp")) {
        protocol = natpmp.NatPmpProtocol.TCP;
    } else if (std.mem.eql(u8, args[2].?, "udp")) {
        protocol = natpmp.NatPmpProtocol.UDP;
    } else {
        std.log.err(
            "Unrecognised protocol {s}. Must be 'tcp' or 'udp'.",
            .{args[2].?},
        );
        return error.InvalidProtocol;
    }

    return .{
        .private_port = private_port,
        .public_port = public_port,
        .protocol = protocol,
        .lifetime = lifetime,
        .gateway_addr = gateway_addr,
    };
}

/// Request a port mapping.
fn mapPort(args: MapArgs) !u32 {
    if (args.gateway_addr != null) {
        std.log.info("Using {d}.{d}.{d}.{d} as the gateway address.", .{
            args.gateway_addr.?[0],
            args.gateway_addr.?[1],
            args.gateway_addr.?[2],
            args.gateway_addr.?[3],
        });
    }

    var client = try natpmp.initNatPmpClient(args.gateway_addr);
    try client.requestPublicAddress();
    const public_addr_response = try client.awaitResponse();

    const octets = try splitOctets(public_addr_response.resource.public_address);
    std.log.info(
        "Gateway has public address: {d}.{d}.{d}.{d}",
        .{ octets[0], octets[1], octets[2], octets[3] },
    );

    try client.requestPortMapping(
        args.protocol,
        args.private_port,
        args.public_port,
        args.lifetime,
    );

    const response = try client.awaitResponse();
    return response.resource.port_mapping.public_port;
}

fn help() void {
    std.log.info("TODO add some help text", .{});
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const cmd = args.next();

    if (cmd != null and std.mem.eql(u8, cmd.?, "map")) {
        const map_args = parseMapArgs(&args) catch |err| {
            std.log.err(
                "Argument parsing hit a fatal error: {s}",
                .{@errorName(err)},
            );
            help();
            std.process.exit(1);
        };

        const public_port = mapPort(map_args) catch |err| {
            std.log.err(
                "Port mapping request hit a fatal error: {s}",
                .{@errorName(err)},
            );
            std.process.exit(1);
        };

        std.log.info(
            "Successfully mapped private port {d} to public port {d}.",
            .{ map_args.private_port, public_port },
        );
    } else {
        if (cmd != null) std.log.err("Unknown command {s}", .{cmd.?});
        help();
        std.process.exit(1);
    }
}
