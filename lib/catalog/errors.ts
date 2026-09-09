/**
 * The catalogue keeps importing its error helpers from here; the table itself moved to
 * lib/db-errors.ts when receiving and stock needed the same translations. One source of
 * truth, no behaviour change for the catalogue screens.
 */
export { toUserMessage, reportDbError, type DbError } from "@/lib/db-errors";
