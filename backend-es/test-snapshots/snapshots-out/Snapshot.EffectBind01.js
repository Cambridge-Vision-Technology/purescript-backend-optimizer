import * as $mEffect$dConsole from "../Effect.Console/index.js";
const test1$d0 = /* #__PURE__ */ $mEffect$dConsole.log("1");
const test1 = () => {
  test1$d0();
  const value = $mEffect$dConsole.log("2")();
  $mEffect$dConsole.log("3")();
  return value;
};
export {test1, test1$d0};
