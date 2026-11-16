// 小鲸桌宠的本地唤醒词常驻进程（sherpa-onnx KWS）。
//
// 为什么是独立进程而不是塞进 App：
//   - sherpa-onnx 要带 onnxruntime（约 31MB）与模型（约 5MB），放进 App 的
//     Xcode 构建会让「没跑过拉取脚本」的机器直接编译不过；
//   - 独立进程崩溃不会带走桌宠，App 侧拉不到进程就自动退回「系统识别 +
//     文本匹配唤醒」，功能降级而不是整个 App 起不来。
// 这也是架构文档 §7.4「采集/KWS/ASR 全在常驻子进程」的同一套做法。
//
// 协议（stdin → stdout，均为二进制/行）：
//   stdin ：一帧一包 = 4 字节小端 int32 采样数 + 采样数 × float32（16kHz 单声道）
//   stdout：每行一个 JSON 事件
//           {"type":"ready","keywords":"小鲸小鲸"}
//           {"type":"wake","keyword":"小鲸小鲸"}
//           {"type":"error","message":"..."}
//
// 用法：
//   whalepet_kws --model <模型目录> --keywords <关键词串或@文件> \
//                [--threshold 0.08] [--score 4.0] [--debug]

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <string>
#include <vector>

#include "sherpa-onnx/c-api/c-api.h"

namespace {

struct Options {
  std::string model_dir;
  std::string keywords;
  float threshold = 0.08f;
  float score = 4.0f;
  bool debug = false;
};

std::string ReadAllFile(const std::string &path) {
  FILE *fp = fopen(path.c_str(), "rb");
  if (!fp) return "";
  std::string out;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) out.append(buf, n);
  fclose(fp);
  return out;
}

bool ReadExactly(FILE *fp, void *dst, size_t n) {
  return fread(dst, 1, n, fp) == n;
}

// 从 "@路径" 读关键词文件，否则当作内联关键词串。
//
// 注意：sherpa-onnx 的关键词表格式**不支持注释**——任何一行解析失败都会让
// 整张表编码失败（关键词文件里出现 '#' 开头的说明行会导致一个词都识别不了）。
// 所以这里先把 '#' 开头的行去掉，再把有效行拼起来。
std::string ResolveKeywords(const std::string &raw) {
  if (raw.empty() || raw[0] != '@') return raw;

  std::string content = ReadAllFile(raw.substr(1));
  // 去掉可能的 BOM
  if (content.size() >= 3 && (unsigned char)content[0] == 0xEF &&
      (unsigned char)content[1] == 0xBB && (unsigned char)content[2] == 0xBF) {
    content = content.substr(3);
  }

  std::vector<std::string> lines;
  size_t start = 0;
  while (start <= content.size()) {
    size_t end = content.find('\n', start);
    if (end == std::string::npos) end = content.size();
    std::string line = content.substr(start, end - start);
    // 去掉行首空白
    size_t first = line.find_first_not_of(" \t\r");
    if (first == std::string::npos) {
      // 空行
    } else if (line[first] == '#') {
      // 注释行
    } else {
      line = line.substr(first);
      while (!line.empty() && (line.back() == '\r' || line.back() == ' ' ||
                               line.back() == '\t')) {
        line.pop_back();
      }
      if (!line.empty()) lines.push_back(line);
    }
    if (end == content.size()) break;
    start = end + 1;
  }

  std::string out;
  for (size_t i = 0; i < lines.size(); ++i) {
    if (i > 0) out += "\n";
    out += lines[i];
  }
  return out;
}

void Emit(const char *json) {
  printf("%s\n", json);
  fflush(stdout);
}

}  // namespace

int main(int argc, char **argv) {
  Options opt;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&](const char *name) -> std::string {
      if (i + 1 >= argc) {
        fprintf(stderr, "缺少 %s 的值\n", name);
        exit(2);
      }
      return argv[++i];
    };
    if (a == "--model") opt.model_dir = next("--model");
    else if (a == "--keywords") opt.keywords = next("--keywords");
    else if (a == "--threshold") opt.threshold = (float)atof(next("--threshold").c_str());
    else if (a == "--score") opt.score = (float)atof(next("--score").c_str());
    else if (a == "--debug") opt.debug = true;
    else {
      fprintf(stderr, "未知参数: %s\n", a.c_str());
      return 2;
    }
  }

  if (opt.model_dir.empty() || opt.keywords.empty()) {
    fprintf(stderr, "用法: %s --model <目录> --keywords <关键词串或@文件> [--threshold f] [--score f]\n", argv[0]);
    return 2;
  }

  std::string model_dir = opt.model_dir;
  std::string encoder = model_dir + "/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx";
  std::string decoder = model_dir + "/decoder-epoch-12-avg-2-chunk-16-left-64.onnx";
  std::string joiner = model_dir + "/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx";
  std::string tokens = model_dir + "/tokens.txt";

  std::string keywords = ResolveKeywords(opt.keywords);
  if (keywords.empty()) {
    fprintf(stderr, "关键词为空\n");
    return 1;
  }

  SherpaOnnxKeywordSpotterConfig config;
  memset(&config, 0, sizeof(config));
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.transducer.encoder = encoder.c_str();
  config.model_config.transducer.decoder = decoder.c_str();
  config.model_config.transducer.joiner = joiner.c_str();
  config.model_config.tokens = tokens.c_str();
  config.model_config.num_threads = 1;
  config.model_config.provider = "cpu";
  config.model_config.modeling_unit = "cjkchar";
  config.max_active_paths = 4;
  config.num_trailing_blanks = 1;
  config.keywords_score = opt.score;
  config.keywords_threshold = opt.threshold;
  config.keywords_buf = keywords.c_str();
  config.keywords_buf_size = (int32_t)keywords.size();

  const SherpaOnnxKeywordSpotter *spotter = SherpaOnnxCreateKeywordSpotter(&config);
  if (!spotter) {
    Emit("{\"type\":\"error\",\"message\":\"创建关键词检测器失败（模型或运行时不可用）\"}");
    return 1;
  }
  const SherpaOnnxOnlineStream *stream = SherpaOnnxCreateKeywordStream(spotter);
  if (!stream) {
    Emit("{\"type\":\"error\",\"message\":\"创建关键词流失败（关键词表编码失败）\"}");
    SherpaOnnxDestroyKeywordSpotter(spotter);
    return 1;
  }

  Emit("{\"type\":\"ready\"}");
  if (opt.debug) fprintf(stderr, "[kws] 就绪 threshold=%f score=%f\n", opt.threshold, opt.score);

  std::vector<float> samples;
  int32_t count = 0;
  while (ReadExactly(stdin, &count, sizeof(count))) {
    // 负数帧长是控制指令：-1 = 复位关键词流。
    // App 在「从聆听切回待机」时发一次，免得上一轮的残留状态误触发。
    if (count == -1) {
      SherpaOnnxResetKeywordStream(spotter, stream);
      if (opt.debug) fprintf(stderr, "[kws] 复位关键词流\n");
      continue;
    }
    if (count <= 0 || count > 16000 * 30) {
      // 非法帧长：直接退出，让 App 侧发现管道断了
      fprintf(stderr, "[kws] 非法帧长 %d\n", count);
      break;
    }
    samples.resize((size_t)count);
    if (!ReadExactly(stdin, samples.data(), sizeof(float) * (size_t)count)) break;

    SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, samples.data(), count);
    while (SherpaOnnxIsKeywordStreamReady(spotter, stream)) {
      SherpaOnnxDecodeKeywordStream(spotter, stream);
      const SherpaOnnxKeywordResult *r = SherpaOnnxGetKeywordResult(spotter, stream);
      if (r) {
        if (r->keyword && strlen(r->keyword) > 0) {
          printf("{\"type\":\"wake\",\"keyword\":\"%s\"}\n", r->keyword);
          fflush(stdout);
          if (opt.debug) fprintf(stderr, "[kws] 命中: %s\n", r->keyword);
          // 命中后复位，下一个关键词独立检测
          SherpaOnnxResetKeywordStream(spotter, stream);
        }
        SherpaOnnxDestroyKeywordResult(r);
      }
    }
  }

  // 输入结束：补一段静音再冲掉尾巴。
  // 关键词要靠「后面跟若干个 blank」才会确认触发：实时场景里麦克风一直送来
  // 静音，所以自然满足；到这里（App 停止采集 / 文件读完）必须显式补一段，
  // 否则最后一个关键词会一直悬着没被确认。
  // 0.5 秒是官方示例用的量。
  std::vector<float> tail(8000, 0.0f);
  SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, tail.data(), (int32_t)tail.size());
  SherpaOnnxOnlineStreamInputFinished(stream);
  while (SherpaOnnxIsKeywordStreamReady(spotter, stream)) {
    SherpaOnnxDecodeKeywordStream(spotter, stream);
    const SherpaOnnxKeywordResult *r = SherpaOnnxGetKeywordResult(spotter, stream);
    if (r) {
      if (r->keyword && strlen(r->keyword) > 0) {
        printf("{\"type\":\"wake\",\"keyword\":\"%s\"}\n", r->keyword);
        fflush(stdout);
        if (opt.debug) fprintf(stderr, "[kws] 收尾命中: %s\n", r->keyword);
      }
      SherpaOnnxDestroyKeywordResult(r);
    }
  }

  SherpaOnnxDestroyOnlineStream(stream);
  SherpaOnnxDestroyKeywordSpotter(spotter);
  return 0;
}
