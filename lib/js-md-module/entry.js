import { remark } from 'remark';
import remarkHtml from 'remark-html';
import { in as stdin } from 'goku';

console.log(stdin.byteLength);


function foo() {
  const buf = new ArrayBuffer(1024);
  stdin.read(buf, 0, buf.byteLength);

  const arr = new Uint8Array(in_buf);
  let str = '';
  for (let i = 0; i < arr.length; i++) {
    if (arr[i] === 0) break;
    str += String.fromCharCode(arr[i]);
  }
  console.log(str);

  throw new Error('Whoops!');

  remark()
    .use(remarkHtml)
    .process(str)
    .then((data) => {
      const res = String(data);
      const out_arr = new Uint8Array(out);
      for (let i = 0; i < res.length; i++) {
        if (i >= out_arr.length) {
          throw new Error("HTML Output exceeds output buffer size.");
        }
        out_arr[i] = res[i];
      }
    });
}
