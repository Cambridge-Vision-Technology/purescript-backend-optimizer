// @inline export divNoInline never
import * as $runtime from "../runtime.js";
import * as $mAssert from "../Assert/index.js";
import * as $mData$dEq from "../Data.Eq/index.js";
import * as $mData$dShow from "../Data.Show/index.js";
const divNoInline = a => b => $runtime.intDiv(a, b);
const main$d0 = /* #__PURE__ */ $mAssert.assertEqual($mData$dEq.eqInt)($mData$dShow.showInt)("div1")({expected: 0, actual: /* #__PURE__ */ divNoInline(1)(0)});
const main = () => {
  main$d0();
  $mAssert.assertEqual($mData$dEq.eqInt)($mData$dShow.showInt)("div2")({expected: 1, actual: divNoInline(3)(2)})();
  return $mAssert.assertEqual($mData$dEq.eqInt)($mData$dShow.showInt)("div3")({expected: -1, actual: divNoInline(3)(-2)})();
};
export {divNoInline, main, main$d0};
