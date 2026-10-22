const $tco$gf$djf = ($tco$gf$djf$b$copy, $tco$gf$djf$a0$copy, $tco$gf$djf$a1$copy) => {
  let $tco$gf$djf$b = $tco$gf$djf$b$copy, $tco$gf$djf$a0 = $tco$gf$djf$a0$copy, $tco$gf$djf$a1 = $tco$gf$djf$a1$copy, $tco$gf$djf$c = true, $tco$gf$djf$r;
  while ($tco$gf$djf$c) {
    if ($tco$gf$djf$b === 0) {
      const n = $tco$gf$djf$a0;
      $tco$gf$djf$b = 2;
      $tco$gf$djf$a0 = n;
      $tco$gf$djf$a1 = n - 1 | 0;
      continue;
    }
    if ($tco$gf$djf$b === 1) {
      const n = $tco$gf$djf$a0;
      if (n === 100) {
        $tco$gf$djf$b = 2;
        $tco$gf$djf$a0 = n;
        $tco$gf$djf$a1 = n - 1 | 0;
        continue;
      }
      $tco$gf$djf$b = 1;
      $tco$gf$djf$a0 = n + 1 | 0;
      continue;
    }
    if ($tco$gf$djf$b === 2) {
      const a = $tco$gf$djf$a0, b = $tco$gf$djf$a1;
      $tco$gf$djf$b = 1;
      $tco$gf$djf$a0 = a + b | 0;
    }
  }
  return $tco$gf$djf$r;
};
const g = n => $tco$gf$djf(0, n);
const f$dj = n => $tco$gf$djf(1, n);
const f = a => b => $tco$gf$djf(2, a, b);
export {f, f$dj, g};
