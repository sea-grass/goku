/**
 * This source is injected in some random spot in the body tag.
 * It should aim to delay its execution until the page has completed loading.
 */
(function() {
  'use strict';

  document.addEventListener("DOMContentLoaded", () => {
    const root = document.createElement("div");
    root.id = "root";
    document.body.appendChild(root);

    mount(root);
  });

  async function mount(root) {
    const response = await fetch("?raw");
    const raw = await response.text();

    const title = cel("h2", "editor-heading", [], ["Editor"]);

    const textarea = cel("textarea", "content");
    textarea.setAttribute("name", "content");
    textarea.value = raw;

    const submitButton = cel("input", null, ["button"]);
    submitButton.type = "submit";
    submitButton.value = "submit";

    const closeButton = cel("button", null, ["button", "close"], ["Close"]);

    const form = cel("form", null, [], [title, textarea, submitButton, closeButton]);
    form.setAttribute("method", "POST");
    const editor = cel("div", "editor", [], [form]);
    
    root.appendChild(editor);
  }

  function cel(tagNames, id, classNames, children) {
    const el = document.createElement(tagNames);
    if (id) el.id = id;
    if (Array.isArray(classNames) && classNames.length) {
      classNames.forEach((className) => el.classList.add(className));
    }
    if (Array.isArray(children) && children.length) {
      children.forEach((child) => el.appendChild(typeof child === 'string' ? new Text(child) : child));
    }
    return el;
  }
}());

