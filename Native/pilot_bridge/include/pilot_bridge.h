#ifndef PILOT_BRIDGE_H
#define PILOT_BRIDGE_H

#pragma once

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Error categories returned by PilotBridge. The message carries operation-specific detail.
 */
typedef enum PP_Error {
  PP_Error_Ok = 0,
  PP_Error_InvalidArgument = 1,
  PP_Error_SessionClosed = 2,
  PP_Error_Connection = 3,
  PP_Error_Service = 4,
  PP_Error_Unsupported = 5,
  PP_Error_Internal = 6,
} PP_Error;

/**
 * Hardware buttons supported by `pp_press`.
 */
typedef enum PP_Button {
  PP_Button_Home = 0,
  PP_Button_Lock = 1,
  PP_Button_VolumeUp = 2,
  PP_Button_VolumeDown = 3,
} PP_Button;

/**
 * Opaque session. API calls on a session must not race `pp_session_close`.
 */
typedef struct PP_Session PP_Session;

/**
 * Called once when an operation finishes. `message` is valid only for the callback duration.
 */
typedef void (*PP_CompletionCallback)(void *ctx, enum PP_Error error, const char *message);

/**
 * Called once with borrowed bytes. `bytes` is valid only for the callback duration.
 */
typedef void (*PP_BytesCallback)(void *ctx,
                                 const uint8_t *bytes,
                                 size_t len,
                                 enum PP_Error error,
                                 const char *message);

/**
 * Called once with the primary display's pixel dimensions.
 */
typedef void (*PP_SizeCallback)(void *ctx,
                                uint32_t width,
                                uint32_t height,
                                enum PP_Error error,
                                const char *message);

/**
 * Opens a session asynchronously. The returned handle is owned by the caller and must be closed.
 * The callback reports whether setup completed; commands enqueued before it fires execute afterward.
 *
 * `pairing_plist_bytes` must point to `len` readable bytes and `host_ip` must be NUL-terminated.
 *
 * # Safety
 *
 * Input pointers must remain readable for the duration of this call. `context` must remain valid
 * until the callback returns, according to the caller's own callback contract.
 */
struct PP_Session *pp_session_open(const uint8_t *pairing_plist_bytes,
                                   size_t len,
                                   const char *host_ip,
                                   PP_CompletionCallback callback,
                                   void *context);

/**
 * Requests asynchronous shutdown and releases the session handle. Does not wait for teardown.
 *
 * # Safety
 *
 * `session` must be null or a live handle returned by `pp_session_open`, and may be closed once.
 */
void pp_session_close(struct PP_Session *session);

/**
 * Captures the primary display as PNG bytes.
 *
 * # Safety
 *
 * `session` must remain live until this call returns. Callback state must outlive the callback.
 */
void pp_screenshot(struct PP_Session *session, PP_BytesCallback callback, void *context);

/**
 * Taps a native-portrait normalized point on the primary display.
 *
 * # Safety
 *
 * `session` must remain live until this call returns. Callback state must outlive the callback.
 */
void pp_tap(struct PP_Session *session,
            double x,
            double y,
            PP_CompletionCallback callback,
            void *context);

/**
 * Holds a native-portrait normalized point for `duration_ms` milliseconds.
 *
 * # Safety
 *
 * `session` must remain live until this call returns. Callback state must outlive the callback.
 */
void pp_long_press(struct PP_Session *session,
                   double x,
                   double y,
                   uint32_t duration_ms,
                   PP_CompletionCallback callback,
                   void *context);

/**
 * Swipes between native-portrait normalized points over `duration_ms` milliseconds.
 *
 * # Safety
 *
 * `session` must remain live until this call returns. Callback state must outlive the callback.
 */
void pp_swipe(struct PP_Session *session,
              double x0,
              double y0,
              double x1,
              double y1,
              uint32_t duration_ms,
              PP_CompletionCallback callback,
              void *context);

/**
 * Copies `utf8` before returning.
 *
 * # Safety
 *
 * `session` must remain live until this call returns, `utf8` must be NUL-terminated, and callback
 * state must outlive the callback.
 */
void pp_type_text(struct PP_Session *session,
                  const char *utf8,
                  PP_CompletionCallback callback,
                  void *context);

/**
 * Presses and releases a supported hardware button.
 *
 * # Safety
 *
 * `session` must remain live until this call returns. Callback state must outlive the callback.
 */
void pp_press(struct PP_Session *session,
              enum PP_Button button,
              PP_CompletionCallback callback,
              void *context);

/**
 * Copies `bundle_id` before returning and launches without terminating an existing instance.
 *
 * # Safety
 *
 * `session` must remain live until this call returns, `bundle_id` must be NUL-terminated, and
 * callback state must outlive the callback.
 */
void pp_launch_app(struct PP_Session *session,
                   const char *bundle_id,
                   PP_CompletionCallback callback,
                   void *context);

/**
 * Returns the primary display size in pixels, capturing one screenshot if the size is uncached.
 *
 * # Safety
 *
 * `session` must remain live until this call returns. Callback state must outlive the callback.
 */
void pp_screen_size(struct PP_Session *session, PP_SizeCallback callback, void *context);

/**
 * Returns a JSON accessibility hierarchy snapshot.
 *
 * The top-level JSON value is an array of nodes. Each node includes `id`, `token_hex`, `role`,
 * `label`, `value`, `traits`, `children`, and `ignored`. Traversal is capped at depth 12 and 300
 * nodes. Geometry is intentionally supplied separately by OCR and `pp_ax_hit_test`.
 *
 * # Safety
 *
 * `session` must remain live until this call returns. Callback state must outlive the callback.
 */
void pp_ax_snapshot(struct PP_Session *session, PP_BytesCallback callback, void *context);

/**
 * Returns the uppercase hexadecimal accessibility token at a normalized display coordinate.
 *
 * Coordinates use portrait display space and must each be finite and in the inclusive range
 * 0...1. The callback bytes contain UTF-8 text and are valid only for the callback duration.
 *
 * # Safety
 *
 * `session` must remain live until this call returns. Callback state must outlive the callback.
 */
void pp_ax_hit_test(struct PP_Session *session,
                    double x,
                    double y,
                    PP_BytesCallback callback,
                    void *context);

#endif  /* PILOT_BRIDGE_H */
