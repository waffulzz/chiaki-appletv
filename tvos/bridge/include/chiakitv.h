// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

// Small C facade over chiaki-lib for the tvOS app.
// Swift only sees this header: chiaki-lib's own structs depend on the crypto backend
// (mbedtls on tvOS), so session/regist/discovery objects stay opaque here.

#ifndef CHIAKITV_H
#define CHIAKITV_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <chiaki/controller.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Must be called once before anything else. Returns 0 on success.
int chiakitv_init(void);

// ---------------------------------------------------------------- logging

typedef enum {
	CHIAKITV_LOG_DEBUG = 1 << 4,
	CHIAKITV_LOG_VERBOSE = 1 << 3,
	CHIAKITV_LOG_INFO = 1 << 2,
	CHIAKITV_LOG_WARNING = 1 << 1,
	CHIAKITV_LOG_ERROR = 1 << 0
} ChiakiTVLogLevel;

typedef void (*ChiakiTVLogCallback)(int level, const char *msg, void *user);
/// Global log sink used by every object created afterwards. level_mask is a ChiakiTVLogLevel mask.
void chiakitv_set_log_callback(ChiakiTVLogCallback cb, void *user, uint32_t level_mask);

// ---------------------------------------------------------------- discovery

typedef enum {
	CHIAKITV_HOST_STATE_UNKNOWN = 0,
	CHIAKITV_HOST_STATE_READY = 1,
	CHIAKITV_HOST_STATE_STANDBY = 2
} ChiakiTVHostState;

typedef struct {
	int state; // ChiakiTVHostState
	bool ps5;
	int target; // ChiakiTarget, to be passed to registration
	char host_addr[64];
	char host_name[128];
	char host_id[64]; // console MAC as hex
	char system_version[32];
	char running_app_name[128];
	char running_app_titleid[32];
} ChiakiTVHost;

typedef struct ChiakiTVDiscovery ChiakiTVDiscovery;
typedef void (*ChiakiTVDiscoveryCallback)(const ChiakiTVHost *hosts, size_t count, void *user);

/// Searches for consoles every 500 ms. host == NULL broadcasts on every local network,
/// otherwise only that hostname/IP is asked. The callback runs on a background thread.
ChiakiTVDiscovery *chiakitv_discovery_start(const char *host, ChiakiTVDiscoveryCallback cb, void *user);
void chiakitv_discovery_stop(ChiakiTVDiscovery *discovery);

/// Wakes a console in rest mode. regist_key is the 16-char rp_regist_key from registration.
int chiakitv_wakeup(const char *host, const char *regist_key, size_t regist_key_size, bool ps5);

// ---------------------------------------------------------------- registration

typedef struct {
	int target;
	char server_nickname[32];
	uint8_t server_mac[6];
	char rp_regist_key[16];
	uint32_t rp_key_type;
	uint8_t rp_key[16];
} ChiakiTVRegisteredHost;

typedef enum {
	CHIAKITV_REGIST_CANCELED = 0,
	CHIAKITV_REGIST_FAILED = 1,
	CHIAKITV_REGIST_SUCCESS = 2
} ChiakiTVRegistResult;

typedef struct ChiakiTVRegist ChiakiTVRegist;
typedef void (*ChiakiTVRegistCallback)(int result, const ChiakiTVRegisteredHost *host, void *user);

/// psn_account_id: 8 raw bytes (decoded from the base64 Account-ID). pin: 8-digit code from the console.
ChiakiTVRegist *chiakitv_regist_start(const char *host, int target, const uint8_t psn_account_id[8],
		uint32_t pin, bool broadcast, ChiakiTVRegistCallback cb, void *user);
/// Stops (if still running) and frees. Do not call from inside the callback.
void chiakitv_regist_free(ChiakiTVRegist *regist);

// ---------------------------------------------------------------- streaming

typedef enum {
	CHIAKITV_CODEC_H264 = 0,
	CHIAKITV_CODEC_H265 = 1,
	CHIAKITV_CODEC_H265_HDR = 2
} ChiakiTVCodec;

typedef struct {
	const char *host;
	bool ps5;
	char regist_key[16]; // rp_regist_key
	uint8_t morning[16]; // rp_key
	unsigned int width;
	unsigned int height;
	unsigned int max_fps;
	unsigned int bitrate; // kbit/s
	int codec; // ChiakiTVCodec, ignored (forced to H264) for PS4
	bool enable_dualsense;
	bool enable_keyboard; // let the console hand text entry to the client (KEYBOARD_* events)
} ChiakiTVConnectInfo;

typedef enum {
	CHIAKITV_EVENT_CONNECTED = 0,
	CHIAKITV_EVENT_LOGIN_PIN_REQUEST = 1,
	CHIAKITV_EVENT_QUIT = 2,
	CHIAKITV_EVENT_RUMBLE = 3,
	CHIAKITV_EVENT_NICKNAME = 4,
	CHIAKITV_EVENT_LED_COLOR = 5,
	/// rumble_left/right derived from the DualSense haptic audio stream (sent every 30 ms while active)
	CHIAKITV_EVENT_HAPTIC_RUMBLE = 6,
	/// The console opened its on-screen keyboard; keyboard_text is the current text (may be NULL).
	/// Answer with chiakitv_session_keyboard_set_text + _accept, or _reject.
	CHIAKITV_EVENT_KEYBOARD_OPEN = 7,
	CHIAKITV_EVENT_KEYBOARD_TEXT_CHANGE = 8,
	/// The console closed the keyboard itself
	CHIAKITV_EVENT_KEYBOARD_REMOTE_CLOSE = 9,
	/// DualSense adaptive trigger effects: trigger_type_* plus 10 parameter bytes each,
	/// in the DualSense controller's own effect format
	CHIAKITV_EVENT_TRIGGER_EFFECTS = 10,
	/// player_index: 0-based player number for the controller's player LEDs
	CHIAKITV_EVENT_PLAYER_INDEX = 11
} ChiakiTVEventType;

typedef struct {
	int type; // ChiakiTVEventType
	bool quit_is_error;
	int quit_reason;
	const char *quit_reason_str; // human readable, valid during the callback only
	bool pin_incorrect;
	uint8_t rumble_left;
	uint8_t rumble_right;
	uint8_t led[3]; // lightbar color, red/green/blue
	uint8_t player_index;
	const char *nickname;
	const char *keyboard_text; // valid during the callback only
	uint8_t trigger_type_left;
	uint8_t trigger_type_right;
	uint8_t trigger_left[10];
	uint8_t trigger_right[10];
} ChiakiTVEvent;

/// Return false to report the frame as corrupt (the console then sends a new keyframe).
typedef bool (*ChiakiTVVideoCallback)(const uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user);
typedef void (*ChiakiTVAudioSettingsCallback)(uint32_t channels, uint32_t rate, void *user);
typedef void (*ChiakiTVAudioFrameCallback)(const int16_t *buf, size_t samples_count, void *user);
typedef void (*ChiakiTVEventCallback)(const ChiakiTVEvent *event, void *user);

typedef struct {
	ChiakiTVVideoCallback video;
	ChiakiTVAudioSettingsCallback audio_settings;
	ChiakiTVAudioFrameCallback audio_frame;
	ChiakiTVEventCallback event;
	void *user;
} ChiakiTVCallbacks;

typedef struct ChiakiTVSession ChiakiTVSession;

/// Creates and starts a session. Returns NULL on failure (error text in the log).
ChiakiTVSession *chiakitv_session_start(const ChiakiTVConnectInfo *info, const ChiakiTVCallbacks *callbacks);
void chiakitv_session_stop(ChiakiTVSession *session);
/// Stops, joins and frees. Do not call from inside a callback.
void chiakitv_session_free(ChiakiTVSession *session);
void chiakitv_session_set_controller_state(ChiakiTVSession *session, const ChiakiControllerState *state);
void chiakitv_session_set_login_pin(ChiakiTVSession *session, const char *pin);
void chiakitv_session_request_idr(ChiakiTVSession *session);
void chiakitv_session_goto_bed(ChiakiTVSession *session);
void chiakitv_session_keyboard_set_text(ChiakiTVSession *session, const char *text);
void chiakitv_session_keyboard_accept(ChiakiTVSession *session);
void chiakitv_session_keyboard_reject(ChiakiTVSession *session);

#ifdef __cplusplus
}
#endif

#endif // CHIAKITV_H
