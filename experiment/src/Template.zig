const Template = @This();

file: File,

pub const Map = std.StringHashMap(*Template);

const File = @import("File.zig");
const std = @import("std");
