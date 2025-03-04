import { html } from 'goku';

export const style = "";
export const render = () => BulmaReferenceSection();


function BulmaReferenceSection() {
  return html`<section class="section">
  <div class="container">
    <h1 class="title">Bulma Reference</h1>
    <p class="subtitle">
      An essential Bulma reference guide.
    </p>

    ## This

    <a href="/bulma-reference" class="button">See more</a>
  </div>
</section>`;
}
