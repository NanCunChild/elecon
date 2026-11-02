#ifndef ELECON_HERMES_H
#define ELECON_HERMES_H
#ifdef __cplusplus
extern "C" {
#endif
/* C ABI v1. UTF-8 JSON input, max 1 MiB. Do not log RPC input/output. */
char *elecon_hermes_call(const char *input_json);
/* Erases and frees exactly one allocation returned by elecon_hermes_call. */
void elecon_hermes_free(char *output_json);
#ifdef __cplusplus
}
#endif
#endif
