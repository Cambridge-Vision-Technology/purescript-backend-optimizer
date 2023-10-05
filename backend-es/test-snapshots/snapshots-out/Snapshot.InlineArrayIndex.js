// @inline export testArrayIndex never
import * as $runtime from "../runtime.js";
import * as $mAssert from "../Assert/index.js";
import * as $mData$dMaybe from "../Data.Maybe/index.js";
import * as $mData$dShow from "../Data.Show/index.js";
const assertEqual = /* #__PURE__ */ $mAssert.assertEqual({
  eq: x => y => {
    if (x.tag === "Nothing") { return y.tag === "Nothing"; }
    return x.tag === "Just" && y.tag === "Just" && x._1 === y._1;
  }
})({
  show: v => {
    if (v.tag === "Just") { return "(Just " + $mData$dShow.showIntImpl(v._1) + ")"; }
    if (v.tag === "Nothing") { return "Nothing"; }
    $runtime.fail();
  }
});
const testArrayIndex = arr => ix => {
  if (ix >= 0 && ix < arr.length) { return $mData$dMaybe.$Maybe("Just", arr[ix]); }
  return $mData$dMaybe.Nothing;
};
const main$darray = [1, 2, 3];
const main$d0 = /* #__PURE__ */ assertEqual("index -1")({expected: $mData$dMaybe.Nothing, actual: /* #__PURE__ */ testArrayIndex(main$darray)(-1)});
const main = () => {
  main$d0();
  assertEqual("index 0")({expected: $mData$dMaybe.$Maybe("Just", 1), actual: testArrayIndex(main$darray)(0)})();
  assertEqual("index 1")({expected: $mData$dMaybe.$Maybe("Just", 2), actual: testArrayIndex(main$darray)(1)})();
  assertEqual("index 2")({expected: $mData$dMaybe.$Maybe("Just", 3), actual: testArrayIndex(main$darray)(2)})();
  return assertEqual("index 3")({expected: $mData$dMaybe.Nothing, actual: testArrayIndex(main$darray)(3)})();
};
export {assertEqual, main, main$d0, main$darray, testArrayIndex};
