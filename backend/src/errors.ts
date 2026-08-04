export type ErrorCode =
  | "INVALID_REQUEST"
  | "DESCRIPTION_TOO_SHORT"
  | "DESCRIPTION_TOO_LONG"
  | "RATE_LIMITED"
  | "INVALID_CLIENT_IDENTIFIER"
  | "CLIENT_RATE_LIMITED"
  | "DAILY_QUOTA_EXCEEDED"
  | "SERVER_CAPACITY_REACHED"
  | "IDENTIFICATION_DISABLED"
  | "IDENTIFICATION_TIMEOUT"
  | "IDENTIFICATION_UNAVAILABLE"
  | "INVALID_PROVIDER_RESPONSE"
  | "NO_MATCHES"
  | "INTERNAL_ERROR";
export class AppError extends Error {
  constructor(
    public code: ErrorCode,
    public status: number,
    message: string,
    public cause?: unknown,
  ) {
    super(message);
  }
}
export const publicMessage = (code: ErrorCode): string =>
  ({
    INVALID_REQUEST: "The request was invalid.",
    DESCRIPTION_TOO_SHORT: "The description is too short.",
    DESCRIPTION_TOO_LONG: "The description is too long.",
    RATE_LIMITED:
      "Dive ID is receiving too many requests right now. Please try again shortly.",
    INVALID_CLIENT_IDENTIFIER: "A valid installation identifier is required.",
    CLIENT_RATE_LIMITED:
      "Dive ID is receiving too many requests from this installation. Please try again later.",
    DAILY_QUOTA_EXCEEDED:
      "This installation has reached its daily identification limit.",
    SERVER_CAPACITY_REACHED:
      "Identification is temporarily at capacity. Please try again later.",
    IDENTIFICATION_DISABLED:
      "Identification is temporarily unavailable for maintenance.",
    IDENTIFICATION_TIMEOUT: "Identification took too long. Please try again.",
    IDENTIFICATION_UNAVAILABLE:
      "Identification is temporarily unavailable. Please try again.",
    INVALID_PROVIDER_RESPONSE:
      "Dive ID received an unexpected response. Please try again.",
    NO_MATCHES: "No useful matches were found.",
    INTERNAL_ERROR:
      "Identification is temporarily unavailable. Please try again.",
  })[code];
