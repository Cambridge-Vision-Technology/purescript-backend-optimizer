export { spawn as spawnImpl } from "node:child_process";

export const errorCodeImpl = error => error.code;
