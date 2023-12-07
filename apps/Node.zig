const std = @import("std");
const Tox = @import("tox");
const sodium = @import("sodium");
const Node = @This();
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const log = std.log.scoped(.Node);

fn connectionStatus(n: *Node, status: Tox.ConnectionStatus) void {
    const s = switch (status) {
        .none => "none",
        .tcp => "tcp",
        .udp => "udp",
    };
    log.info("{s} connection status: {s}", .{ n.name, s });
}

pub const Friend = struct {
    name: ?[]u8 = null,
    status_message: ?[]u8 = null,
    pub fn deinit(self: Friend, a: Allocator) void {
        if (self.name) |n| a.free(n);
    }
};

fn setOptionalString(
    comptime T: type,
    l: *ArrayList(T),
    i: usize,
    comptime field: []const u8,
    v: []const u8,
) void {
    if (l.*.items.len <= i) {
        l.*.resize(i + 1) catch @panic("allocation error");
        l.*.items[i] = T{};
    }
    const r = &@field(&l.*.items[i], field);
    if (r.*) |n| l.*.allocator.free(n);
    r.* = l.*.allocator.dupe(u8, v) catch @panic("allocation error");
}

fn friendNameCb(node: *Node, id: u32, name: []const u8) void {
    log.debug("{s} friend name: {d}->{s}", .{ node.name, id, name });
    setOptionalString(Friend, &node.friends, id, "name", name);
}

fn friendStatusMessageCb(node: *Node, id: u32, msg: []const u8) void {
    log.debug("{s} friend status message: {d}->{s}", .{ node.name, id, msg });
    setOptionalString(Friend, &node.friends, id, "status_message", msg);
}

allocator: Allocator,
tox: Tox,
name: []const u8,
friends: ArrayList(Friend),
timeout: u16,
keep_running: *bool,

pub const Options = struct {
    name: []const u8,
    secret_key: []const u8,
    nospam: u32,
    port: u16,
    timeout: u16,
    keep_running: *bool,
};

pub fn init(allocator: Allocator, opt: Options) !Node {
    var tox_opt = Tox.Options{};
    var secret_key_bin: [sodium.crypto_box.secret_key_size]u8 = undefined;
    tox_opt.savedata_type = .key;
    tox_opt.savedata_data = @ptrCast(try sodium.hex2bin(&secret_key_bin, opt.secret_key));
    tox_opt.start_port = opt.port;
    var self = Node{
        .allocator = allocator,
        .tox = try Tox.init(tox_opt),
        .name = opt.name,
        .friends = ArrayList(Friend).init(allocator),
        .timeout = opt.timeout,
        .keep_running = opt.keep_running,
    };
    self.tox.setNospam(opt.nospam);
    self.tox.connectionStatusCallback(*Node, connectionStatus);
    self.tox.friend.nameCallback(*Node, friendNameCb);
    self.tox.friend.statusMessageCallback(*Node, friendStatusMessageCb);
    return self;
}

pub fn deinit(self: Node) void {
    self.tox.deinit();
    for (self.friends.items) |i| i.deinit(self.allocator);
    self.friends.deinit();
}

pub fn setName(self: Node, name: []const u8, status_message: []const u8) !void {
    try self.tox.setName(name);
    try self.tox.setStatusMessage(status_message);
}

pub fn bootstrap(
    self: Node,
    bs_node_host: [:0]const u8,
    bs_node_port: u16,
    bs_node_public_key_hex: []const u8,
) !void {
    var bs_node_public_key_bin: [sodium.crypto_box.public_key_size]u8 = undefined;
    try self.tox.bootstrap(
        bs_node_host,
        bs_node_port,
        try sodium.hex2bin(
            &bs_node_public_key_bin,
            bs_node_public_key_hex,
        ),
    );
}

pub fn getAddress(self: Node) ![]const u8 {
    var addr_bin: [Tox.address_size]u8 = undefined;
    try self.tox.getAddress(&addr_bin);
    var addr_hex: [sodium.hexSizeForBin(Tox.address_size)]u8 = undefined;
    return try sodium.bin2hex(&addr_hex, &addr_bin, true);
}

pub fn friendAdd(self: Node, friend_address: []const u8, message: []const u8) !u32 {
    var rpn_addr_bin: [Tox.address_size]u8 = undefined;
    _ = try sodium.hex2bin(&rpn_addr_bin, friend_address);
    return try self.tox.friend.add(&rpn_addr_bin, message);
}

pub fn friendAddNoRequest(self: Node, friend_address: []const u8) !u32 {
    var rpn_addr_bin: [Tox.address_size]u8 = undefined;
    _ = try sodium.hex2bin(&rpn_addr_bin, friend_address);
    return try self.tox.friend.addNoRequest(&rpn_addr_bin);
}

pub fn friendByPublicKey(self: Node, public_key_hex: []const u8) !u32 {
    var public_key_bin: [sodium.crypto_box.public_key_size]u8 = undefined;
    return try self.tox.friend.byPublicKey(
        try sodium.hex2bin(&public_key_bin, public_key_hex),
    );
}

pub fn check(
    self: *Node,
    comptime list: []const u8,
    id: usize,
    comptime field: []const u8,
    value: []const u8,
) !void {
    const l = &@field(self.*, list);
    var foundFalseValue: bool = false;
    var falseValue: []const u8 = undefined;
    var wait = false;
    const t0 = std.time.milliTimestamp();
    while (@atomicLoad(bool, self.*.keep_running, .SeqCst)) {
        if (l.*.items.len > id) {
            if (@field(l.*.items[id], field)) |v| {
                if (std.mem.eql(u8, v, value)) {
                    return;
                } else {
                    foundFalseValue = true;
                    falseValue = v;
                }
            }
        }
        const t1 = std.time.milliTimestamp();
        if (t1 - t0 > self.*.timeout) {
            // timeout reached
            if (foundFalseValue) {
                log.err(
                    "{s} check for {s} in {s}: timeout, expected '{s}', found '{s}'.",
                    .{ self.name, list, field, value, falseValue },
                );
            } else {
                log.err(
                    "{s} check for {s} in {s}: timeout, no value found.",
                    .{ self.name, list, field },
                );
            }
            return error.Timeout;
        }
        if (@atomicLoad(bool, self.*.keep_running, .SeqCst) and wait) {
            std.time.sleep(self.*.tox.iterationInterval() * 1000 * 1000);
        }
        self.*.tox.iterate(self);
        wait = true;
    }
}
