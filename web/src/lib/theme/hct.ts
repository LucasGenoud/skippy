// The slice of Material's HCT colour space the theme needs: the hue of a
// seed, and the colour at a given hue, chroma and tone. Ported from
// material_color_utilities 0.13 (Apache 2.0: Cam16, ViewingConditions and
// HctSolver), which Flutter's ColorScheme.fromSeed is built on, so a seed
// lands on the same tonal colours here as in the app.

export type Rgb = readonly [number, number, number];
type Vec3 = readonly [number, number, number];
type Mat3 = readonly [Vec3, Vec3, Vec3];

const WHITE_POINT_D65: Vec3 = [95.047, 100.0, 108.883];

const SRGB_TO_XYZ: Mat3 = [
  [0.41233895, 0.35762064, 0.18051042],
  [0.2126, 0.7152, 0.0722],
  [0.01932141, 0.11916382, 0.95034478],
];

const SCALED_DISCOUNT_FROM_LINRGB: Mat3 = [
  [0.001200833568784504, 0.002389694492170889, 0.0002795742885861124],
  [0.0005891086651375999, 0.0029785502573438758, 0.0003270666104008398],
  [0.00010146692491640572, 0.0005364214359186694, 0.0032979401770712076],
];

const LINRGB_FROM_SCALED_DISCOUNT: Mat3 = [
  [1373.2198709594231, -1100.4251190754821, -7.278681089101213],
  [-271.815969077903, 559.6580465940733, -32.46047482791194],
  [1.9622899599665666, -57.173814538844006, 308.7233197812385],
];

const Y_FROM_LINRGB: Vec3 = [0.2126, 0.7152, 0.0722];

const MIN_SOLVABLE = 0.0001;
const MAX_TONE = 99.9999;
const LSTAR_EPSILON = 216 / 24389;
const LSTAR_KAPPA = 24389 / 27;
const NEWTON_ROUNDS = 5;
const BISECTION_ROUNDS = 8;
const VERTEX_COUNT = 12;
const GAMUT_LIMIT = 100.01;

function multiply(row: Vec3, m: Mat3): Vec3 {
  const dot = (col: Vec3): number => row[0] * col[0] + row[1] * col[1] + row[2] * col[2];
  return [dot(m[0]), dot(m[1]), dot(m[2])];
}

function signum(n: number): number {
  if (n < 0) {
    return -1;
  }
  return n === 0 ? 0 : 1;
}

function labInvf(ft: number): number {
  const ft3 = ft * ft * ft;
  return ft3 > LSTAR_EPSILON ? ft3 : (116 * ft - 16) / LSTAR_KAPPA;
}

function yFromLstar(lstar: number): number {
  return 100 * labInvf((lstar + 16) / 116);
}

function linearized(component: number): number {
  const normalized = component / 255;
  if (normalized <= 0.040449936) {
    return (normalized / 12.92) * 100;
  }
  return Math.pow((normalized + 0.055) / 1.055, 2.4) * 100;
}

// Linear 0-100 back to a 0-255 channel, unrounded.
function trueDelinearized(component: number): number {
  const normalized = component / 100;
  const value = normalized <= 0.0031308 ? normalized * 12.92 : 1.055 * Math.pow(normalized, 1 / 2.4) - 0.055;
  return value * 255;
}

function delinearized(component: number): number {
  return Math.min(255, Math.max(0, Math.round(trueDelinearized(component))));
}

function rgbFromLinrgb(linrgb: Vec3): Rgb {
  return [delinearized(linrgb[0]), delinearized(linrgb[1]), delinearized(linrgb[2])];
}

function rgbFromLstar(lstar: number): Rgb {
  const c = delinearized(yFromLstar(lstar));
  return [c, c, c];
}

// The default viewing conditions: sRGB, a 50 L* background, average surround.
interface ViewingConditions {
  aw: number;
  nbb: number;
  ncb: number;
  c: number;
  nC: number;
  fl: number;
  z: number;
  rgbD: Vec3;
  backgroundYToWhitePointY: number;
}

function makeViewingConditions(): ViewingConditions {
  const adaptingLuminance = ((200 / Math.PI) * yFromLstar(50)) / 100;
  const [x, y, z] = WHITE_POINT_D65;
  const rW = x * 0.401288 + y * 0.650173 + z * -0.051461;
  const gW = x * -0.250268 + y * 1.204414 + z * 0.045854;
  const bW = x * -0.002079 + y * 0.048952 + z * 0.953127;
  const surround = 2;
  const f = 0.8 + surround / 10;
  const c = f >= 0.9 ? 0.59 + (0.69 - 0.59) * ((f - 0.9) * 10) : 0.525 + (0.59 - 0.525) * ((f - 0.8) * 10);
  const d = Math.min(1, Math.max(0, f * (1 - (1 / 3.6) * Math.exp((-adaptingLuminance - 42) / 92))));
  const rgbD: Vec3 = [d * (100 / rW) + 1 - d, d * (100 / gW) + 1 - d, d * (100 / bW) + 1 - d];
  const k = 1 / (5 * adaptingLuminance + 1);
  const k4 = k * k * k * k;
  const k4F = 1 - k4;
  const fl = k4 * adaptingLuminance + 0.1 * k4F * k4F * Math.cbrt(5 * adaptingLuminance);
  const n = yFromLstar(50) / y;
  const nbb = 0.725 / Math.pow(n, 0.2);
  const factor = (channel: number, white: number): number => Math.pow((fl * channel * white) / 100, 0.42);
  const adapted = (v: number): number => (400 * v) / (v + 27.13);
  const rA = adapted(factor(rgbD[0], rW));
  const gA = adapted(factor(rgbD[1], gW));
  const bA = adapted(factor(rgbD[2], bW));
  const aw = (2 * rA + gA + 0.05 * bA) * nbb;
  return { aw, nbb, ncb: nbb, c, nC: f, fl, z: 1.48 + Math.sqrt(n), rgbD, backgroundYToWhitePointY: n };
}

let cachedConditions: ViewingConditions | null = null;

function conditions(): ViewingConditions {
  cachedConditions ??= makeViewingConditions();
  return cachedConditions;
}

/** The CAM16 hue of an sRGB colour, in degrees [0, 360). */
export function hctHue(rgb: Rgb): number {
  const vc = conditions();
  const [x, y, z] = multiply([linearized(rgb[0]), linearized(rgb[1]), linearized(rgb[2])], SRGB_TO_XYZ);
  const rC = 0.401288 * x + 0.650173 * y - 0.051461 * z;
  const gC = -0.250268 * x + 1.204414 * y + 0.045854 * z;
  const bC = -0.002079 * x + 0.048952 * y + 0.953127 * z;
  const adapt = (value: number, factor: number): number => {
    const d = factor * value;
    const af = Math.pow((vc.fl * Math.abs(d)) / 100, 0.42);
    return (signum(d) * 400 * af) / (af + 27.13);
  };
  const rA = adapt(rC, vc.rgbD[0]);
  const gA = adapt(gC, vc.rgbD[1]);
  const bA = adapt(bC, vc.rgbD[2]);
  const a = (11 * rA - 12 * gA + bA) / 11;
  const b = (rA + gA - 2 * bA) / 9;
  const degrees = (Math.atan2(b, a) * 180) / Math.PI;
  if (degrees < 0) {
    return degrees + 360;
  }
  return degrees >= 360 ? degrees - 360 : degrees;
}

// ---------------------------------------------------------------------------
// HctSolver

function sanitizeRadians(angle: number): number {
  return (angle + Math.PI * 8) % (Math.PI * 2);
}

function chromaticAdaptation(component: number): number {
  const af = Math.pow(Math.abs(component), 0.42);
  return (signum(component) * 400 * af) / (af + 27.13);
}

function inverseChromaticAdaptation(adapted: number): number {
  const abs = Math.abs(adapted);
  const base = Math.max(0, (27.13 * abs) / (400 - abs));
  return signum(adapted) * Math.pow(base, 1 / 0.42);
}

function hueOf(linrgb: Vec3): number {
  const [r, g, b] = multiply(linrgb, SCALED_DISCOUNT_FROM_LINRGB);
  const rA = chromaticAdaptation(r);
  const gA = chromaticAdaptation(g);
  const bA = chromaticAdaptation(b);
  return Math.atan2((rA + gA - 2 * bA) / 9, (11 * rA - 12 * gA + bA) / 11);
}

function areInCyclicOrder(a: number, b: number, c: number): boolean {
  return sanitizeRadians(b - a) < sanitizeRadians(c - a);
}

function setCoordinate(source: Vec3, coordinate: number, target: Vec3, axis: 0 | 1 | 2): Vec3 {
  const t = (coordinate - source[axis]) / (target[axis] - source[axis]);
  return [
    source[0] + (target[0] - source[0]) * t,
    source[1] + (target[1] - source[1]) * t,
    source[2] + (target[2] - source[2]) * t,
  ];
}

function isBounded(x: number): boolean {
  return x >= 0 && x <= 100;
}

const NO_VERTEX: Vec3 = [-1, -1, -1];

// The nth of the 12 edges of the RGB cube, cut by the plane of luminance y.
function nthVertex(y: number, n: number): Vec3 {
  const [kR, kG, kB] = Y_FROM_LINRGB;
  const coordA = n % 4 <= 1 ? 0 : 100;
  const coordB = n % 2 === 0 ? 0 : 100;
  if (n < 4) {
    const r = (y - coordA * kG - coordB * kB) / kR;
    return isBounded(r) ? [r, coordA, coordB] : NO_VERTEX;
  }
  if (n < 8) {
    const g = (y - coordB * kR - coordA * kB) / kG;
    return isBounded(g) ? [coordB, g, coordA] : NO_VERTEX;
  }
  const b = (y - coordA * kR - coordB * kG) / kB;
  return isBounded(b) ? [coordA, coordB, b] : NO_VERTEX;
}

function bisectToSegment(y: number, targetHue: number): [Vec3, Vec3] {
  let left = NO_VERTEX;
  let right = NO_VERTEX;
  let leftHue = 0;
  let rightHue = 0;
  let initialized = false;
  let uncut = true;
  for (let n = 0; n < VERTEX_COUNT; n++) {
    const mid = nthVertex(y, n);
    if (mid[0] < 0) {
      continue;
    }
    const midHue = hueOf(mid);
    if (!initialized) {
      left = mid;
      right = mid;
      leftHue = midHue;
      rightHue = midHue;
      initialized = true;
      continue;
    }
    if (uncut || areInCyclicOrder(leftHue, midHue, rightHue)) {
      uncut = false;
      if (areInCyclicOrder(leftHue, targetHue, midHue)) {
        right = mid;
        rightHue = midHue;
      } else {
        left = mid;
        leftHue = midHue;
      }
    }
  }
  return [left, right];
}

// The linear value at which a channel's rounded sRGB byte steps from i to i+1.
function criticalPlane(index: number): number {
  return linearized(index + 0.5);
}

// The most chromatic in-gamut colour at luminance y and the target hue.
function bisectToLimit(y: number, targetHue: number): Vec3 {
  let [left, right] = bisectToSegment(y, targetHue);
  let leftHue = hueOf(left);
  for (const axis of [0, 1, 2] as const) {
    if (left[axis] === right[axis]) {
      continue;
    }
    let lPlane: number;
    let rPlane: number;
    if (left[axis] < right[axis]) {
      lPlane = Math.floor(trueDelinearized(left[axis]) - 0.5);
      rPlane = Math.ceil(trueDelinearized(right[axis]) - 0.5);
    } else {
      lPlane = Math.ceil(trueDelinearized(left[axis]) - 0.5);
      rPlane = Math.floor(trueDelinearized(right[axis]) - 0.5);
    }
    for (let i = 0; i < BISECTION_ROUNDS; i++) {
      if (Math.abs(rPlane - lPlane) <= 1) {
        break;
      }
      const mPlane = Math.floor((lPlane + rPlane) / 2);
      const mid = setCoordinate(left, criticalPlane(mPlane), right, axis);
      const midHue = hueOf(mid);
      if (areInCyclicOrder(leftHue, targetHue, midHue)) {
        right = mid;
        rPlane = mPlane;
      } else {
        left = mid;
        leftHue = midHue;
        lPlane = mPlane;
      }
    }
  }
  return [(left[0] + right[0]) / 2, (left[1] + right[1]) / 2, (left[2] + right[2]) / 2];
}

// Newton iteration on J for the exact hue and chroma; null when that colour
// lies outside the sRGB gamut.
function findResultByJ(hueRadians: number, chroma: number, y: number): Rgb | null {
  const vc = conditions();
  let j = Math.sqrt(y) * 11;
  const tInnerCoeff = 1 / Math.pow(1.64 - Math.pow(0.29, vc.backgroundYToWhitePointY), 0.73);
  const eHue = 0.25 * (Math.cos(hueRadians + 2) + 3.8);
  const p1 = eHue * (50000 / 13) * vc.nC * vc.ncb;
  const hSin = Math.sin(hueRadians);
  const hCos = Math.cos(hueRadians);
  for (let round = 0; round < NEWTON_ROUNDS; round++) {
    const jNormalized = j / 100;
    const alpha = chroma === 0 || j === 0 ? 0 : chroma / Math.sqrt(jNormalized);
    const t = Math.pow(alpha * tInnerCoeff, 1 / 0.9);
    const ac = vc.aw * Math.pow(jNormalized, 1 / vc.c / vc.z);
    const p2 = ac / vc.nbb;
    const gamma = (23 * (p2 + 0.305) * t) / (23 * p1 + 11 * t * hCos + 108 * t * hSin);
    const a = gamma * hCos;
    const b = gamma * hSin;
    const rA = (460 * p2 + 451 * a + 288 * b) / 1403;
    const gA = (460 * p2 - 891 * a - 261 * b) / 1403;
    const bA = (460 * p2 - 220 * a - 6300 * b) / 1403;
    const scaled: Vec3 = [
      inverseChromaticAdaptation(rA),
      inverseChromaticAdaptation(gA),
      inverseChromaticAdaptation(bA),
    ];
    const linrgb = multiply(scaled, LINRGB_FROM_SCALED_DISCOUNT);
    if (linrgb[0] < 0 || linrgb[1] < 0 || linrgb[2] < 0) {
      return null;
    }
    const fnj = Y_FROM_LINRGB[0] * linrgb[0] + Y_FROM_LINRGB[1] * linrgb[1] + Y_FROM_LINRGB[2] * linrgb[2];
    if (fnj <= 0) {
      return null;
    }
    if (round === NEWTON_ROUNDS - 1 || Math.abs(fnj - y) < 0.002) {
      if (linrgb[0] > GAMUT_LIMIT || linrgb[1] > GAMUT_LIMIT || linrgb[2] > GAMUT_LIMIT) {
        return null;
      }
      return rgbFromLinrgb(linrgb);
    }
    j = j - ((fnj - y) * j) / (2 * fnj);
  }
  return null;
}

/**
 * The sRGB colour at an HCT hue (degrees), chroma and tone (L*, 0-100). Where
 * that chroma does not fit the gamut, the most chromatic colour of the same
 * hue and tone that does.
 */
export function hctToRgb(hue: number, chroma: number, tone: number): Rgb {
  if (chroma < MIN_SOLVABLE || tone < MIN_SOLVABLE || tone > MAX_TONE) {
    return rgbFromLstar(tone);
  }
  const hueRadians = ((((hue % 360) + 360) % 360) / 180) * Math.PI;
  const y = yFromLstar(tone);
  return findResultByJ(hueRadians, chroma, y) ?? rgbFromLinrgb(bisectToLimit(y, hueRadians));
}
