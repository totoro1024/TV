#ifndef TV_HLS_REMUXER_H
#define TV_HLS_REMUXER_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct TVRemux TVRemux;
TVRemux *TVRemuxCreate(const char *input, const char *directory, double start);
int TVRemuxRun(TVRemux *job);
void TVRemuxCancel(TVRemux *job);
void TVRemuxPlaybackTime(TVRemux *job, double seconds);
void TVRemuxDestroy(TVRemux *job);
double TVRemuxStartTime(TVRemux *job);
double TVRemuxDuration(TVRemux *job);
#ifdef __cplusplus
}
#endif
#endif
