#include "TVHLSRemuxer.h"
#include <libavformat/avformat.h>
#include <libavcodec/bsf.h>
#include <libavutil/avutil.h>
#include <libavutil/mathematics.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/statvfs.h>

struct TVRemux {
    char *input, *directory;
    double requested;
    _Atomic int cancelled;
    _Atomic double start, duration, playback;
};
TVRemux *TVRemuxCreate(const char *input, const char *directory, double start) {
    TVRemux *job = calloc(1, sizeof(*job));
    if (!job) return NULL;
    job->input = strdup(input); job->directory = strdup(directory); job->requested = start;
    atomic_init(&job->cancelled, 0); atomic_init(&job->start, 0); atomic_init(&job->duration, 0); atomic_init(&job->playback, start);
    return job;
}
void TVRemuxPlaybackTime(TVRemux *job, double seconds) { atomic_store(&job->playback, seconds); }
void TVRemuxCancel(TVRemux *job) { atomic_store(&job->cancelled, 1); }
void TVRemuxDestroy(TVRemux *job) { free(job->input); free(job->directory); free(job); }
double TVRemuxStartTime(TVRemux *job) { return atomic_load(&job->start); }
double TVRemuxDuration(TVRemux *job) { return atomic_load(&job->duration); }
static int interrupted(void *opaque) { return atomic_load(&((TVRemux *)opaque)->cancelled); }

// 只重新封装 H.264/HEVC + AAC，不降低画质、不在主线程解码。
int TVRemuxRun(TVRemux *job) {
    AVFormatContext *input = avformat_alloc_context(), *output = NULL;
    AVPacket *packet = NULL, *filtered = NULL;
    AVBSFContext *aac = NULL;
    AVDictionary *options = NULL;
    int result = AVERROR(ENOMEM), headerWritten = 0, video = -1, audio = -1;
    int *map = NULL;
    char playlist[4096], pattern[4096];
    int64_t bytes = 0;
    double base = -1;
    if (!input) goto done;
    input->interrupt_callback.callback = interrupted;
    input->interrupt_callback.opaque = job;
    av_dict_set(&options, "rw_timeout", "20000000", 0);
    result = avformat_open_input(&input, job->input, NULL, &options);
    av_dict_free(&options);
    if (result < 0) goto done;
    if ((result = avformat_find_stream_info(input, NULL)) < 0) goto done;
    atomic_store(&job->duration, input->duration > 0 ? (double)input->duration / AV_TIME_BASE : 0);
    for (unsigned i = 0; i < input->nb_streams; i++) {
        AVCodecParameters *p = input->streams[i]->codecpar;
        if (video < 0 && p->codec_type == AVMEDIA_TYPE_VIDEO && (p->codec_id == AV_CODEC_ID_H264 || p->codec_id == AV_CODEC_ID_HEVC)) video = i;
        if (audio < 0 && p->codec_type == AVMEDIA_TYPE_AUDIO && p->codec_id == AV_CODEC_ID_AAC) audio = i;
    }
    // 不支持的编码明确失败，不能产生无声或黑屏的“投放成功”。
    if (video < 0 || audio < 0) { result = AVERROR(ENOSYS); goto done; }
    if (job->requested > 0) {
        int64_t stamp = (int64_t)(job->requested / av_q2d(input->streams[video]->time_base));
        if ((result = av_seek_frame(input, video, stamp, AVSEEK_FLAG_BACKWARD)) < 0) goto done;
    }
    snprintf(playlist, sizeof(playlist), "%s/index.m3u8", job->directory);
    int fragmented = input->streams[video]->codecpar->codec_id == AV_CODEC_ID_HEVC;
    snprintf(pattern, sizeof(pattern), fragmented ? "%s/segment-%%06d.m4s" : "%s/segment-%%06d.ts", job->directory);
    if ((result = avformat_alloc_output_context2(&output, NULL, "hls", playlist)) < 0 || !output) goto done;
    output->interrupt_callback = input->interrupt_callback;
    output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_ZERO;
    map = malloc(input->nb_streams * sizeof(int));
    if (!map) { result = AVERROR(ENOMEM); goto done; }
    for (unsigned i = 0; i < input->nb_streams; i++) {
        map[i] = -1;
        if ((int)i != video && (int)i != audio) continue;
        AVStream *stream = avformat_new_stream(output, NULL);
        if (!stream) { result = AVERROR(ENOMEM); goto done; }
        map[i] = stream->index;
        if ((result = avcodec_parameters_copy(stream->codecpar, input->streams[i]->codecpar)) < 0) goto done;
        stream->codecpar->codec_tag = fragmented && (int)i == video ? MKTAG('h','v','c','1') : 0;
        stream->time_base = input->streams[i]->time_base;
    }
    // TS 中 AAC 带 ADTS 头；MP4 需要 AudioSpecificConfig 与无 ADTS 的音频包。
    if (fragmented) {
        const AVBitStreamFilter *filter = av_bsf_get_by_name("aac_adtstoasc");
        if (!filter) { result = AVERROR(ENOSYS); goto done; }
        if ((result = av_bsf_alloc(filter, &aac)) < 0) goto done;
        if ((result = avcodec_parameters_copy(aac->par_in, input->streams[audio]->codecpar)) < 0) goto done;
        aac->time_base_in = input->streams[audio]->time_base;
        if ((result = av_bsf_init(aac)) < 0) goto done;
        if ((result = avcodec_parameters_copy(output->streams[map[audio]]->codecpar, aac->par_out)) < 0) goto done;
        output->streams[map[audio]]->codecpar->codec_tag = 0;
        filtered = av_packet_alloc();
        if (!filtered) { result = AVERROR(ENOMEM); goto done; }
    }
    if (fragmented) {
        av_dict_set(&options, "hls_segment_type", "fmp4", 0);
        av_dict_set(&options, "hls_fmp4_init_filename", "init.mp4", 0);
    }
    av_dict_set(&options, "hls_time", "6", 0);
    av_dict_set(&options, "hls_list_size", "0", 0);
    av_dict_set(&options, "hls_playlist_type", "event", 0);
    av_dict_set(&options, "hls_flags", "temp_file+independent_segments", 0);
    av_dict_set(&options, "hls_segment_filename", pattern, 0);
    if ((result = avformat_write_header(output, &options)) < 0) goto done;
    av_dict_free(&options); headerWritten = 1;
    packet = av_packet_alloc();
    if (!packet) { result = AVERROR(ENOMEM); goto done; }
    while (!interrupted(job) && (result = av_read_frame(input, packet)) >= 0) {
        int index = packet->stream_index;
        if (index < 0 || index >= (int)input->nb_streams || map[index] < 0) { av_packet_unref(packet); continue; }
        if (base < 0) {
            if (index != video || !(packet->flags & AV_PKT_FLAG_KEY) || packet->pts == AV_NOPTS_VALUE) { av_packet_unref(packet); continue; }
            base = packet->pts * av_q2d(input->streams[index]->time_base);
            atomic_store(&job->start, base);
        }
        AVRational time = input->streams[index]->time_base;
        // 只预备约三分钟，暂停时停止继续消耗网络和存储。
        double packetTime = packet->pts == AV_NOPTS_VALUE ? 0 : packet->pts * av_q2d(time);
        while (!interrupted(job) && packetTime > atomic_load(&job->playback) + 180) usleep(50000);
        if (interrupted(job)) { result = AVERROR_EXIT; goto done; }
        int64_t offset = (int64_t)(base / av_q2d(time));
        if (packet->pts != AV_NOPTS_VALUE) packet->pts -= offset;
        if (packet->dts != AV_NOPTS_VALUE) packet->dts -= offset;
        bytes += packet->size;
        // 临时缓存上限 2 GiB，同时为本机保留至少 128 MiB 可用空间。
        struct statvfs disk;
        if (bytes > 2LL * 1024 * 1024 * 1024 || (statvfs(job->directory, &disk) == 0 && (uint64_t)disk.f_bavail * disk.f_frsize < 128ULL * 1024 * 1024)) {
            result = AVERROR(ENOSPC); goto done;
        }
        if (aac && index == audio) {
            if ((result = av_bsf_send_packet(aac, packet)) < 0) goto done;
            while ((result = av_bsf_receive_packet(aac, filtered)) >= 0) {
                av_packet_rescale_ts(filtered, aac->time_base_out, output->streams[map[index]]->time_base);
                filtered->stream_index = map[index]; filtered->pos = -1;
                result = av_interleaved_write_frame(output, filtered);
                av_packet_unref(filtered);
                if (result < 0) goto done;
            }
            if (result != AVERROR(EAGAIN) && result != AVERROR_EOF) goto done;
        } else {
            av_packet_rescale_ts(packet, time, output->streams[map[index]]->time_base);
            packet->stream_index = map[index]; packet->pos = -1;
            result = av_interleaved_write_frame(output, packet);
            av_packet_unref(packet);
            if (result < 0) goto done;
        }
    }
    if (result == AVERROR_EOF) result = 0;
    if (interrupted(job)) result = AVERROR_EXIT;
done:
    // 不把不完整输出标记为完整影片。
    if (headerWritten && result == 0) result = av_write_trailer(output);
    av_dict_free(&options);
    if (packet) av_packet_free(&packet);
    if (filtered) av_packet_free(&filtered);
    av_bsf_free(&aac);
    free(map);
    if (input) avformat_close_input(&input);
    if (output) avformat_free_context(output);
    return result;
}
