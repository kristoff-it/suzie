const std = @import("std");
const zCord = @import("zCord");

const util = @import("util.zig");

var NotifCooldown: std.StringHashMap(i64) = undefined;

fn roleIdFromGuild(gid: zCord.Snowflake(.guild)) !zCord.Snowflake(.role) {
    return switch (@enumToInt(gid)) {
        // Showtime
        697519923273924658 => zCord.Snowflake(.role).init(759242430456660018),
        // Main
        605571803288698900 => zCord.Snowflake(.role).init(813098928550969385),
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

pub fn main() !void {
    try zCord.root_ca.preload(std.heap.page_allocator);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    NotifCooldown = std.StringHashMap(i64).init(&gpa.allocator);

    var auth_buf: [0x100]u8 = undefined;

    const c = try zCord.Client.create(.{
        .allocator = &gpa.allocator,
        .auth_token = try std.fmt.bufPrint(&auth_buf, "Bot {s}", .{std.os.getenv("DISCORD_AUTH") orelse return error.AuthNotFound}),
        .intents = .{ .guild_presences = true },
        .presence = .{
            .status = .online,
            .activities = &[_]zCord.Gateway.Activity{
                .{
                    .@"type" = .Game,
                    .name = "If your stream has Zig and ⚡ anywhere in the title I will promote it!",
                },
            },
        },
    });
    defer c.destroy();

    try c.ws(struct {
        pub fn handleDispatch(client: *zCord.Client, name: []const u8, data: anytype) !void {
            if (!std.mem.eql(u8, name, "PRESENCE_UPDATE")) {
                return;
            }

            var user_id = zCord.Snowflake(.user).init(0);
            var guild_id = zCord.Snowflake(.guild).init(0);
            var url = Buffer(1024){};
            var created_at: ?i64 = null;
            var details = Buffer(1024){};
            var found = false;
            var roles = std.ArrayList(zCord.Snowflake(.role)).init(client.allocator);
            defer roles.deinit();

            while (try data.objectMatch(enum { user, roles, guild_id, activities })) |match| switch (match) {
                .user => |e_user| {
                    const id = (try e_user.objectMatchOne("id")) orelse return;

                    user_id = try zCord.Snowflake(.user).consumeJsonElement(id.value);

                    // Leave if it's ourselves
                    if (client.connect_info.?.user_id == user_id) return;

                    _ = try e_user.finalizeToken();
                },
                .guild_id => |e_guild_id| {
                    guild_id = try zCord.Snowflake(.guild).consumeJsonElement(e_guild_id);
                    _ = try e_guild_id.finalizeToken();
                },
                .roles => |e_roles| {
                    while (try e_roles.arrayNext()) |elem| {
                        try roles.append(try zCord.Snowflake(.role).consumeJsonElement(elem));
                        // var buf: [100]u8 = undefined;
                        // const role = try elem.stringBuffer(&buf);
                        // if (std.mem.eql(u8, role, live_role_id)) {
                        //     has_live_role = true;
                        //     _ = try match.value.finalizeToken();
                        //     break;
                        // }
                    }
                    _ = try e_roles.finalizeToken();
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

            const live_role_id = try roleIdFromGuild(guild_id);
            const has_live_role = for (roles.items) |x| {
                if (x == live_role_id) {
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
                user_id,
                guild_id,
                url.slice(),
                created_at,
                details.slice(),
            });
            if (found) {
                if (!has_live_role) try toggleUserRole(client, guild_id, live_role_id, user_id, .add);
            } else {
                if (has_live_role) try toggleUserRole(client, guild_id, live_role_id, user_id, .rem);
            }
        }

        pub fn toggleUserRole(
            client: *zCord.Client,
            guild_id: zCord.Snowflake(.guild),
            live_role_id: zCord.Snowflake(.role),
            user_id: zCord.Snowflake(.user),
            action: enum { add, rem },
        ) !void {
            var path_buf: [0x100]u8 = undefined;

            const path = try std.fmt.bufPrint(&path_buf, "/api/v8/guilds/{s}/members/{s}/roles/{s}", .{
                guild_id,
                user_id,
                live_role_id,
            });

            std.debug.print("\ntoggle: {e} {s} \n", .{ action, path });
            var req = try client.sendRequest(
                client.allocator,
                if (action == .add) .PUT else .DELETE,
                path,
                "\n\n",
            );
            defer req.deinit();

            if (req.response_code.?.group() == .success) {
                try req.completeHeaders();
                return;
            } else switch (req.response_code.?) {
                .client_too_many_requests => {
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
                    return error.UnknownResponse;
                },
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
