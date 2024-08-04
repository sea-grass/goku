import { remark } from 'remark';
import remarkHtml from 'remark-html';
import { in as stdin } from 'std';

const buf = new ArrayBuffer(1024);
stdin.read(buf, 0, buf.byteLength);

const arr = new Uint8Array(buf);
let str = '';
for (let i = 0; i < arr.length; i++) {
  if (arr[i] === 0) break;
  str += String.fromCharCode(arr[i]);
}
console.log(str);

remark()
  .use(remarkHtml)
  .process(str)
.then((data) => {
  console.log(String(data));
});
