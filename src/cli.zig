const std = @import("std");
const client = @import("client.zig");
const natpmp = @import("natpmp");

const MapArgs = client.MapArgs;
const setupClient = client.setupClient;
const mapPort = client.mapPort;

/// Parse a gateway address from a string and return it.
fn parseGatewayAddr(string: [:0]const u8) ![4]u8 {
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
            gateway_addr = try parseGatewayAddr(next_arg);
            gateway_flag = false;
        } else if (std.mem.eql(u8, next_arg, "-g")) {
            gateway_flag = true;
        } else {
            args[num_args] = next_arg;
            num_args += 1;
        }
    }

    const public_port = try parseUint(u16, args[0].?);
    const private_port = try parseUint(u16, args[1].?);
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

/// Parse arguments to the gateway command.
fn parseGatewayArgs(args_iter: *std.process.Args.Iterator) !?[4]u8 {
    var gateway_flag = false;
    var gateway_addr: ?[4]u8 = null;

    while (args_iter.next()) |next_arg| {
        if (gateway_flag) {
            if (gateway_addr != null) {
                std.log.err("You can only use one gateway address.", .{});
                return error.MultipleGatewayAddresses;
            }
            gateway_addr = try parseGatewayAddr(next_arg);
        } else if (std.mem.eql(u8, next_arg, "-g")) {
            gateway_flag = true;
        } else {
            std.log.err("Unexpected argument: {s}", .{next_arg});
            return error.InvalidArgs;
        }
    }

    return gateway_addr;
}

const HELP_TEXT =
    \\
    \\natpmpctl  -  NAT-PMP client.
    \\
    \\Flags:
    \\  -g <gateway>
    \\    + The IPv4 address of the gateway to use.
    \\      If unset, your default gateway will be used.
    \\      Optional and usable with all commands.
    \\
    \\Commands:
    \\  gateway
    \\    + Request and print the public address of the gateway.
    \\
    \\  map <public port> <private port> <protocol> [lifetime]
    \\    + Request a mapping from the private port to the public port for
    \\      the given protocol.
    \\      + The public port is the port on the gateway's public interface that
    \\        will be used to exchange traffic with theoutside world.
    \\        The gateway may not use this value and assign you a random port.
    \\      + The private port is the port on this machine that can send and
    \\        receive traffic.
    \\      + The protocol must be either "tcp" or "udp". The gateway will only
    \\        forward traffic using this protocol.
    \\      + The lifetime is the requested lifetime for the mapping in seconds.
    \\        Again the gateway may not honour this value and use its own.
    \\        Defaults to 3600 seconds (1 hour).
;

/// Print the help text.
fn help() void {
    std.debug.print("{s}\n", .{HELP_TEXT});
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const cmd = args.next();

    if (cmd == null) {
        help();
        std.process.exit(1);
    }

    if (std.mem.eql(u8, cmd.?, "gateway")) {
        const gw_addr = parseGatewayArgs(&args) catch |err| {
            std.log.err(
                "Argument parsing hit a fatal error: {s}",
                .{@errorName(err)},
            );
            std.process.exit(1);
        };

        _ = setupClient(gw_addr) catch |err| {
            std.log.err(
                "Getting public gateway address hit a fatal error: {s}",
                .{@errorName(err)},
            );
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd.?, "map")) {
        const map_args = parseMapArgs(&args) catch |err| {
            std.log.err(
                "Argument parsing hit a fatal error: {s}",
                .{@errorName(err)},
            );
            help();
            std.process.exit(1);
        };

        _ = mapPort(map_args) catch |err| {
            std.log.err(
                "Port mapping request hit a fatal error: {s}",
                .{@errorName(err)},
            );
            std.process.exit(1);
        };
    } else {
        std.log.err("Unknown command {s}", .{cmd.?});
        help();
        std.process.exit(1);
    }
}
