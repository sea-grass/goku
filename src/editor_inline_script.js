/**
 * This source is injected in some random spot in the body tag.
 * It should aim to delay its execution until the page has completed loading.
 */
(function() {
  'use strict';

  document.addEventListener("DOMContentLoaded", () => {
    const root = cel("div", "root", ["loading"], ["Loading..."]);
    document.body.appendChild(root);
    // Display the loading state before loading the app.
      requestAnimationFrame(() => {
        mount(root).then(() => { root.classList.remove("loading"); });
      });
  });

  async function mount(root) {
    const raw = await fetch("?raw").then((res) => res.text());

    const editor = cel("div", "editor", ["content"], [
      form("POST", null, [], [
        cel("h2", "editor-heading", ["title", "is-2"], ["Editor"]),
        textarea(10, "content", [], raw),
        input("submit", null, ["button", "is-primary"], "Save"),
        cel("button", null, ["button", "close"], ["Close"]),
      ]),
    ]);

    await tweaks.artificialDelay(5_00, 1_200);

    root.innerHTML = '';
    root.appendChild(editor);
  }

  const tweaks = {
    /**
     * Sometimes, a little waiting is good.
     */
    artificialDelay(min_ms, max_ms) {
      const wait_ms = min_ms + Math.random() * (max_ms - min_ms);
      return new Promise((resolve) => {
        setTimeout(resolve, wait_ms);
      });
    },
  };

  /**
   * @param {keyof HTMLElementTagNameMap} tagName 
   * @param {string} id
   * @param {Arguments<typeof clsx>[0]} classNames
   */
  function cel(tagName, id, classNames, children) {
    const el = document.createElement(tagName);
    if (id) el.id = id;
    if (classNames) {
      classNames = clsx(classNames);
      if (classNames === 'loading') {
        console.log('set!');
      }
      el.className = classNames;
    }
    if (Array.isArray(children) && children.length) {
      children.forEach((child) => el.appendChild(typeof child === 'string' ? new Text(child) : child));
    }
    return el;
  }

  function textarea(rows, id, classNames, value) {
    const el = cel("textarea", id, ["textarea", classNames]);
    if (id) el.setAttribute("name", id);
    if (value) el.value = value;
    if (rows) el.setAttribute("rows", rows);
    return el;
  }

  function input(type, id, classNames, value) {
    const el = cel("input", id, classNames);
    if (type) el.type = type;
    if (value) el.value = value;
    return el;
  }

  function form(method, id, classNames, children) {
    const el = cel("form", id, classNames, children);
    if (method) el.setAttribute("method", method);
    return el;
  }

  /* clsx is from: https://github.com/lukeed/clsx/blob/master/src/index.js */
  const clsx = (function() {
    function toVal(mix) {
      var k, y, str='';

      if (typeof mix === 'string' || typeof mix === 'number') {
        str += mix;
      } else if (typeof mix === 'object') {
        if (Array.isArray(mix)) {
          var len=mix.length;
          for (k=0; k < len; k++) {
            if (mix[k]) {
              if (y = toVal(mix[k])) {
                str && (str += ' ');
                str += y;
              }
            }
          }
        } else {
          for (y in mix) {
            if (mix[y]) {
              str && (str += ' ');
              str += y;
            }
          }
        }
      }

      return str;
    }

    function clsx() {
      var i=0, tmp, x, str='', len=arguments.length;
      for (; i < len; i++) {
        if (tmp = arguments[i]) {
          if (x = toVal(tmp)) {
            str && (str += ' ');
            str += x
          }
        }
      }
      return str;
    }
    return clsx;
  }());
}());

