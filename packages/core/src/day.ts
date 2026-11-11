// When a study day begins. The daily new-card allowance counts from here, so cards finished in
// the morning leave the evening free for the next day's batch.

/** The hour (0–23, in the study time zone) at which a new study day starts. */
export const DAY_START_HOUR = 17;

/** Where the clock is read when no other zone is given. */
export const DEFAULT_STUDY_TIME_ZONE = 'America/New_York';

/**
 * The start of the study day that `now` falls in: the most recent `startHour`:00 on the clock
 * of `timeZone`. Measured in elapsed time from that clock reading, so on the two days a year the
 * clocks change it can sit an hour off until the next start.
 */
export function studyDayStart(now: Date = new Date(), timeZone: string = DEFAULT_STUDY_TIME_ZONE, startHour: number = DAY_START_HOUR): Date {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone, hourCycle: 'h23', hour: 'numeric', minute: 'numeric', second: 'numeric' }).formatToParts(now);
  const part = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? 0);
  const DAY_MS = 86_400_000;
  const sinceMidnight = (part('hour') * 3600 + part('minute') * 60 + part('second')) * 1000 + now.getUTCMilliseconds();
  const sinceStart = (sinceMidnight - startHour * 3_600_000 + DAY_MS) % DAY_MS;
  return new Date(now.getTime() - sinceStart);
}
