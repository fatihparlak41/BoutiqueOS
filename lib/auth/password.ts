/**
 * Password rule shown to the user before they type and enforced in the server action.
 * Lives outside the "use server" module: a file with that directive may only export
 * async functions, so a shared constant has to sit next to it rather than inside it.
 */
export const PASSWORD_MIN_LENGTH = 10;
