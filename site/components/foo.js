const bulmaReferenceSection = () => `
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

function render() {
  return `
  <a href="/">Home</a>
  <b>This is a rendered component.</b>
  ${bulmaReferenceSection()}
  `;
}


globalThis.foo = render();
