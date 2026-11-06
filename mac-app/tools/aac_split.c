// Split a raw AAC-LC elementary stream (no ADTS) into frames by asking
// libavcodec for the shortest byte count that decodes cleanly, then emit ADTS.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>

static AVCodecContext *ctx; static AVPacket *pkt; static AVFrame *frm;
static uint8_t extradata[2] = {0x14, 0x08};   // AAC-LC, 16 kHz, mono

static int try_decode(const uint8_t *p, int len) {
    avcodec_flush_buffers(ctx);
    memset(pkt->data, 0, pkt->size);
    memcpy(pkt->data, p, len);
    pkt->size = len;
    int r = avcodec_send_packet(ctx, pkt);
    pkt->size = 800 + AV_INPUT_BUFFER_PADDING_SIZE;
    if (r < 0) return 0;
    r = avcodec_receive_frame(ctx, frm);
    if (r < 0) return 0;
    return frm->nb_samples == 1024;
}

int main(int argc, char **argv) {
    const char *in = argv[1], *out = argv[2];
    long start = atol(argv[3]);
    FILE *f = fopen(in, "rb"); fseek(f, 0, SEEK_END); long n = ftell(f);
    fseek(f, start, SEEK_SET);
    long len = n - start;
    uint8_t *buf = malloc(len + 1024); memset(buf, 0, len + 1024);
    fread(buf, 1, len, f); fclose(f);

    av_log_set_level(AV_LOG_QUIET);
    const AVCodec *c = avcodec_find_decoder(AV_CODEC_ID_AAC);
    ctx = avcodec_alloc_context3(c);
    ctx->sample_rate = 16000; ctx->ch_layout.nb_channels = 1;
    av_channel_layout_default(&ctx->ch_layout, 1);
    ctx->extradata = av_mallocz(2 + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(ctx->extradata, extradata, 2); ctx->extradata_size = 2;
    if (avcodec_open2(ctx, c, NULL) < 0) { fprintf(stderr, "open fail\n"); return 1; }
    pkt = av_packet_alloc(); av_new_packet(pkt, 800 + AV_INPUT_BUFFER_PADDING_SIZE);
    frm = av_frame_alloc();

    FILE *o = fopen(out, "wb");
    long pos = 0, frames = 0, bad = 0;
    while (pos < len) {
        int found = 0;
        int maxl = (len - pos) < 800 ? (int)(len - pos) : 800;
        for (int L = 1; L <= maxl; L++) {            // ascending = exact frame end
            if (try_decode(buf + pos, L)) { found = L; break; }
        }
        if (!found) { bad++; pos++; continue; }      // resync a byte at a time
        // ADTS header: AAC-LC(1), 16kHz idx 8, mono
        int fl = found + 7;
        uint8_t h[7] = {0xFF, 0xF1,
            (uint8_t)(((1) << 6) | (8 << 2) | ((1 >> 2) & 1)),
            (uint8_t)(((1 & 3) << 6) | ((fl >> 11) & 3)),
            (uint8_t)((fl >> 3) & 0xFF),
            (uint8_t)(((fl & 7) << 5) | 0x1F), 0xFC};
        fwrite(h, 1, 7, o); fwrite(buf + pos, 1, found, o);
        pos += found; frames++;
        if (argc > 4) printf("%d\n", found);
    }
    fclose(o);
    fprintf(stderr, "frames=%ld resync_bytes=%ld bytes=%ld/%ld\n", frames, bad, pos, len);
    return 0;
}
