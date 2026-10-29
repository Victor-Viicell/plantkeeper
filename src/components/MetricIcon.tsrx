import type { ReadingMetricKey } from "../utils/devices";

/**
 * One stroke icon per reading, so a metric is recognisable before the label is
 * read. The colour comes from `.metric-icon-*` in the global stylesheet.
 */
export function MetricIcon({ metric }: { metric: ReadingMetricKey }) @{
  <>
    <svg
      class={`metric-icon metric-icon-${metric}`}
      viewBox="0 0 24 24"
      width="16"
      height="16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      @if (metric === "soil") {
        <>
          <path d="M12 21v-6" />
          <path d="M12 15c0-3.3-2.7-6-6-6 0 3.3 2.7 6 6 6z" />
          <path d="M12 15c0-3.3 2.7-6 6-6 0 3.3-2.7 6-6 6z" />
        </>
      } @else if (metric === "light") {
        <>
          <circle cx="12" cy="12" r="4" />
          <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
        </>
      } @else if (metric === "temperature") {
        <>
          <path d="M14 14.8V5a2 2 0 1 0-4 0v9.8a4 4 0 1 0 4 0z" />
          <path d="M12 9v6" />
        </>
      } @else {
        <path d="M12 3s6 6.5 6 10.5a6 6 0 0 1-12 0C6 9.5 12 3 12 3z" />
      }
    </svg>
  </>
}
