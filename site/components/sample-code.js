import { html } from 'goku';

const index = ["pages/index.md", `template: template.html
---
# Hello, world`];
const template = ["templates/template.html", `
{{& component.head }}

{{& component button.js }}
{{& content }}

{{& component.body }}`];

// There's a bug where the html returned from a component is then processed as markdown.
// I think it has to do with `allow_html: true`...
const button = ["components/button.js", `
// Custom button component
// A simple demo of a component within a Goku site.
// A component is a javascript module whose exports satisfy the component API.
// The component API might look like this typescript type:
// {
//   // Produce an HTML string to be injected at the point of usage.
//   render: () => string;
//   // Produce a JS string to be bundled in a script on a page where
//   // the component is used.
//   script?: () => string;
//   // Produce a CSS string to be bundled in a script on a page where
//   // the component is used.
//   style?: () => string;
// }

export render = () => '<button class="my-button">Click me!</button>';
export const script = * 
  Array.from(document.querySelectorAll(".my-button")).forEach((button) => {
    button.addEventListener("click", () => { console.log("Hello, world!"); });
  });
*;`];

const tabs = [index, template, button];

export const style = `
.sample-code, .sample-code pre, .sample-code code {
font-weight: bold;
}

.sample-code {
  position: relative;
  --tab-2: 179px;
  --tab-3: 426px;
  height: 380px;
  overflow: scroll;
}

.sample-code pre code {
  text-wrap: wrap;
}

details {
  position: absolute;
  top: 0;
  left: 0;
}

details ~ details {
  margin-left: var(--tab-2);
}
details ~ details ~ details {
  margin-left: var(--tab-3);
}
details pre {
}
details ~ details pre {
  margin-left: Calc(-1 * var(--tab-2));
}
details ~ details ~ details pre {
  margin-left: Calc(-1 * var(--tab-3));
}

summary {
padding: .5em 1em;
--bend: 15%;
border-radius: var(--bend) var(--bend) 0 0;
border: 1px solid black;
width: fit-content;
cursor: pointer;
}
summary {
  background: var(--bulma-info-soft-invert);
  color: var(--bulma-info-soft);
}
details[open] {
width: 100%;
}
details[open] pre {
width: 100%;
}
`;

export const render = () => html`<div class="sample-code">
<div class="container">
  ${tabs.map((tab, i) => html`<${Tab} title=${tab[0]} content=${tab[1]} open=${i==0}/>`)}
</div>
</div>
`;

function Tab(props) {
  const { title, content } = props;
  const is_open = props.open;

  return html`<details name="tab" open=${is_open}>
  <summary>${title}</summary>
  <pre><code>${content}</code></pre>
</details>`;

}

