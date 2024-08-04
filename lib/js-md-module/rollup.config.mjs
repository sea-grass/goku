import {nodeResolve} from '@rollup/plugin-node-resolve';
import commonjs from '@rollup/plugin-commonjs';

export default {
  input: 'entry.js',
  output: {
    file: 'bin.js',
  },
  plugins: [commonjs(), nodeResolve()]
};
