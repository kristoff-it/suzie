const std = @import("std");
const hzzp = @import("hzzp");
const wz = @import("wz");
const ssl = @import("zig-bearssl");

const format = @import("format.zig");
const request = @import("request.zig");
const util = @import("util.zig");

const agent = "zigbot9001/0.0.1";
const suzie_id = "809094603680514088";

var NotifCooldown: std.StringHashMap(i64) = undefined;

fn roleIdFromGuild(gid: []const u8) ![]const u8 {
    const swh = util.Swhash(32);
    return switch (swh.match(gid)) {
        // Showtime
        swh.case("697519923273924658") => "759242430456660018",
        // Main
        swh.case("605571803288698900") => "813098928550969385",
        else => error.UnknownGuild,
    };
}

fn Buffer(comptime max_len: usize) type {
    return struct {
        data: [max_len]u8 = undefined,
        len: usize = 0,

        fn initFrom(data: []const u8) @This() {
            var result: @This() = undefined;
            std.mem.copy(u8, &result.data, data);
            result.len = data.len;
            return result;
        }

        fn slice(self: @This()) []const u8 {
            return self.data[0..self.len];
        }

        fn append(self: *@This(), char: u8) !void {
            if (self.len >= max_len) {
                return error.NoSpaceLeft;
            }
            self.data[self.len] = char;
            self.len += 1;
        }

        fn last(self: @This()) ?u8 {
            if (self.len > 0) {
                return self.data[self.len - 1];
            } else {
                return null;
            }
        }

        fn pop(self: *@This()) !u8 {
            return self.last() orelse error.Empty;
        }
    };
}

const Context = struct {
    allocator: *std.mem.Allocator,
    auth_token: []const u8,

    pub fn init(allocator: *std.mem.Allocator, auth_token: []const u8) !*Context {
        const result = try allocator.create(Context);
        errdefer allocator.destroy(result);

        result.allocator = allocator;
        result.auth_token = auth_token;

        return result;
    }

    pub fn toggleUserRole(
        self: Context,
        guild_id: []const u8,
        live_role_id: []const u8,
        user_id: []const u8,
        action: enum { add, rem },
    ) !void {
        var path_buf: [0x100]u8 = undefined;

        const method = if (action == .add) "PUT" else "DELETE";
        const path = try std.fmt.bufPrint(&path_buf, "/api/v8/guilds/{s}/members/{s}/roles/{s}", .{
            guild_id,
            user_id,
            live_role_id,
        });

        std.debug.print("\ntoggle: {e} {s} \n", .{ action, path });
        var req = try request.Https.init(.{
            .allocator = self.allocator,
            .pem = @embedFile("../discord-com-chain.pem"),
            .host = "discord.com",
            .method = method,
            .path = path,
        });
        defer req.deinit();

        try req.client.writeHeaderValue("Accept", "application/json");
        try req.client.writeHeaderValue("Content-Type", "application/json");
        try req.client.writeHeaderValue("Authorization", self.auth_token);

        try req.printSend("\n\n", .{});

        if (req.expectSuccessStatus()) |_| {
            try req.completeHeaders();
            return;
        } else |err| switch (err) {
            error.TooManyRequests => {
                try req.completeHeaders();

                var stream = util.streamJson(req.client.reader());
                const root = try stream.root();

                if (try root.objectMatch("retry_after")) |match| {
                    const sec = try match.value.number(f64);
                    // Don't bother trying for awhile
                    std.time.sleep(@floatToInt(u64, sec * std.time.ns_per_s));
                }
                return error.TooManyRequests;
            },
            else => {
                // var buf: [1024]u8 = undefined;
                // const n = try req.client.reader().readAll(&buf);
                // std.debug.print("toggle error: {s}\n", .{buf[0..n]});
                return err;
            },
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    NotifCooldown = std.StringHashMap(i64).init(&gpa.allocator);

    var auth_buf: [0x100]u8 = undefined;
    const context = try Context.init(
        &gpa.allocator,
        try std.fmt.bufPrint(&auth_buf, "Bot {s}", .{std.os.getenv("DISCORD_AUTH") orelse return error.AuthNotFound}),
    );

    var reconnect_wait: u64 = 1;
    while (true) {
        var discord_ws = DiscordWs.init(
            context.allocator,
            context.auth_token,
            DiscordWs.Intents{ .guild_presences = true },
        ) catch |err| {
            std.debug.print("Connect error: {s}\n", .{@errorName(err)});
            std.time.sleep(reconnect_wait * std.time.ns_per_s);
            reconnect_wait = std.math.min(reconnect_wait * 2, 30);
            continue;
        };
        reconnect_wait = 1;

        defer discord_ws.deinit();

        discord_ws.run(context, struct {
            fn handleDispatch(ctx: *Context, name: []const u8, data: anytype) !void {
                if (!std.mem.eql(u8, name, "PRESENCE_UPDATE")) {
                    return;
                }

                var user_id = Buffer(1024){};
                var guild_id = Buffer(1024){};
                var url = Buffer(1024){};
                var created_at: ?i64 = null;
                var details = Buffer(1024){};
                var found = false;
                var roles = std.ArrayList([]const u8).init(ctx.allocator);
                defer {
                    for (roles.items) |x| ctx.allocator.free(x);
                    roles.deinit();
                }

                while (try data.objectMatchAny(&[_][]const u8{
                    "user",
                    "roles",
                    "guild_id",
                    "activities",
                })) |match| {
                    const swh = util.Swhash(16);
                    switch (swh.match(match.key)) {
                        else => unreachable,
                        swh.case("user") => {
                            const id = (try match.value.objectMatch("id")) orelse return;

                            const len = (try id.value.stringBuffer(&user_id.data)).len;
                            user_id.len = len;

                            // Leave if it's ourselves
                            if (std.mem.eql(u8, suzie_id, user_id.slice())) return;

                            _ = try match.value.finalizeToken();
                        },
                        swh.case("guild_id") => {
                            const len = (try match.value.stringBuffer(&guild_id.data)).len;
                            guild_id.len = len;
                        },
                        swh.case("roles") => {
                            while (try match.value.arrayNext()) |elem| {
                                var r = try elem.stringReader();
                                try roles.append(try r.readAllAlloc(ctx.allocator, 1024));

                                // var buf: [100]u8 = undefined;
                                // const role = try elem.stringBuffer(&buf);
                                // if (std.mem.eql(u8, role, live_role_id)) {
                                //     has_live_role = true;
                                //     _ = try match.value.finalizeToken();
                                //     break;
                                // }
                            }
                        },
                        swh.case("activities") => {
                            //   [{
                            //        "url": "https://www.twitch.tv/kristoff_it",
                            //        "type": 1,
                            //        "state": "Science & Technology",
                            //        "name":"Twitch",
                            //        "id":"38840a5af62d1fb",
                            //        "details":"Discord bot in Zig, what could go bork?⚡ Come chat about #ziglang ⚡ https://zig.show",
                            //        "created_at":1612977937331,
                            //        "assets":{
                            //            "large_image":"twitch:kristoff_it"
                            //        }
                            //    }]
                            while (try match.value.arrayNext()) |elem| {
                                while (try elem.objectMatchAny(&[_][]const u8{
                                    "type",
                                    "created_at",
                                    "url",
                                    "details",
                                })) |act| {
                                    const aswh = util.Swhash(16);
                                    switch (aswh.match(act.key)) {
                                        else => unreachable,
                                        aswh.case("type") => {
                                            found = (try act.value.number(usize)) == 1;
                                        },
                                        aswh.case("created_at") => {
                                            created_at = try act.value.number(i64);
                                        },
                                        aswh.case("url") => {
                                            const len = (try act.value.stringBuffer(&url.data)).len;
                                            url.len = len;
                                        },
                                        aswh.case("details") => {
                                            const len = (try act.value.stringBuffer(&details.data)).len;
                                            details.len = len;
                                        },
                                    }
                                }
                                if (found) {
                                    _ = try match.value.finalizeToken();
                                    break;
                                }
                            }
                        },
                    }
                }

                const live_role_id = try roleIdFromGuild(guild_id.slice());
                const has_live_role = for (roles.items) |x| {
                    if (std.mem.eql(u8, x, live_role_id)) {
                        break true;
                    }
                } else false;

                // Only consider streams that have Zig and ⚡ in their title.
                found = found and
                    contains(details.slice(), "⚡") and
                    (contains(details.slice(), "Zig") or
                    contains(details.slice(), "zig") or
                    contains(details.slice(), "ZIG"));

                std.debug.print("\n\n>> found = {b} uid = {s} guild_id = {s} url = {s} time = {any} desc = {s}\n\n\n", .{
                    found,
                    user_id.slice(),
                    guild_id.slice(),
                    url.slice(),
                    created_at,
                    details.slice(),
                });
                if (found) {
                    if (!has_live_role) try ctx.toggleUserRole(guild_id.slice(), live_role_id, user_id.slice(), .add);
                } else {
                    if (has_live_role) try ctx.toggleUserRole(guild_id.slice(), live_role_id, user_id.slice(), .rem);
                }
            }
        }) catch |err| switch (err) {
            // TODO: investigate if IO localized enough. And possibly convert to ConnectionReset
            error.ConnectionReset, error.IO => continue,
            error.AuthenticationFailed => |e| return e,
            else => @panic(@errorName(err)),
        };

        std.debug.print("Exited: {}\n", .{discord_ws.client});
    }
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (std.mem.indexOf(u8, haystack, needle)) |_| {
        return true;
    }

    return false;
}

const DiscordWs = struct {
    allocator: *std.mem.Allocator,

    is_dying: bool,
    ssl_tunnel: *request.SslTunnel,

    client: wz.base.client.BaseClient(request.SslTunnel.Stream.DstReader, request.SslTunnel.Stream.DstWriter),
    client_buffer: []u8,
    write_mutex: std.Thread.Mutex,

    heartbeat_interval: usize,
    heartbeat_seq: ?usize,
    heartbeat_ack: bool,
    heartbeat_thread: *std.Thread,

    const Opcode = enum {
        /// An event was dispatched.
        dispatch = 0,
        /// Fired periodically by the client to keep the connection alive.
        heartbeat = 1,
        /// Starts a new session during the initial handshake.
        identify = 2,
        /// Update the client's presence.
        presence_update = 3,
        /// Used to join/leave or move between voice channels.
        voice_state_update = 4,
        /// Resume a previous session that was disconnected.
        @"resume" = 6,
        /// You should attempt to reconnect and resume immediately.
        reconnect = 7,
        /// Request information about offline guild members in a large guild.
        request_guild_members = 8,
        /// The session has been invalidated. You should reconnect and identify/resume accordingly.
        invalid_session = 9,
        /// Sent immediately after connecting, contains the heartbeat_interval to use.
        hello = 10,
        /// Sent in response to receiving a heartbeat to acknowledge that it has been received.
        heartbeat_ack = 11,
    };

    const Intents = packed struct {
        guilds: bool = false,
        guild_members: bool = false,
        guild_bans: bool = false,
        guild_emojis: bool = false,
        guild_integrations: bool = false,
        guild_webhooks: bool = false,
        guild_invites: bool = false,
        guild_voice_states: bool = false,
        guild_presences: bool = false,
        guild_messages: bool = false,
        guild_message_reactions: bool = false,
        guild_message_typing: bool = false,
        direct_messages: bool = false,
        direct_message_reactions: bool = false,
        direct_message_typing: bool = false,
        _pad: bool = undefined,

        fn toRaw(self: Intents) u16 {
            return @bitCast(u16, self);
        }

        fn fromRaw(raw: u16) Intents {
            return @bitCast(Intents, self);
        }
    };

    pub fn init(allocator: *std.mem.Allocator, auth_token: []const u8, intents: Intents) !*DiscordWs {
        const result = try allocator.create(DiscordWs);
        errdefer allocator.destroy(result);
        result.allocator = allocator;

        result.write_mutex = .{};

        result.ssl_tunnel = try request.SslTunnel.init(.{
            .allocator = allocator,
            .pem = @embedFile("../discord-gg-chain.pem"),
            .host = "gateway.discord.gg",
        });
        errdefer result.ssl_tunnel.deinit();

        result.client_buffer = try allocator.alloc(u8, 0x1000);
        errdefer allocator.free(result.client_buffer);

        result.client = wz.base.client.create(
            result.client_buffer,
            result.ssl_tunnel.conn.reader(),
            result.ssl_tunnel.conn.writer(),
        );

        // Handshake
        try result.client.handshakeStart("/?v=6&encoding=json");
        try result.client.handshakeAddHeaderValue("Host", "gateway.discord.gg");
        try result.client.handshake_client.finishHeaders(); // needed due to SSL flushing
        try result.ssl_tunnel.conn.flush();
        try result.client.handshakeFinish();

        if (try result.client.next()) |event| {
            std.debug.assert(event == .header);
        }

        result.is_dying = false;
        result.heartbeat_interval = 0;
        if (try result.client.next()) |event| {
            std.debug.assert(event == .chunk);

            var fba = std.io.fixedBufferStream(event.chunk.data);
            var stream = util.streamJson(fba.reader());

            const root = try stream.root();
            while (try root.objectMatchAny(&[_][]const u8{ "op", "d" })) |match| {
                const swh = util.Swhash(2);
                switch (swh.match(match.key)) {
                    swh.case("op") => {
                        const op = try std.meta.intToEnum(Opcode, try match.value.number(u8));
                        if (op != .hello) {
                            return error.MalformedHelloResponse;
                        }
                    },
                    swh.case("d") => {
                        while (try match.value.objectMatch("heartbeat_interval")) |hbi| {
                            result.heartbeat_interval = try hbi.value.number(u32);
                        }
                    },
                    else => unreachable,
                }
            }
        }

        if (result.heartbeat_interval == 0) {
            return error.MalformedHelloResponse;
        }

        const Activity = struct {
            @"type": u8,
            name: []const u8,
        };

        try result.sendCommand(.identify, .{
            .compress = false,
            .intents = intents.toRaw(),
            .token = auth_token,
            .properties = .{
                .@"$os" = @tagName(std.Target.current.os.tag),
                .@"$browser" = agent,
                .@"$device" = agent,
            },
            .presence = .{
                .status = "online",
                .activities = &[_]Activity{
                    .{
                        .@"type" = 0,
                        .name = "If your stream has Zig and ⚡ in the title I will promote it!",
                    },
                },
            },
        });

        result.heartbeat_seq = null;
        result.heartbeat_ack = true;
        result.heartbeat_thread = try std.Thread.spawn(heartbeatHandler, result);

        return result;
    }

    pub fn deinit(self: *DiscordWs) void {
        self.ssl_tunnel.deinit();

        self.is_dying = true;
        self.heartbeat_thread.wait();

        self.allocator.destroy(self);
    }

    pub fn run(self: *DiscordWs, ctx: anytype, handler: anytype) !void {
        while (try self.client.next()) |event| {
            // Skip over any remaining chunks. The processor didn't take care of it.
            if (event != .header) continue;

            switch (event.header.opcode) {
                .Text => {
                    self.processChunks(ctx, handler) catch |err| {
                        std.debug.print("Process chunks failed: {s}\n", .{err});
                    };
                },
                .Ping, .Pong => {},
                .Close => {
                    const body = (try self.client.next()) orelse {
                        std.debug.print("Websocket close frame - {{}}: no reason provided. Reconnecting...\n", .{});
                        return error.ConnectionReset;
                    };

                    const CloseEventCode = enum(u16) {
                        UnknownError = 4000,
                        UnknownOpcode = 4001,
                        DecodeError = 4002,
                        NotAuthenticated = 4003,
                        AuthenticationFailed = 4004,
                        AlreadyAuthenticated = 4005,
                        InvalidSeq = 4007,
                        RateLimited = 4008,
                        SessionTimedOut = 4009,
                        InvalidShard = 4010,
                        ShardingRequired = 4011,
                        InvalidApiVersion = 4012,
                        InvalidIntents = 4013,
                        DisallowedIntents = 4014,

                        pub fn format(code: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
                            try writer.print("{d}: {s}", .{ @enumToInt(code), @tagName(code) });
                        }
                    };

                    const code_num = std.mem.readIntBig(u16, body.chunk.data[0..2]);
                    const code = std.meta.intToEnum(CloseEventCode, std.mem.readIntBig(u16, body.chunk.data[0..2])) catch |err| switch (err) {
                        error.InvalidEnumTag => {
                            std.debug.print("Websocket close frame - {d}: unknown code. Reconnecting...\n", .{code_num});
                            return error.ConnectionReset;
                        },
                    };

                    switch (code) {
                        .UnknownError, .SessionTimedOut => {
                            std.debug.print("Websocket close frame - {}. Reconnecting...\n", .{code});
                            return error.ConnectionReset;
                        },

                        // Most likely user error
                        .AuthenticationFailed => return error.AuthenticationFailed,
                        .AlreadyAuthenticated => return error.AlreadyAuthenticated,
                        .DecodeError => return error.DecodeError,
                        .UnknownOpcode => return error.UnknownOpcode,
                        .RateLimited => return error.WoahNelly,
                        .DisallowedIntents => return error.DisallowedIntents,

                        // We don't support these yet
                        .InvalidSeq => unreachable,
                        .InvalidShard => unreachable,
                        .ShardingRequired => unreachable,
                        .InvalidApiVersion => unreachable,

                        // This library fucked up
                        .NotAuthenticated => unreachable,
                        .InvalidIntents => unreachable,
                    }
                },
                .Binary => return error.WtfBinary,
                else => return error.WtfWtf,
            }
        }
    }

    pub fn processChunks(self: *DiscordWs, ctx: anytype, handler: anytype) !void {
        const event = (try self.client.next()) orelse return error.NoBody;
        std.debug.assert(event == .chunk);

        var name_buf: [32]u8 = undefined;
        var name: ?[]u8 = null;
        var op: ?Opcode = null;

        var fba = std.io.fixedBufferStream(event.chunk.data);
        var stream = util.streamJson(fba.reader());
        const root = try stream.root();

        while (try root.objectMatchAny(&[_][]const u8{ "t", "s", "op", "d" })) |match| {
            const swh = util.Swhash(2);
            switch (swh.match(match.key)) {
                swh.case("t") => {
                    name = try match.value.optionalStringBuffer(&name_buf);
                },
                swh.case("s") => {
                    if (try match.value.optionalNumber(u32)) |seq| {
                        self.heartbeat_seq = seq;
                    }
                },
                swh.case("op") => {
                    op = try std.meta.intToEnum(Opcode, try match.value.number(u8));
                },
                swh.case("d") => {
                    switch (op orelse return error.DataBeforeOp) {
                        .dispatch => {
                            std.debug.print("<< {d} -- {s}\n", .{ self.heartbeat_seq, name });
                            try handler.handleDispatch(
                                ctx,
                                name orelse return error.DispatchWithoutName,
                                match.value,
                            );
                        },
                        .heartbeat_ack => {
                            std.debug.print("<< ♥\n", .{});
                            self.heartbeat_ack = true;
                        },
                        else => {},
                    }
                    _ = try match.value.finalizeToken();
                },
                else => unreachable,
            }
        }
    }

    pub fn sendCommand(self: *DiscordWs, opcode: Opcode, data: anytype) !void {
        var buf: [0x1000]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s}", .{
            format.json(.{
                .op = @enumToInt(opcode),
                .d = data,
            }),
        });

        const held = self.write_mutex.acquire();
        defer held.release();

        try self.client.writeHeader(.{ .opcode = .Text, .length = msg.len });
        try self.client.writeChunk(msg);

        try self.ssl_tunnel.conn.flush();
    }

    pub extern "c" fn shutdown(sockfd: std.os.fd_t, how: c_int) c_int;

    fn heartbeatHandler(self: *DiscordWs) void {
        while (true) {
            const start = std.time.milliTimestamp();
            // Buffer to fire early than late
            while (std.time.milliTimestamp() - start < self.heartbeat_interval - 1000) {
                std.time.sleep(std.time.ns_per_s);
                if (self.is_dying) {
                    return;
                }
            }

            if (!self.heartbeat_ack) {
                std.debug.print("Missed heartbeat. Reconnecting...\n", .{});
                const SHUT_RDWR = 2;
                const rc = shutdown(self.ssl_tunnel.tcp_conn.handle, SHUT_RDWR);
                if (rc != 0) {
                    std.debug.print("Shutdown failed: {d}\n", .{std.c.getErrno(rc)});
                }
                return;
            }

            self.heartbeat_ack = false;

            var retries: u6 = 0;
            while (self.sendCommand(.heartbeat, self.heartbeat_seq)) |_| {
                std.debug.print(">> ♡\n", .{});
                break;
            } else |err| {
                if (retries < 3) {
                    std.os.nanosleep(@as(u64, 1) << retries, 0);
                    retries += 1;
                } else {
                    const SHUT_RDWR = 2;
                    const rc = shutdown(self.ssl_tunnel.tcp_conn.handle, SHUT_RDWR);
                    if (rc != 0) {
                        std.debug.print("Shutdown failed: {d}\n", .{std.c.getErrno(rc)});
                    }
                    return;
                }
            }
        }
    }
};

test "" {
    _ = request;
    _ = util;
}
