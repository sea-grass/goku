export const Page = union(enum) {
    markdown: struct {
        frontmatter: []const u8,
        data: []const u8,
    },
};
