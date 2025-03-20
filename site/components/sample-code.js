import { html } from 'goku';

const index = ["pages/index.md", `template: template.html
title: Hello, world
---
# Hello, world`];
const template = ["templates/template.html", `<!doctype html>
<html>
<head>
{{& title}}
{{& theme.head}}
{{& component.head }}
</head>
<body>
  <h1>{{& title}}</h1>
  {{& component button.js }}
  <div class="content">
    {{& content }}
  </div>
  {{& theme.body}}
  {{& component.body }}
</body>
</html>`];

// There's a bug where the html returned from a component is then processed as markdown.
// I think it has to do with `allow_html: true`...
const button = ["components/button.js", `export const render = () => '<button class="my-btn">Click me!</button>';
export const script = "
  Array.from(document.querySelectorAll(".my-button")).forEach((button) => {
    button.addEventListener("click", () => { console.log("Hello, world!"); });
  });
"`];

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
  overflow: hidden;
}

.sample-code pre {
pointer-events: all;
max-height: 200px;
overflow-y: scroll;
text-wrap: wrap;
}

.sample-code pre code {
  text-wrap: wrap;
}

details {
  position: absolute;
  top: 0;
  left: 0;
}

details ~ details summary {
  margin-left: var(--tab-2);
}
details ~ details ~ details summary {
  margin-left: var(--tab-3);
}

details {
  pointer-events: none;
  width: 100%;
}

details summary {
  pointer-events: all;
  text-wrap: nowrap;
}

details[open] summary {
  pointer-events: none;
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

@media (max-width: 768px) {
  details ~ details ~details summary {
    margin-left: 0;
    margin-top: var(--tab-3-mobile, 60px);

  }

  details[open] pre {
    margin-top: var(--tab-3-mobile, 60px);
  }

  details ~ details ~ details[open] pre {
    margin-top: 0;
  }
}
`;

export const render = () => html`<div class="sample-code">
  ${tabs.map((tab, i) => html`<${Tab} title=${tab[0]} content=${tab[1]} open=${i==0}/>`)}
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

