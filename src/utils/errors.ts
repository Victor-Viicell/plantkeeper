/**
 * Surfaces a thrown message, falling back to generic copy for odd failures.
 *
 * Every screen that talks to the backend needs this, so it lives in one place;
 * a rejected `Error` with an empty message is as likely as a thrown string.
 */
export function describeError(cause: unknown, fallback: string): string {
  return cause instanceof Error && cause.message ? cause.message : fallback;
}
