// The site gate: time on distracting sites is earned by practising. The first window of a day
// takes the whole day's cards. Once those have been finished, a later batch (the next study day's,
// arriving in the evening) doesn't lock the sites again: a finished practice session earns a window.

/** A session-earned window needs a timed session at least this long. */
export const SESSION_PASS_MINUTES = 4;

/** ...with at least this many cards rated in it. */
export const SESSION_PASS_REVIEWS = 5;

/** How far back the server looks for those ratings when asked for a session's pass. */
export const SESSION_PASS_WINDOW_MINUTES = 20;

/** Whether a practice session earns a window: long enough, with enough cards rated. */
export function sessionEarnsPass(minutes: number, reviews: number): boolean {
  return minutes >= SESSION_PASS_MINUTES && reviews >= SESSION_PASS_REVIEWS;
}
