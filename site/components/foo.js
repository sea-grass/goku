import htm from 'htm';
const t = htm.bind(globalThis.vhtml);

export const style = "";
export function render() {
  return t`<${BulmaReferenceSection} />`;
}

function BulmaReferenceSection() {
  return t`
<section class="section">
  <div class="container">
    <h1 class="title">Bulma Reference</h1>
    <p class="subtitle">
      An essential Bulma reference guide.
    </p>

## This


<a href="/bulma-reference" class="button">See more</a>
  </div>
</section>
  `;
}
