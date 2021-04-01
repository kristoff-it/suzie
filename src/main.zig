const std = @import("std");
const zCord = @import("zCord");

const util = @import("util.zig");

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

        const path = try std.fmt.bufPrint(&path_buf, "/api/v8/guilds/{s}/members/{s}/roles/{s}", .{
            guild_id,
            user_id,
            live_role_id,
        });

        std.debug.print("\ntoggle: {e} {s} \n", .{ action, path });
        var req = try zCord.https.Request.init(.{
            .allocator = self.allocator,
            .host = "discord.com",
            .method = if (action == .add) .PUT else .DELETE,
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

                var stream = zCord.json.stream(req.client.reader());
                const root = try stream.root();

                if (try root.objectMatchOne("retry_after")) |match| {
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
    try zCord.root_ca.preload(std.heap.page_allocator);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    NotifCooldown = std.StringHashMap(i64).init(&gpa.allocator);

    var auth_buf: [0x100]u8 = undefined;
    const context = try Context.init(
        &gpa.allocator,
        try std.fmt.bufPrint(&auth_buf, "Bot {s}", .{std.os.getenv("DISCORD_AUTH") orelse return error.AuthNotFound}),
    );

    var c = try zCord.Client.create(.{
        .allocator = context.allocator,
        .auth_token = context.auth_token,
        .context = context,
        .intents = .{ .guild_presences = true },
    });
    defer c.destroy();

    try c.ws(struct {
        pub fn handleDispatch(client: *zCord.Client, name: []const u8, data: anytype) !void {
            if (!std.mem.eql(u8, name, "PRESENCE_UPDATE")) {
                return;
            }

            var user_id = Buffer(1024){};
            var guild_id = Buffer(1024){};
            var url = Buffer(1024){};
            var created_at: ?i64 = null;
            var details = Buffer(1024){};
            var found = false;
            var roles = std.ArrayList([]const u8).init(client.allocator);
            defer {
                for (roles.items) |x| client.allocator.free(x);
                roles.deinit();
            }

            while (try data.objectMatch(enum { user, roles, guild_id, activities })) |match| switch (match) {
                .user => |e_user| {
                    const id = (try e_user.objectMatchOne("id")) orelse return;

                    const len = (try id.value.stringBuffer(&user_id.data)).len;
                    user_id.len = len;

                    // Leave if it's ourselves
                    if (std.mem.eql(u8, suzie_id, user_id.slice())) return;
                },
                .guild_id => |e_guild_id| {
                    const len = (try e_guild_id.stringBuffer(&guild_id.data)).len;
                    guild_id.len = len;
                },
                .roles => |e_roles| {
                    while (try e_roles.arrayNext()) |elem| {
                        var r = try elem.stringReader();
                        try roles.append(try r.readAllAlloc(client.allocator, 1024));

                        // var buf: [100]u8 = undefined;
                        // const role = try elem.stringBuffer(&buf);
                        // if (std.mem.eql(u8, role, live_role_id)) {
                        //     has_live_role = true;
                        //     _ = try match.value.finalizeToken();
                        //     break;
                        // }
                    }
                },
                .activities => |e_activities| {
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
                    while (try e_activities.arrayNext()) |elem| {
                        while (try elem.objectMatch(enum { type, created_at, url, details })) |m| switch (m) {
                            .type => |e_type| {
                                found = (try e_type.number(usize)) == 1;
                            },
                            .created_at => |e_created_at| {
                                created_at = try e_created_at.number(i64);
                            },
                            .url => |e_url| {
                                const len = (try e_url.stringBuffer(&url.data)).len;
                                url.len = len;
                            },
                            .details => |e_details| {
                                const len = (try e_details.stringBuffer(&details.data)).len;
                                details.len = len;
                            },
                        };
                        if (found) {
                            break;
                        }
                    }
                    _ = try e_activities.finalizeToken();
                },
            };

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
                if (!has_live_role) try client.ctx(Context).toggleUserRole(guild_id.slice(), live_role_id, user_id.slice(), .add);
            } else {
                if (has_live_role) try client.ctx(Context).toggleUserRole(guild_id.slice(), live_role_id, user_id.slice(), .rem);
            }
        }
    });
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (std.mem.indexOf(u8, haystack, needle)) |_| {
        return true;
    }

    return false;
}
