import htm from 'htm';
const t = htm.bind(globalThis.vhtml);

export const style = `details[open] :not(summary) {
  background: var(--bulma-background-hover);
}

details {
  display: inline-grid;
  grid-template-columns: auto 1fr;
}

details summary {
  grid-column: 2 / 3;
}

details summary ~ * {
  /*! grid-column: 2 / 3; */
}

.sample-code {
background: var(--bulma-background-active);
color: var(--bulma-text-100);
padding: var(--bulma-code-padding);
}
`;
export function render() {
  const tabs = ["pages/index.md", "templates/template.html", "components/button.js"];
  return t`
<div class="sample-code">
${tabs.map((tab) => t`<${Tab} tab=${tab} />`)}
</div>
`;
}

function Tab(props) {
  const tab = props.tab;

  return t`
<details name="tab">
  <summary>${tab}</summary>
  <b>tab</b>
  </details>
  `;

}

