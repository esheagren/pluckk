// The site gate: time on distracting sites is earned by practising. The first window of a day
// takes the whole day's cards. Once those have been finished, a later batch (the next study day's,
// arriving in the evening) doesn't lock the sites again: a finished practice session earns a window.

/** A session-earned window needs a timed session at least this long. */
export const SESSION_PASS_MINUTES = 4;

/** ...with at least this many cards rated in it: the gate's rate is ten cards for a window. */
export const SESSION_PASS_REVIEWS = 10;

/**
 * How far back the server looks for those ratings when asked for a session's pass. Generous,
 * because earned minutes can be taken any time until midnight; the session itself is judged
 * where it happened (the Mac app), and this only checks there was practice to show for it.
 */
export const SESSION_PASS_WINDOW_MINUTES = 12 * 60;

/** Whether a practice session earns a window: long enough, with enough cards rated. */
export function sessionEarnsPass(minutes: number, reviews: number): boolean {
  return minutes >= SESSION_PASS_MINUTES && reviews >= SESSION_PASS_REVIEWS;
}
