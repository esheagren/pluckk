// The site gate: time on distracting sites is earned by practising. The first window of a day
// takes the whole day's cards. Once those have been finished, a later batch (the next study day's,
// arriving in the evening) doesn't lock the sites again: a finished practice session earns a window.

/** A session-earned window needs a timed session at least this long. */
export const SESSION_PASS_MINUTES = 4;

/** ...with at least this many cards rated in it: the gate's rate is ten cards for a window. */
export const SESSION_PASS_REVIEWS = 10;

/**
 * What the server asks to see before signing a window the Mac app says was earned while cards
 * are due: some practice in the last day. The window is judged where it was earned (the Mac
 * app); it's kept until midnight, and the due count rarely stays at zero that long, because
 * cards due later in the day keep coming into it. So the server doesn't re-judge, it only
 * refuses a pass with no practice behind it.
 */
export const PASS_EVIDENCE_REVIEWS = 1;
export const PASS_EVIDENCE_WINDOW_MINUTES = 24 * 60;

/** Whether a practice session earns a window: long enough, with enough cards rated. */
export function sessionEarnsPass(minutes: number, reviews: number): boolean {
  return minutes >= SESSION_PASS_MINUTES && reviews >= SESSION_PASS_REVIEWS;
}
