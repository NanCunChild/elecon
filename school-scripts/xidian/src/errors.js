/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */

// ADR-034 §6: messages stay in sanitized diagnostics. The result channel uses
// only the host's fixed categories, never server text, URLs or identifiers.
export function failure(message) {
  const error = new Error(message);
  if (message === "card_number_required") error.code = "input_required_card_number";
  else if (message === "input_cancelled") error.code = "input_cancelled";
  else if (message === "student_id_required") error.code = "input_required_student_id";
  else if (/^xidian_login_required_(ehall|yjspt|card|library)$/.test(message))
    error.code = "authentication_required";
  else if (message === "xidian_login_timeout") error.code = "authentication_timeout";
  else if (message === "xidian_redirect_origin_denied") error.code = "network_denied";
  else if (
    /^xidian_ids_(password_rejected|login_rejected|mfa_.*|captcha_rejected|global_session_missing)$/.test(
      message,
    )
  )
    error.code = "authentication_required";
  else if (
    message === "academic_response_invalid" ||
    [
      "card_balance_missing",
      "card_money_invalid",
      "card_transactions_invalid",
      "card_transactions_incomplete",
    ].includes(message) ||
    /^xidian_(ids|pda)_/.test(message)
  )
    error.code = "source_response_invalid";
  return error;
}
