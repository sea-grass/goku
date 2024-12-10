const memory = new WebAssembly.Memory({
  initial: 0,
  maximum: 10,
});
console.log(memory);
const table = new WebAssembly.Table({initial:0, element: "anyfunc"});
const import_object = { env: { __memory_base: 0, __table_base: 0, memory, __indirect_function_table: table, __stack_pointer: 0 } };

WebAssembly.instantiateStreaming(
  fetch("zig-out/lib/goku.wasm.wasm"),
  import_object,
).then((results) => {
  console.log(results);
  console.log(results.module);
  debugger;
});
