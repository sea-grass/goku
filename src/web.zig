pub const Web = struct {
    pub const HTML = struct {
        // All elements
        // Purposefully does not include obsolete_and_deprecated_elements
        pub const all_elements = list: {
            var list: []const []const u8 = &.{};

            for (&.{
                Web.HTML.Element.main_root,
                Web.HTML.Element.document_metadata,
                Web.HTML.Element.sectioning_root,
                Web.HTML.Element.content_sectioning,
                Web.HTML.Element.text_content,
                Web.HTML.Element.inline_text_semantics,
                Web.HTML.Element.image_and_multimedia,
                Web.HTML.Element.embedded_content,
                Web.HTML.Element.svg_and_mathml,
                Web.HTML.Element.scripting,
                Web.HTML.Element.demarcating_edits,
                Web.HTML.Element.table_content,
                Web.HTML.Element.forms,
                Web.HTML.Element.interactive_elements,
                Web.HTML.Element.web_components,
            }) |namespace| {
                for (@typeInfo(namespace).Struct.decls) |decl| {
                    list = list ++ [_][]const u8{decl.name};
                }
            }

            break :list list;
        };

        // @see {https://developer.mozilla.org/en-US/docs/Web/HTML/Element}
        pub const Element = struct {
            pub const main_root = struct {
                pub const html = struct {};
            };

            pub const document_metadata = struct {
                pub const base = struct {};
                pub const head = struct {};
                pub const link = struct {};
                pub const meta = struct {};
                pub const style = struct {};
                pub const title = struct {};
            };

            pub const sectioning_root = struct {
                pub const body = struct {};
            };

            pub const content_sectioning = struct {
                pub const address = struct {};
                pub const article = struct {};
                pub const aside = struct {};
                pub const footer = struct {};
                pub const header = struct {};
                pub const h1 = struct {};
                pub const h2 = struct {};
                pub const h3 = struct {};
                pub const h4 = struct {};
                pub const h5 = struct {};
                pub const h6 = struct {};
                pub const hgroup = struct {};
                pub const main = struct {};
                pub const nav = struct {};
                pub const section = struct {};
                pub const search = struct {};
            };

            pub const text_content = struct {
                pub const blockquote = struct {};
                pub const dd = struct {};
                pub const div = struct {};
                pub const dl = struct {};
                pub const dt = struct {};
                pub const figcaption = struct {};
                pub const figure = struct {};
                pub const hr = struct {};
                pub const li = struct {};
                pub const menu = struct {};
                pub const ol = struct {};
                pub const p = struct {};
                pub const pre = struct {};
                pub const ul = struct {};
            };

            pub const inline_text_semantics = struct {
                pub const a = struct {};
                pub const abbr = struct {};
                pub const b = struct {};
                pub const bdi = struct {};
                pub const bdo = struct {};
                pub const br = struct {};
                pub const cite = struct {};
                pub const code = struct {};
                pub const data = struct {};
                pub const dfn = struct {};
                pub const em = struct {};
                pub const i = struct {};
                pub const kbd = struct {};
                pub const mark = struct {};
                pub const q = struct {};
                pub const rp = struct {};
                pub const rt = struct {};
                pub const ruby = struct {};
                pub const s = struct {};
                pub const samp = struct {};
                pub const small = struct {};
                pub const span = struct {};
                pub const strong = struct {};
                pub const sub = struct {};
                pub const sup = struct {};
                pub const time = struct {};
                pub const u = struct {};
                pub const @"var" = struct {};
                pub const wbr = struct {};
            };

            pub const image_and_multimedia = struct {
                pub const area = struct {};
                pub const audio = struct {};
                pub const img = struct {};
                pub const map = struct {};
                pub const track = struct {};
                pub const video = struct {};
            };

            pub const embedded_content = struct {
                pub const embed = struct {};
                pub const iframe = struct {};
                pub const object = struct {};
                pub const picture = struct {};
                pub const portal = struct {};
                pub const source = struct {};
            };

            pub const svg_and_mathml = struct {
                pub const svg = struct {};
                pub const math = struct {};
            };

            pub const scripting = struct {
                pub const canvas = struct {};
                pub const noscript = struct {};
                pub const script = struct {};
            };

            pub const demarcating_edits = struct {
                pub const del = struct {};
                pub const ins = struct {};
            };

            pub const table_content = struct {
                pub const caption = struct {};
                pub const col = struct {};
                pub const colgroup = struct {};
                pub const table = struct {};
                pub const tbody = struct {};
                pub const td = struct {};
                pub const tfoot = struct {};
                pub const th = struct {};
                pub const thead = struct {};
                pub const tr = struct {};
            };

            pub const forms = struct {
                pub const button = struct {};
                pub const datalist = struct {};
                pub const fieldset = struct {};
                pub const form = struct {};
                pub const input = struct {};
                pub const label = struct {};
                pub const legend = struct {};
                pub const meter = struct {};
                pub const optgroup = struct {};
                pub const option = struct {};
                pub const output = struct {};
                pub const progress = struct {};
                pub const select = struct {};
                pub const textarea = struct {};
            };

            pub const interactive_elements = struct {
                pub const details = struct {};
                pub const dialog = struct {};
                pub const summary = struct {};
            };

            pub const web_components = struct {
                pub const slot = struct {};
                pub const template = struct {};
            };

            pub const obsolete_and_deprecated_elements = struct {
                pub const acronym = struct {};
                pub const big = struct {};
                pub const center = struct {};
                pub const content = struct {};
                pub const dir = struct {};
                pub const font = struct {};
                pub const frame = struct {};
                pub const frameset = struct {};
                pub const image = struct {};
                pub const marquee = struct {};
                pub const menuitem = struct {};
                pub const nobr = struct {};
                pub const noembed = struct {};
                pub const noframes = struct {};
                pub const param = struct {};
                pub const plaintext = struct {};
                pub const rb = struct {};
                pub const rtc = struct {};
                pub const shadow = struct {};
                pub const strike = struct {};
                pub const tt = struct {};
                pub const xmp = struct {};
            };
        };
    };
};
