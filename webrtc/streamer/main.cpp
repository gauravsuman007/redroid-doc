/*
 * Copyright (C) 2026 The redroid Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// redroid_webrtc: streams a redroid device to browsers through the cuttlefish
// WebRTC operator. Phase 0 spike: renders a test pattern instead of the device
// screen and only logs input, to validate the cuttlefish streamer integration.

#include <signal.h>
#include <stdint.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <gflags/gflags.h>

#include "absl/log/globals.h"
#include "absl/log/initialize.h"
#include "absl/log/log.h"
#include "drm/drm_fourcc.h"

#include "cuttlefish/host/frontend/redroid_webrtc/logging_connection_observer.h"
#include "cuttlefish/host/frontend/webrtc/client_server.h"
#include "cuttlefish/host/frontend/webrtc/cvd_abgr_video_frame_buffer.h"
#include "cuttlefish/host/frontend/webrtc/libdevice/recording_manager.h"
#include "cuttlefish/host/frontend/webrtc/libdevice/streamer.h"
#include "cuttlefish/host/frontend/webrtc/libdevice/video_sink.h"

DEFINE_string(device_id, "redroid", "Id the device registers with at the operator.");
DEFINE_string(operator_path, "/run/cuttlefish/operator",
              "Unix socket of the cuttlefish operator.");
DEFINE_string(client_dir, "/usr/share/redroid-webrtc/html_client",
              "Directory with the cuttlefish html client files.");
DEFINE_int32(width, 720, "Display width.");
DEFINE_int32(height, 1280, "Display height.");
DEFINE_int32(dpi, 320, "Display dpi.");
DEFINE_int32(fps, 30, "Frames per second.");
DEFINE_int32(udp_port_min, 15550, "First UDP port WebRTC may use.");
DEFINE_int32(udp_port_max, 15599, "Last UDP port WebRTC may use.");

namespace redroid {
namespace {

using cuttlefish::CvdAbgrVideoFrameBuffer;
using cuttlefish::webrtc_streaming::OperatorObserver;
using cuttlefish::webrtc_streaming::RecordingManager;
using cuttlefish::webrtc_streaming::Streamer;
using cuttlefish::webrtc_streaming::StreamerConfig;
using cuttlefish::webrtc_streaming::VideoSink;

constexpr auto kDisplayLabel = "display_0";

std::atomic<bool> g_running{true};

class LoggingOperatorObserver : public OperatorObserver {
 public:
  void OnRegistered() override { LOG(INFO) << "Registered with operator"; }
  void OnClose() override { LOG(ERROR) << "Connection with operator closed"; }
  void OnError() override { LOG(ERROR) << "Error in connection with operator"; }
};

// Renders moving colour bars plus a square at the last pointer position.
// ABGR8888 is stored as R,G,B,A bytes in memory (little endian).
class TestPattern {
 public:
  TestPattern(int width, int height)
      : width_(width), height_(height), pixels_(width * height * 4) {}

  std::shared_ptr<CvdAbgrVideoFrameBuffer> Render(
      int frame, const PointerState& pointer) {
    static constexpr uint8_t kBars[8][3] = {
        {255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
        {255, 0, 255},   {255, 0, 0},   {0, 0, 255},   {16, 16, 16}};
    int bar_width = (width_ + 7) / 8;
    int shift = (frame * 4) % width_;
    for (int y = 0; y < height_; y++) {
      uint8_t* row = &pixels_[y * width_ * 4];
      for (int x = 0; x < width_; x++) {
        const uint8_t* c = kBars[((x + shift) % width_) / bar_width];
        row[x * 4 + 0] = c[0];
        row[x * 4 + 1] = c[1];
        row[x * 4 + 2] = c[2];
        row[x * 4 + 3] = 255;
      }
    }
    int px = pointer.x, py = pointer.y;
    if (px >= 0 && py >= 0) {
      int half = pointer.down ? 40 : 20;
      uint8_t v = pointer.down ? 255 : 200;
      for (int y = std::max(0, py - half); y < std::min(height_, py + half);
           y++) {
        for (int x = std::max(0, px - half); x < std::min(width_, px + half);
             x++) {
          uint8_t* p = &pixels_[(y * width_ + x) * 4];
          p[0] = p[1] = p[2] = v;
        }
      }
    }
    return std::make_shared<CvdAbgrVideoFrameBuffer>(
        width_, height_, DRM_FORMAT_ABGR8888, width_ * 4, pixels_.data());
  }

 private:
  int width_;
  int height_;
  std::vector<uint8_t> pixels_;
};

int Main() {
  auto client_server = cuttlefish::ClientFilesServer::New(FLAGS_client_dir);
  if (!client_server) {
    LOG(ERROR) << "Failed to serve client files from " << FLAGS_client_dir;
    return 1;
  }

  StreamerConfig config;
  config.device_id = FLAGS_device_id;
  config.client_files_port = client_server->port();
  config.operator_path = FLAGS_operator_path;
  config.udp_port_range = {static_cast<uint16_t>(FLAGS_udp_port_min),
                           static_cast<uint16_t>(FLAGS_udp_port_max)};
  config.tcp_port_range = config.udp_port_range;
  config.adb_port = 0;
  config.enable_mouse = false;
  config.enable_gamepad = false;

  auto pointer = std::make_shared<PointerState>();
  auto observer_factory =
      std::make_shared<LoggingConnectionObserverFactory>(pointer);

  RecordingManager recording_manager;
  auto streamer = Streamer::Create(config, recording_manager, observer_factory);
  if (!streamer) {
    LOG(ERROR) << "Failed to create streamer";
    return 1;
  }

  std::shared_ptr<VideoSink> display = streamer->AddDisplay(
      kDisplayLabel, FLAGS_width, FLAGS_height, FLAGS_dpi, /*touch_enabled=*/true);
  if (!display) {
    LOG(ERROR) << "Failed to add display";
    return 1;
  }
  streamer->SetHardwareSpec("Device", std::string("redroid (test pattern)"));

  auto operator_observer = std::make_shared<LoggingOperatorObserver>();
  streamer->Register(operator_observer);
  LOG(INFO) << "Streaming " << FLAGS_width << "x" << FLAGS_height << "@"
            << FLAGS_fps << " as '" << FLAGS_device_id << "' via "
            << FLAGS_operator_path;

  TestPattern pattern(FLAGS_width, FLAGS_height);
  auto frame_interval = std::chrono::microseconds(1000000 / FLAGS_fps);
  auto next_frame = std::chrono::steady_clock::now();
  for (int frame = 0; g_running; frame++) {
    auto buffer = pattern.Render(frame, *pointer);
    int64_t timestamp_us =
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count();
    display->OnFrame(buffer, timestamp_us);
    next_frame += frame_interval;
    std::this_thread::sleep_until(next_frame);
  }

  streamer->Unregister();
  return 0;
}

}  // namespace
}  // namespace redroid

int main(int argc, char** argv) {
  absl::InitializeLog();
  absl::SetStderrThreshold(absl::LogSeverityAtLeast::kInfo);
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  signal(SIGINT, [](int) { redroid::g_running = false; });
  signal(SIGTERM, [](int) { redroid::g_running = false; });
  return redroid::Main();
}
