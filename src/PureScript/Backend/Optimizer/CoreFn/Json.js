// CVT fork patch — see decodeInt in Json.purs.
// Native isInteger so we can accept Numbers outside the PureScript Int range
// (Erlang Int is arbitrary precision; CoreFn from purerl can emit such values).
export const isInteger = (n) => Number.isInteger(n);
