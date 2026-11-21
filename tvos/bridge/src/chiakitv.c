// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include <chiakitv.h>

#include <chiaki/common.h>
#include <chiaki/log.h>
#include <chiaki/discovery.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>
#include <chiaki/opusdecoder.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <signal.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------- logging

static ChiakiTVLogCallback g_log_cb;
static void *g_log_user;
static ChiakiLog g_log;

static void log_forward(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	if(g_log_cb)
		g_log_cb((int)level, msg, g_log_user);
	else
		chiaki_log_cb_print(level, msg, NULL);
}

void chiakitv_set_log_callback(ChiakiTVLogCallback cb, void *user, uint32_t level_mask)
{
	g_log_cb = cb;
	g_log_user = user;
	chiaki_log_init(&g_log, level_mask, log_forward, NULL);
}

int chiakitv_init(void)
{
	// Writing to a socket the system has torn down (e.g. while the app was suspended)
	// raises SIGPIPE, which would kill the app. Get EPIPE from send() instead.
	signal(SIGPIPE, SIG_IGN);
	if(!g_log.cb)
		chiaki_log_init(&g_log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, log_forward, NULL);
	ChiakiErrorCode err = chiaki_lib_init();
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&g_log, "chiaki_lib_init failed: %s", chiaki_error_string(err));
		return (int)err;
	}
	return 0;
}

// ---------------------------------------------------------------- discovery

struct ChiakiTVDiscovery
{
	ChiakiDiscoveryService service;
	ChiakiTVDiscoveryCallback cb;
	void *user;
};

static void copy_str(char *dst, size_t dst_size, const char *src)
{
	if(!src)
	{
		dst[0] = '\0';
		return;
	}
	snprintf(dst, dst_size, "%s", src);
}

static void discovery_cb(ChiakiDiscoveryHost *hosts, size_t hosts_count, void *user)
{
	ChiakiTVDiscovery *d = user;
	ChiakiTVHost *out = hosts_count ? calloc(hosts_count, sizeof(ChiakiTVHost)) : NULL;
	if(hosts_count && !out)
		return;
	for(size_t i = 0; i < hosts_count; i++)
	{
		ChiakiDiscoveryHost *h = &hosts[i];
		ChiakiTVHost *o = &out[i];
		o->state = (int)h->state;
		o->ps5 = chiaki_discovery_host_is_ps5(h);
		o->target = (int)chiaki_discovery_host_system_version_target(h);
		copy_str(o->host_addr, sizeof(o->host_addr), h->host_addr);
		copy_str(o->host_name, sizeof(o->host_name), h->host_name);
		copy_str(o->host_id, sizeof(o->host_id), h->host_id);
		copy_str(o->system_version, sizeof(o->system_version), h->system_version);
		copy_str(o->running_app_name, sizeof(o->running_app_name), h->running_app_name);
		copy_str(o->running_app_titleid, sizeof(o->running_app_titleid), h->running_app_titleid);
	}
	d->cb(out, hosts_count, d->user);
	free(out);
}

ChiakiTVDiscovery *chiakitv_discovery_start(const char *host, ChiakiTVDiscoveryCallback cb, void *user)
{
	ChiakiTVDiscovery *d = calloc(1, sizeof(ChiakiTVDiscovery));
	if(!d)
		return NULL;
	d->cb = cb;
	d->user = user;

	ChiakiDiscoveryServiceOptions options = { 0 };
	options.ping_ms = 500;
	options.hosts_max = 16;
	options.host_drop_pings = 3;
	options.cb = discovery_cb;
	options.cb_user = d;

	struct sockaddr_in in_addr = { 0 };
	in_addr.sin_family = AF_INET;
	in_addr.sin_addr.s_addr = host ? 0 : 0xffffffff;
	struct sockaddr_storage addr;
	memset(&addr, 0, sizeof(addr));
	memcpy(&addr, &in_addr, sizeof(in_addr));
	options.send_addr = &addr;
	options.send_addr_size = sizeof(in_addr);
	options.send_host = (char *)host;

	// Also send to each interface's directed broadcast address: 255.255.255.255 alone
	// only goes out of the primary interface.
	struct sockaddr_storage broadcast_addrs[16];
	size_t broadcast_num = 0;
	struct ifaddrs *ifaddrs = NULL;
	if(!host && getifaddrs(&ifaddrs) == 0)
	{
		for(struct ifaddrs *ifa = ifaddrs; ifa && broadcast_num < 16; ifa = ifa->ifa_next)
		{
			if(!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
				continue;
			if(!(ifa->ifa_flags & IFF_UP) || !(ifa->ifa_flags & IFF_BROADCAST) || (ifa->ifa_flags & IFF_LOOPBACK))
				continue;
			if(!ifa->ifa_broadaddr)
				continue;
			struct sockaddr_in b = *(struct sockaddr_in *)ifa->ifa_broadaddr;
			b.sin_family = AF_INET;
			memset(&broadcast_addrs[broadcast_num], 0, sizeof(struct sockaddr_storage));
			memcpy(&broadcast_addrs[broadcast_num], &b, sizeof(b));
			char s[INET_ADDRSTRLEN];
			inet_ntop(AF_INET, &b.sin_addr, s, sizeof(s));
			CHIAKI_LOGI(&g_log, "Discovery broadcasting on %s (%s)", ifa->ifa_name, s);
			broadcast_num++;
		}
		freeifaddrs(ifaddrs);
	}
	options.broadcast_addrs = broadcast_num ? broadcast_addrs : NULL;
	options.broadcast_num = broadcast_num;

	ChiakiErrorCode err = chiaki_discovery_service_init(&d->service, &options, &g_log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&g_log, "Failed to start discovery: %s", chiaki_error_string(err));
		free(d);
		return NULL;
	}
	return d;
}

void chiakitv_discovery_stop(ChiakiTVDiscovery *d)
{
	if(!d)
		return;
	chiaki_discovery_service_fini(&d->service);
	free(d);
}

int chiakitv_wakeup(const char *host, const char *regist_key, size_t regist_key_size, bool ps5)
{
	char key[17] = { 0 };
	memcpy(key, regist_key, regist_key_size < 16 ? regist_key_size : 16);
	char *end = NULL;
	uint64_t credential = strtoull(key, &end, 16);
	if(end == key)
	{
		CHIAKI_LOGE(&g_log, "Invalid regist key for wakeup");
		return CHIAKI_ERR_INVALID_DATA;
	}
	return (int)chiaki_discovery_wakeup(&g_log, NULL, host, credential, ps5);
}

// ---------------------------------------------------------------- registration

struct ChiakiTVRegist
{
	ChiakiRegist regist;
	char *host;
	ChiakiTVRegistCallback cb;
	void *user;
};

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	ChiakiTVRegist *r = user;
	ChiakiTVRegisteredHost out = { 0 };
	int result = CHIAKITV_REGIST_FAILED;
	switch(event->type)
	{
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
			result = CHIAKITV_REGIST_CANCELED;
			break;
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED:
			result = CHIAKITV_REGIST_FAILED;
			break;
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
		{
			result = CHIAKITV_REGIST_SUCCESS;
			ChiakiRegisteredHost *h = event->registered_host;
			out.target = (int)h->target;
			memcpy(out.server_nickname, h->server_nickname, sizeof(out.server_nickname));
			out.server_nickname[sizeof(out.server_nickname) - 1] = '\0';
			memcpy(out.server_mac, h->server_mac, sizeof(out.server_mac));
			memcpy(out.rp_regist_key, h->rp_regist_key, sizeof(out.rp_regist_key));
			out.rp_key_type = h->rp_key_type;
			memcpy(out.rp_key, h->rp_key, sizeof(out.rp_key));
			break;
		}
	}
	r->cb(result, result == CHIAKITV_REGIST_SUCCESS ? &out : NULL, r->user);
}

ChiakiTVRegist *chiakitv_regist_start(const char *host, int target, const uint8_t psn_account_id[8],
		uint32_t pin, bool broadcast, ChiakiTVRegistCallback cb, void *user)
{
	ChiakiTVRegist *r = calloc(1, sizeof(ChiakiTVRegist));
	if(!r)
		return NULL;
	r->host = strdup(host);
	r->cb = cb;
	r->user = user;

	ChiakiRegistInfo info = { 0 };
	info.target = (ChiakiTarget)target;
	info.host = r->host;
	info.broadcast = broadcast;
	info.psn_online_id = NULL;
	memcpy(info.psn_account_id, psn_account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.pin = pin;
	info.console_pin = 0;
	info.holepunch_info = NULL;
	info.rudp = NULL;

	ChiakiErrorCode err = chiaki_regist_start(&r->regist, &g_log, &info, regist_cb, r);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&g_log, "Failed to start registration: %s", chiaki_error_string(err));
		free(r->host);
		free(r);
		return NULL;
	}
	return r;
}

void chiakitv_regist_free(ChiakiTVRegist *r)
{
	if(!r)
		return;
	chiaki_regist_stop(&r->regist);
	chiaki_regist_fini(&r->regist);
	free(r->host);
	free(r);
}

// ---------------------------------------------------------------- streaming

struct ChiakiTVSession
{
	ChiakiSession session;
	ChiakiOpusDecoder opus;
	ChiakiTVCallbacks cb;
	char *host;
	bool stopped;
	// DualSense haptics -> rumble (see haptics_frame_cb)
	uint32_t haptic_sum_left;
	uint32_t haptic_sum_right;
	unsigned haptic_packets;
	bool haptic_on;
};

#define HAPTIC_PACKETS_PER_RUMBLE 3 // 10 ms packets, so one rumble update every 30 ms
#define HAPTIC_RUMBLE_MIN_STRENGTH 100

/// With DualSense features on, the PS5 sends vibration as 3 kHz stereo 16-bit "haptic audio"
/// instead of rumble events. Like the desktop GUI, turn its loudness into rumble strength.
static void haptics_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
	ChiakiTVSession *s = user;
	const size_t sample_size = 2 * sizeof(int16_t);
	if(!s->cb.event || buf_size < sample_size)
		return;
	size_t count = buf_size / sample_size;
	uint32_t sum_left = 0, sum_right = 0;
	for(size_t i = 0; i < count; i++)
	{
		int16_t l, r;
		memcpy(&l, buf + i * sample_size, sizeof(l));
		memcpy(&r, buf + i * sample_size + sizeof(l), sizeof(r));
		sum_left += (uint32_t)abs(l) * 2;
		sum_right += (uint32_t)abs(r) * 2;
	}
	uint32_t left = sum_left / count, right = sum_right / count;
	s->haptic_sum_left += left > HAPTIC_RUMBLE_MIN_STRENGTH ? left : 0;
	s->haptic_sum_right += right > HAPTIC_RUMBLE_MIN_STRENGTH ? right : 0;
	if(++s->haptic_packets < HAPTIC_PACKETS_PER_RUMBLE)
		return;
	uint32_t avg_left = s->haptic_sum_left / HAPTIC_PACKETS_PER_RUMBLE;
	uint32_t avg_right = s->haptic_sum_right / HAPTIC_PACKETS_PER_RUMBLE;
	s->haptic_sum_left = s->haptic_sum_right = 0;
	s->haptic_packets = 0;
	bool on = avg_left > 0 || avg_right > 0;
	if(!on && !s->haptic_on)
		return; // stay quiet while idle, but send one "off" after activity
	s->haptic_on = on;
	ChiakiTVEvent e = { 0 };
	e.type = CHIAKITV_EVENT_HAPTIC_RUMBLE;
	e.rumble_left = (uint8_t)((avg_left > 0xffff ? 0xffff : avg_left) >> 8);
	e.rumble_right = (uint8_t)((avg_right > 0xffff ? 0xffff : avg_right) >> 8);
	s->cb.event(&e, s->cb.user);
}

static void session_event_cb(ChiakiEvent *event, void *user)
{
	ChiakiTVSession *s = user;
	if(!s->cb.event)
		return;
	ChiakiTVEvent e = { 0 };
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			e.type = CHIAKITV_EVENT_CONNECTED;
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			e.type = CHIAKITV_EVENT_LOGIN_PIN_REQUEST;
			e.pin_incorrect = event->login_pin_request.pin_incorrect;
			break;
		case CHIAKI_EVENT_QUIT:
			e.type = CHIAKITV_EVENT_QUIT;
			e.quit_reason = (int)event->quit.reason;
			e.quit_is_error = chiaki_quit_reason_is_error(event->quit.reason);
			e.quit_reason_str = event->quit.reason_str ? event->quit.reason_str : chiaki_quit_reason_string(event->quit.reason);
			break;
		case CHIAKI_EVENT_RUMBLE:
			e.type = CHIAKITV_EVENT_RUMBLE;
			e.rumble_left = event->rumble.left;
			e.rumble_right = event->rumble.right;
			break;
		case CHIAKI_EVENT_NICKNAME_RECEIVED:
			e.type = CHIAKITV_EVENT_NICKNAME;
			e.nickname = event->server_nickname;
			break;
		case CHIAKI_EVENT_KEYBOARD_OPEN:
			e.type = CHIAKITV_EVENT_KEYBOARD_OPEN;
			e.keyboard_text = event->keyboard.text_str;
			break;
		case CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE:
			e.type = CHIAKITV_EVENT_KEYBOARD_TEXT_CHANGE;
			e.keyboard_text = event->keyboard.text_str;
			break;
		case CHIAKI_EVENT_KEYBOARD_REMOTE_CLOSE:
			e.type = CHIAKITV_EVENT_KEYBOARD_REMOTE_CLOSE;
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
			e.type = CHIAKITV_EVENT_TRIGGER_EFFECTS;
			e.trigger_type_left = event->trigger_effects.type_left;
			e.trigger_type_right = event->trigger_effects.type_right;
			memcpy(e.trigger_left, event->trigger_effects.left, sizeof(e.trigger_left));
			memcpy(e.trigger_right, event->trigger_effects.right, sizeof(e.trigger_right));
			break;
		case CHIAKI_EVENT_LED_COLOR:
			e.type = CHIAKITV_EVENT_LED_COLOR;
			memcpy(e.led, event->led_state, sizeof(e.led));
			break;
		default:
			return;
	}
	s->cb.event(&e, s->cb.user);
}

static bool session_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	ChiakiTVSession *s = user;
	if(!s->cb.video)
		return true;
	return s->cb.video(buf, buf_size, frames_lost, frame_recovered, s->cb.user);
}

static void opus_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	ChiakiTVSession *s = user;
	if(s->cb.audio_settings)
		s->cb.audio_settings(channels, rate, s->cb.user);
}

static void opus_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
	ChiakiTVSession *s = user;
	if(s->cb.audio_frame)
		s->cb.audio_frame(buf, samples_count, s->cb.user);
}

ChiakiTVSession *chiakitv_session_start(const ChiakiTVConnectInfo *info, const ChiakiTVCallbacks *callbacks)
{
	ChiakiTVSession *s = calloc(1, sizeof(ChiakiTVSession));
	if(!s)
		return NULL;
	s->cb = *callbacks;
	s->host = strdup(info->host);

	ChiakiConnectInfo ci;
	memset(&ci, 0, sizeof(ci));
	ci.ps5 = info->ps5;
	ci.host = s->host;
	memcpy(ci.regist_key, info->regist_key, sizeof(ci.regist_key));
	memcpy(ci.morning, info->morning, sizeof(ci.morning));
	ci.video_profile.width = info->width;
	ci.video_profile.height = info->height;
	ci.video_profile.max_fps = info->max_fps;
	ci.video_profile.bitrate = info->bitrate;
	ci.video_profile.codec = info->ps5 ? (ChiakiCodec)info->codec : CHIAKI_CODEC_H264;
	ci.video_profile_auto_downgrade = true;
	ci.enable_keyboard = info->enable_keyboard;
	ci.enable_dualsense = info->enable_dualsense;
	ci.audio_video_disabled = 0;
	ci.auto_regist = false;
	ci.holepunch_session = NULL;
	ci.rudp_sock = NULL;
	ci.packet_loss_max = 0.05;
	ci.enable_idr_on_fec_failure = true;

	chiaki_opus_decoder_init(&s->opus, &g_log);

	ChiakiErrorCode err = chiaki_session_init(&s->session, &ci, &g_log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&g_log, "Session init failed: %s", chiaki_error_string(err));
		chiaki_opus_decoder_fini(&s->opus);
		free(s->host);
		free(s);
		return NULL;
	}

	chiaki_opus_decoder_set_cb(&s->opus, opus_settings_cb, opus_frame_cb, s);
	ChiakiAudioSink audio_sink;
	chiaki_opus_decoder_get_sink(&s->opus, &audio_sink);
	chiaki_session_set_audio_sink(&s->session, &audio_sink);
	ChiakiAudioSink haptics_sink = { 0 };
	haptics_sink.user = s;
	haptics_sink.frame_cb = haptics_frame_cb;
	chiaki_session_set_haptics_sink(&s->session, &haptics_sink);
	chiaki_session_set_event_cb(&s->session, session_event_cb, s);
	chiaki_session_set_video_sample_cb(&s->session, session_video_cb, s);

	err = chiaki_session_start(&s->session);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&g_log, "Session start failed: %s", chiaki_error_string(err));
		chiaki_session_fini(&s->session);
		chiaki_opus_decoder_fini(&s->opus);
		free(s->host);
		free(s);
		return NULL;
	}
	return s;
}

void chiakitv_session_stop(ChiakiTVSession *s)
{
	if(!s || s->stopped)
		return;
	s->stopped = true;
	chiaki_session_stop(&s->session);
}

void chiakitv_session_free(ChiakiTVSession *s)
{
	if(!s)
		return;
	chiakitv_session_stop(s);
	chiaki_session_join(&s->session);
	chiaki_session_fini(&s->session);
	chiaki_opus_decoder_fini(&s->opus);
	free(s->host);
	free(s);
}

void chiakitv_session_set_controller_state(ChiakiTVSession *s, const ChiakiControllerState *state)
{
	if(!s)
		return;
	ChiakiControllerState copy = *state;
	chiaki_session_set_controller_state(&s->session, &copy);
}

void chiakitv_session_set_login_pin(ChiakiTVSession *s, const char *pin)
{
	if(!s || !pin)
		return;
	chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

void chiakitv_session_request_idr(ChiakiTVSession *s)
{
	if(s)
		chiaki_session_request_idr(&s->session);
}

void chiakitv_session_goto_bed(ChiakiTVSession *s)
{
	if(s)
		chiaki_session_goto_bed(&s->session);
}

void chiakitv_session_keyboard_set_text(ChiakiTVSession *s, const char *text)
{
	if(s && text)
		chiaki_session_keyboard_set_text(&s->session, text);
}

void chiakitv_session_keyboard_accept(ChiakiTVSession *s)
{
	if(s)
		chiaki_session_keyboard_accept(&s->session);
}

void chiakitv_session_keyboard_reject(ChiakiTVSession *s)
{
	if(s)
		chiaki_session_keyboard_reject(&s->session);
}
